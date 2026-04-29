import { promises as fs } from 'node:fs';
import path from 'node:path';

import { getAlwaysOnRoot } from './always-on-paths.js';
import { getAlwaysOnRunLog } from './always-on-run-logs.js';

const RUN_HISTORY_FILE_NAME = 'run-history.jsonl';
const RUN_HISTORY_MAX_ITEMS = 500;
const OUTPUT_LOG_MAX_CHARS = 60_000;
const VALID_KINDS = new Set(['plan', 'cron']);
const VALID_STATUSES = new Set(['queued', 'running', 'completed', 'failed', 'unknown']);

function normalizeString(value, fallback = '') {
  return typeof value === 'string' && value.trim() ? value.trim() : fallback;
}

function toIsoTimestamp(value) {
  const timestamp = value ? Date.parse(value) : NaN;
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : '';
}

function getRunHistoryPath(projectRoot) {
  return path.join(getAlwaysOnRoot(projectRoot), RUN_HISTORY_FILE_NAME);
}

function sanitizeMetadata(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value;
}

function normalizeRunEvent(event) {
  const runId = normalizeString(event?.runId);
  const kind = normalizeString(event?.kind);
  const status = normalizeString(event?.status);
  const sourceId = normalizeString(event?.sourceId);

  if (!runId || !VALID_KINDS.has(kind) || !VALID_STATUSES.has(status) || !sourceId) {
    return null;
  }

  const timestamp = toIsoTimestamp(event?.timestamp) || new Date().toISOString();

  return {
    runId,
    projectRoot: normalizeString(event?.projectRoot),
    kind,
    sourceId,
    title: normalizeString(event?.title, sourceId),
    status,
    timestamp,
    startedAt: toIsoTimestamp(event?.startedAt) || undefined,
    finishedAt: toIsoTimestamp(event?.finishedAt) || undefined,
    sessionId: normalizeString(event?.sessionId) || undefined,
    parentSessionId: normalizeString(event?.parentSessionId) || undefined,
    relativeTranscriptPath: normalizeString(event?.relativeTranscriptPath) || undefined,
    transcriptKey: normalizeString(event?.transcriptKey) || undefined,
    output: normalizeString(event?.output) || undefined,
    error: normalizeString(event?.error) || undefined,
    metadata: sanitizeMetadata(event?.metadata),
  };
}

function mergeRunEvent(record, event) {
  const metadata = {
    ...(record.metadata || {}),
    ...(event.metadata || {}),
  };

  const next = {
    ...record,
    title: event.title || record.title,
    status: event.status || record.status,
    updatedAt: event.timestamp || record.updatedAt,
    startedAt: event.startedAt || record.startedAt || event.timestamp,
    finishedAt: event.finishedAt || record.finishedAt,
    sessionId: event.sessionId || record.sessionId,
    parentSessionId: event.parentSessionId || record.parentSessionId,
    relativeTranscriptPath: event.relativeTranscriptPath || record.relativeTranscriptPath,
    transcriptKey: event.transcriptKey || record.transcriptKey,
    metadata,
  };

  const outputParts = [record.outputLog, event.output, event.error ? `Error: ${event.error}` : '']
    .filter(Boolean);
  next.outputLog = outputParts.join('\n\n').slice(-OUTPUT_LOG_MAX_CHARS);

  if (event.error) {
    next.error = event.error;
  }

  return next;
}

function createRecordFromEvent(event) {
  return mergeRunEvent({
    runId: event.runId,
    kind: event.kind,
    sourceId: event.sourceId,
    title: event.title,
    status: event.status,
    createdAt: event.timestamp,
    updatedAt: event.timestamp,
    startedAt: event.startedAt || event.timestamp,
    finishedAt: event.finishedAt,
    sessionId: event.sessionId,
    parentSessionId: event.parentSessionId,
    relativeTranscriptPath: event.relativeTranscriptPath,
    transcriptKey: event.transcriptKey,
    metadata: {},
    outputLog: '',
  }, event);
}

function toHistoryEntry(record) {
  return {
    runId: record.runId,
    title: record.title,
    kind: record.kind,
    status: record.status,
    startedAt: record.startedAt,
    sourceId: record.sourceId,
    session: {
      sessionId: record.sessionId,
      parentSessionId: record.parentSessionId,
      relativeTranscriptPath: record.relativeTranscriptPath,
    },
  };
}

function extractContentText(content) {
  if (typeof content === 'string') {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === 'string') return part;
        if (typeof part?.text === 'string') return part.text;
        if (typeof part?.content === 'string') return part.content;
        return '';
      })
      .filter(Boolean)
      .join('\n');
  }
  if (typeof content?.text === 'string') {
    return content.text;
  }
  return '';
}

function formatMessageForLog(entry) {
  const role = normalizeString(entry?.message?.role || entry?.type || entry?.role, 'message');
  const content = extractContentText(entry?.message?.content ?? entry?.content).trim();
  if (!content) {
    return '';
  }
  const timestamp = toIsoTimestamp(entry?.timestamp);
  const prefix = timestamp ? `[${timestamp}] ${role}` : role;
  return `${prefix}\n${content}`;
}

async function buildSessionOutputLog(projectName, record) {
  if (!projectName || !record.sessionId) {
    return '';
  }

  try {
    const { getSessionMessages } = await import('../projects.js');
    const result = await getSessionMessages(projectName, record.sessionId, {
      limit: null,
      offset: 0,
      sessionKind: record.parentSessionId && record.relativeTranscriptPath ? 'background_task' : null,
      parentSessionId: record.parentSessionId,
      relativeTranscriptPath: record.relativeTranscriptPath,
    });
    const messages = Array.isArray(result?.messages) ? result.messages : [];
    return messages
      .map(formatMessageForLog)
      .filter(Boolean)
      .join('\n\n')
      .slice(-OUTPUT_LOG_MAX_CHARS);
  } catch (error) {
    return '';
  }
}

async function readRunHistoryRecords(projectRoot) {
  let raw = '';
  try {
    raw = await fs.readFile(getRunHistoryPath(projectRoot), 'utf8');
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return [];
    }
    throw error;
  }

  const recordsById = new Map();
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) {
      continue;
    }

    try {
      const event = normalizeRunEvent(JSON.parse(line));
      if (!event) {
        continue;
      }
      const existing = recordsById.get(event.runId);
      recordsById.set(
        event.runId,
        existing ? mergeRunEvent(existing, event) : createRecordFromEvent(event),
      );
    } catch {
      // Concurrent appends or manual edits can leave bad lines; ignore them.
    }
  }

  return [...recordsById.values()].sort((left, right) => {
    const leftTime = Date.parse(left.startedAt || left.updatedAt || left.createdAt || '') || 0;
    const rightTime = Date.parse(right.startedAt || right.updatedAt || right.createdAt || '') || 0;
    return rightTime - leftTime;
  });
}

export async function appendAlwaysOnRunEvent(projectRoot, event) {
  const normalized = normalizeRunEvent({
    ...event,
    projectRoot,
  });
  if (!normalized) {
    return null;
  }

  await fs.mkdir(getAlwaysOnRoot(projectRoot), { recursive: true });
  await fs.appendFile(getRunHistoryPath(projectRoot), `${JSON.stringify(normalized)}\n`, 'utf8');
  return normalized;
}

export async function getAlwaysOnRunHistory(projectRoot, { limit = RUN_HISTORY_MAX_ITEMS } = {}) {
  const records = (await readRunHistoryRecords(projectRoot)).filter(
    (record) => record.status !== 'unknown',
  );
  const safeLimit = Number.isFinite(limit) && limit > 0 ? limit : RUN_HISTORY_MAX_ITEMS;
  return {
    runs: records.slice(0, safeLimit).map(toHistoryEntry),
  };
}

export async function getAlwaysOnRunHistoryDetail(projectRoot, runId, { projectName = '' } = {}) {
  const records = await readRunHistoryRecords(projectRoot);
  const record = records.find((candidate) => candidate.runId === runId);
  if (!record) {
    const error = new Error('Run history entry not found');
    error.code = 'NOT_FOUND';
    throw error;
  }

  const sessionOutput = await buildSessionOutputLog(projectName, record);
  const fileLog = await getAlwaysOnRunLog(projectRoot, runId);
  const outputLog = fileLog.content || sessionOutput || record.outputLog || record.error || '';
  const logSource = fileLog.content ? 'log-file' : (sessionOutput ? 'session' : 'history');
  return {
    ...toHistoryEntry(record),
    outputLog,
    metadata: {
      ...record.metadata,
      runId: record.runId,
      sourceId: record.sourceId,
      status: record.status,
      startedAt: record.startedAt,
      finishedAt: record.finishedAt,
      sessionId: record.sessionId,
      parentSessionId: record.parentSessionId,
      relativeTranscriptPath: record.relativeTranscriptPath,
      transcriptKey: record.transcriptKey,
      logSource,
      logUpdatedAt: fileLog.updatedAt,
      logSize: fileLog.size,
      logTruncated: fileLog.truncated,
    },
  };
}

export {
  getRunHistoryPath,
  readRunHistoryRecords,
};
