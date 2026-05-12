import crypto from 'crypto';
import { createNormalizedMessage } from '../providers/types.js';
import { appendActivitySummary } from './activity-traces.js';

const PROVIDER = 'claude';
const HEARTBEAT_AFTER_MS = 8000;
const HEARTBEAT_INTERVAL_MS = 2000;
const MAX_DETAIL_LENGTH = 220;
const MAX_KEY_STEPS = 16;

function nowIso() {
  return new Date().toISOString();
}

function truncate(value, maxLength = MAX_DETAIL_LENGTH) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (text.length <= maxLength) {
    return text;
  }
  return `${text.slice(0, maxLength - 1)}…`;
}

function parseMaybeJson(value) {
  if (value && typeof value === 'object') {
    return value;
  }
  if (typeof value !== 'string') {
    return {};
  }
  try {
    return JSON.parse(value);
  } catch {
    return {};
  }
}

function extractPath(input, keys = ['file_path', 'path', 'notebook_path']) {
  const obj = parseMaybeJson(input);
  for (const key of keys) {
    if (typeof obj[key] === 'string' && obj[key].trim()) {
      return obj[key].trim();
    }
  }
  return '';
}

function basename(value) {
  const text = String(value || '').trim();
  if (!text) {
    return '';
  }
  return text.split(/[\\/]/).filter(Boolean).pop() || text;
}

function readToolContent(message) {
  const result = message?.toolResult;
  if (result && typeof result === 'object') {
    return String(result.content || '');
  }
  return String(message?.content || '');
}

function describeToolUse(message) {
  const toolName = message?.toolName || 'Tool';
  const input = parseMaybeJson(message?.toolInput);
  const filePath = extractPath(input);

  if (isRagSearchTool(message)) {
    return {
      phase: 'rag',
      title: '正在检索资料',
      detail: truncate(input.description || input.query || input.command || '使用 9GClaw RAG 检索资料'),
    };
  }

  switch (toolName) {
    case 'Read':
      return {
        phase: 'tool',
        title: `正在读取 ${basename(filePath) || '文件'}`,
        detail: filePath,
      };
    case 'Write':
      return {
        phase: 'tool',
        title: `正在写入 ${basename(filePath) || '文件'}`,
        detail: filePath,
      };
    case 'Edit':
    case 'MultiEdit':
      return {
        phase: 'tool',
        title: `正在编辑 ${basename(filePath) || '文件'}`,
        detail: filePath,
      };
    case 'Bash':
      return {
        phase: 'tool',
        title: '正在执行命令',
        detail: truncate(input.description || input.command || ''),
      };
    case 'Task':
      return {
        phase: 'subtask',
        title: '正在启动子任务',
        detail: truncate(input.description || input.prompt || ''),
      };
    case 'Skill':
      return {
        phase: 'tool',
        title: `正在调用 ${toolName}`,
        detail: truncate(input.skill || input.command || ''),
      };
    default:
      return {
        phase: 'tool',
        title: `正在调用 ${toolName}`,
        detail: truncate(filePath || input.description || input.command || ''),
      };
  }
}

function isRagSearchTool(message) {
  const toolName = message?.toolName || '';
  const input = parseMaybeJson(message?.toolInput);
  const joined = [
    toolName,
    input.skill,
    input.command,
    input.description,
    input.query,
  ].filter(Boolean).join(' ');
  return /9gclaw-rag|edgeclaw-rag-plugin|glm_web_search|local_knowledge_search|rag-research/i.test(joined);
}

function isSearchActivity(activity) {
  return activity?.phase === 'rag' || /检索|search/i.test(`${activity?.title || ''} ${activity?.detail || ''}`);
}

function extractCompactDetail(message) {
  const progress = message?.compactProgress || {};
  const level = progress.level || message?.compactLevel;
  const label = progress.label || message?.compactStageLabel || '上下文压缩';
  if (level) {
    return `Level ${level}: ${label}`;
  }
  return label;
}

export class ActivityTracker {
  constructor({ ws, sessionId = null, projectRoot = null, sessionSummary = '' } = {}) {
    this.ws = ws;
    this.sessionId = sessionId;
    this.projectRoot = projectRoot;
    this.sessionSummary = sessionSummary;
    this.runId = `run_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
    this.startedAt = nowIso();
    this.lastEventAt = Date.now();
    this.activities = [];
    this.activitiesById = new Map();
    this.toolActivities = new Map();
    this.streamActivitySent = false;
    this.completed = false;
    this.heartbeatTimer = null;
  }

  start() {
    this.emit({
      activityId: `${this.runId}:model_request`,
      phase: 'model_request',
      state: 'running',
      title: '正在请求模型',
      detail: this.sessionSummary || '',
      severity: 'info',
    });
    this.heartbeatTimer = setInterval(() => this.emitHeartbeatIfStale(), HEARTBEAT_INTERVAL_MS);
  }

  setSessionId(sessionId) {
    if (sessionId) {
      this.sessionId = sessionId;
    }
  }

  observe(message) {
    if (!message || this.completed) {
      return;
    }

    switch (message.kind) {
      case 'thinking':
        this.emit({
          activityId: `${this.runId}:thinking`,
          phase: 'thinking',
          state: 'running',
          title: '正在分析下一步',
          detail: '',
          severity: 'info',
        });
        break;
      case 'stream_delta':
        if (!this.streamActivitySent) {
          this.streamActivitySent = true;
          this.emit({
            activityId: `${this.runId}:stream`,
            phase: 'generation',
            state: 'running',
            title: '正在生成回复',
            detail: '',
            severity: 'info',
          });
        }
        break;
      case 'tool_use':
        this.observeToolUse(message);
        break;
      case 'tool_result':
        this.observeToolResult(message);
        break;
      case 'status':
        if (message.text === 'compacting') {
          this.emit({
            activityId: `${this.runId}:compact`,
            phase: 'compact',
            state: 'running',
            title: '正在压缩上下文',
            detail: extractCompactDetail(message),
            severity: 'info',
          });
        } else if (message.text === 'waiting_for_permission') {
          this.emitPermission(message);
        }
        break;
      case 'permission_request':
        this.emitPermission(message);
        break;
      case 'compact_boundary':
        this.emit({
          activityId: `${this.runId}:compact`,
          phase: 'compact',
          state: 'completed',
          title: '上下文已压缩',
          detail: message.preTokens ? `压缩前 ${message.preTokens} tokens` : '',
          severity: 'info',
        });
        break;
      case 'error':
        this.emit({
          activityId: `${this.runId}:error`,
          phase: 'error',
          state: 'failed',
          title: '请求出错',
          detail: truncate(message.content || ''),
          severity: 'error',
        });
        break;
      default:
        break;
    }
  }

  observeToolUse(message) {
    const description = describeToolUse(message);
    const activityId = `${this.runId}:tool:${message.toolId || message.id || crypto.randomUUID()}`;
    this.toolActivities.set(message.toolId || message.id, activityId);
    this.emit({
      activityId,
      phase: description.phase,
      state: 'running',
      title: description.title,
      detail: description.detail,
      toolName: message.toolName,
      toolId: message.toolId || '',
      severity: 'info',
    });
  }

  observeToolResult(message) {
    const toolKey = message.toolId || message.id;
    const activityId = this.toolActivities.get(toolKey) || `${this.runId}:tool_result:${toolKey || crypto.randomUUID()}`;
    const existing = this.activitiesById.get(activityId);
    const failed = Boolean(message.isError || message.toolResult?.isError);
    const content = readToolContent(message);
    this.emit({
      activityId,
      phase: existing?.phase || 'tool',
      state: failed ? 'failed' : 'completed',
      title: failed ? 'Tool Error' : (existing?.title || '工具调用完成'),
      detail: failed ? truncate(stripToolUseErrorTags(content)) : (existing?.detail || ''),
      toolName: existing?.toolName || '',
      toolId: message.toolId || '',
      severity: failed ? 'warning' : 'info',
    });
  }

  emitPermission(message) {
    this.emit({
      activityId: `${this.runId}:permission:${message.requestId || 'pending'}`,
      phase: 'permission',
      state: 'running',
      title: '等待用户授权',
      detail: truncate(message.toolName || ''),
      severity: 'warning',
    });
  }

  emitHeartbeatIfStale() {
    if (this.completed) {
      return;
    }
    const elapsed = Date.now() - this.lastEventAt;
    if (elapsed < HEARTBEAT_AFTER_MS) {
      return;
    }
    const seconds = Math.max(8, Math.round(elapsed / 1000));
    this.emit({
      activityId: `${this.runId}:provider_wait`,
      phase: 'provider_wait',
      state: 'running',
      title: '等待模型返回',
      detail: `已等待 ${seconds}s`,
      severity: 'info',
      updateLastEvent: false,
    });
  }

  async complete(status = 'completed') {
    if (this.completed) {
      return;
    }
    this.completed = true;
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }

    const endedAt = nowIso();
    const state = status === 'failed' ? 'failed' : status === 'cancelled' ? 'cancelled' : 'completed';
    this.emit({
      activityId: `${this.runId}:complete`,
      phase: 'complete',
      state,
      title: state === 'completed' ? '任务已完成' : state === 'cancelled' ? '已停止' : '任务未完成',
      detail: '',
      severity: state === 'failed' ? 'error' : 'info',
      endedAt,
    });

    const summary = this.createSummary({ status: state, endedAt });
    const summaryMessage = this.createMessage({
      kind: 'agent_activity_summary',
      id: `activity_summary_${this.runId}`,
      ...summary,
    });
    this.send(summaryMessage);

    if (this.projectRoot && this.sessionId) {
      try {
        await appendActivitySummary(this.projectRoot, this.sessionId, summary);
      } catch (error) {
        console.warn('[ActivityTracker] Failed to persist summary:', error?.message || error);
      }
    }
  }

  createSummary({ status, endedAt }) {
    const latestActivities = Array.from(this.activitiesById.values());
    const toolActivities = latestActivities.filter((activity) => activity.toolName || activity.phase === 'tool' || activity.phase === 'subtask' || activity.phase === 'rag');
    const toolErrors = latestActivities.filter((activity) => activity.state === 'failed' || activity.severity === 'error');
    const ragSearches = latestActivities.filter(isSearchActivity);
    const compacts = latestActivities.filter((activity) => activity.phase === 'compact' && activity.state === 'completed');
    const keySteps = this.activities
      .filter((activity) => activity.title && activity.phase !== 'provider_wait')
      .slice(-MAX_KEY_STEPS)
      .map((activity) => ({
        activityId: activity.activityId,
        phase: activity.phase,
        state: activity.state,
        title: activity.title,
        detail: activity.detail || '',
        toolName: activity.toolName || '',
        severity: activity.severity || 'info',
        startedAt: activity.startedAt,
        endedAt: activity.endedAt || null,
        durationMs: activity.durationMs || null,
      }));

    return {
      runId: this.runId,
      sessionId: this.sessionId || '',
      startedAt: this.startedAt,
      endedAt,
      durationMs: Math.max(0, Date.parse(endedAt) - Date.parse(this.startedAt)),
      status,
      toolCallCount: toolActivities.length,
      toolErrorCount: toolErrors.length,
      ragSearchCount: ragSearches.length,
      compactCount: compacts.length,
      keySteps,
    };
  }

  emit(activity) {
    const startedAt = activity.startedAt || this.activitiesById.get(activity.activityId)?.startedAt || nowIso();
    const endedAt = activity.endedAt || (activity.state === 'completed' || activity.state === 'failed' || activity.state === 'cancelled' ? nowIso() : null);
    const durationMs = endedAt ? Math.max(0, Date.parse(endedAt) - Date.parse(startedAt)) : null;
    const normalized = {
      runId: this.runId,
      activityId: activity.activityId,
      phase: activity.phase,
      state: activity.state,
      title: activity.title,
      detail: activity.detail || '',
      toolName: activity.toolName || '',
      toolId: activity.toolId || '',
      startedAt,
      endedAt,
      durationMs,
      severity: activity.severity || 'info',
    };

    this.activitiesById.set(normalized.activityId, normalized);
    this.activities.push(normalized);
    if (activity.updateLastEvent !== false) {
      this.lastEventAt = Date.now();
    }
    this.send(this.createMessage({ kind: 'agent_activity', ...normalized }));
  }

  createMessage(fields) {
    return createNormalizedMessage({
      ...fields,
      provider: PROVIDER,
      sessionId: this.sessionId || '',
    });
  }

  send(message) {
    try {
      this.ws?.send?.(message);
    } catch (error) {
      console.warn('[ActivityTracker] Failed to send activity event:', error?.message || error);
    }
  }
}

function stripToolUseErrorTags(value) {
  return String(value || '')
    .replace(/<\/?tool_use_error>/g, '')
    .trim();
}
