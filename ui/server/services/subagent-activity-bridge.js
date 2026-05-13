import { promises as fs } from 'fs';
import fsSync from 'fs';
import path from 'path';
import os from 'os';

const POLL_INTERVAL_MS = 1000;
const AGENT_TRANSCRIPT_RE = /^agent-(?!cron).*\.jsonl$/i;

function encodeProjectRoot(projectRoot) {
  return path.resolve(projectRoot).replace(/[\\/:\s~_]/g, '-');
}

async function readProjectConfig() {
  try {
    const configPath = path.join(os.homedir(), '.claude', 'project-config.json');
    return JSON.parse(await fs.readFile(configPath, 'utf8'));
  } catch {
    return {};
  }
}

async function resolveProjectStoreDir(projectRoot) {
  if (!projectRoot) {
    return null;
  }

  const resolvedRoot = path.resolve(projectRoot);
  const config = await readProjectConfig();
  for (const [projectName, projectConfig] of Object.entries(config)) {
    const configuredRoot = projectConfig?.originalPath || projectConfig?.path;
    if (configuredRoot && path.resolve(configuredRoot) === resolvedRoot) {
      return path.join(os.homedir(), '.claude', 'projects', projectName);
    }
  }

  return path.join(os.homedir(), '.claude', 'projects', encodeProjectRoot(resolvedRoot));
}

function partContentToString(content) {
  if (typeof content === 'string') {
    return content;
  }
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (typeof part === 'string') return part;
      if (typeof part?.text === 'string') return part.text;
      if (typeof part?.content === 'string') return part.content;
      return '';
    }).filter(Boolean).join('\n');
  }
  if (content == null) {
    return '';
  }
  try {
    return JSON.stringify(content);
  } catch {
    return String(content);
  }
}

async function readFileRange(filePath, start, end) {
  if (end < start) {
    return '';
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    const stream = fsSync.createReadStream(filePath, {
      encoding: 'utf8',
      start,
      end,
    });
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(chunks.join('')));
  });
}

export class SubagentActivityBridge {
  constructor({
    projectRoot = null,
    sessionId = null,
    onToolUse = null,
    onToolResult = null,
    intervalMs = POLL_INTERVAL_MS,
  } = {}) {
    this.projectRoot = projectRoot;
    this.sessionId = sessionId;
    this.onToolUse = onToolUse;
    this.onToolResult = onToolResult;
    this.intervalMs = intervalMs;
    this.timer = null;
    this.started = false;
    this.startedAtMs = 0;
    this.subagentsDir = null;
    this.files = new Map();
  }

  setSessionId(sessionId) {
    if (sessionId) {
      this.sessionId = sessionId;
    }
  }

  async start() {
    if (this.started || !this.projectRoot || !this.sessionId) {
      return;
    }
    const projectStoreDir = await resolveProjectStoreDir(this.projectRoot);
    if (!projectStoreDir) {
      return;
    }
    this.subagentsDir = path.join(projectStoreDir, this.sessionId, 'subagents');
    this.started = true;
    this.startedAtMs = Date.now();
    await this.seedExistingFiles();
    this.timer = setInterval(() => {
      void this.scan().catch((error) => {
        console.warn('[SubagentActivityBridge] scan failed:', error?.message || error);
      });
    }, this.intervalMs);
  }

  stop() {
    this.started = false;
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.files.clear();
  }

  async seedExistingFiles() {
    const entries = await fs.readdir(this.subagentsDir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isFile() || !AGENT_TRANSCRIPT_RE.test(entry.name)) {
        continue;
      }
      const filePath = path.join(this.subagentsDir, entry.name);
      const stats = await fs.stat(filePath).catch(() => null);
      const isRecentlyTouched = stats?.mtimeMs && stats.mtimeMs >= this.startedAtMs - 2000;
      this.files.set(filePath, {
        offset: isRecentlyTouched ? 0 : (stats?.size || 0),
        buffer: '',
      });
    }
  }

  async scan() {
    if (!this.started || !this.subagentsDir) {
      return;
    }

    const entries = await fs.readdir(this.subagentsDir, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (!entry.isFile() || !AGENT_TRANSCRIPT_RE.test(entry.name)) {
        continue;
      }
      const filePath = path.join(this.subagentsDir, entry.name);
      if (!this.files.has(filePath)) {
        this.files.set(filePath, { offset: 0, buffer: '' });
      }
      await this.readNewLines(filePath);
    }
  }

  async readNewLines(filePath) {
    const state = this.files.get(filePath);
    if (!state) {
      return;
    }

    const stats = await fs.stat(filePath).catch(() => null);
    if (!stats) {
      return;
    }
    if (stats.size < state.offset) {
      state.offset = 0;
      state.buffer = '';
    }
    if (stats.size === state.offset) {
      return;
    }

    const chunk = await readFileRange(filePath, state.offset, stats.size - 1);
    state.offset = stats.size;
    if (!chunk) {
      return;
    }

    const combined = state.buffer + chunk;
    const complete = combined.endsWith('\n') || combined.endsWith('\r');
    const lines = combined.split(/\r?\n/);
    state.buffer = complete ? '' : (lines.pop() || '');

    for (const line of lines) {
      if (!line.trim()) {
        continue;
      }
      this.processLine(filePath, line);
    }
  }

  processLine(filePath, line) {
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return;
    }

    const agentId = entry.agentId || path.basename(filePath).replace(/^agent-|\.jsonl$/gi, '');
    const timestamp = entry.timestamp || new Date().toISOString();
    const parts = Array.isArray(entry.message?.content) ? entry.message.content : [];

    if (entry.message?.role === 'assistant') {
      for (const part of parts) {
        if (part?.type !== 'tool_use') {
          continue;
        }
        this.onToolUse?.({
          agentId,
          transcriptPath: filePath,
          timestamp,
          toolId: part.id || '',
          toolName: part.name || 'UnknownTool',
          toolInput: part.input || {},
        });
      }
      return;
    }

    if (entry.message?.role === 'user') {
      for (const part of parts) {
        if (part?.type !== 'tool_result') {
          continue;
        }
        this.onToolResult?.({
          agentId,
          transcriptPath: filePath,
          timestamp,
          toolId: part.tool_use_id || '',
          content: partContentToString(part.content),
          isError: Boolean(part.is_error),
        });
      }
    }
  }
}
