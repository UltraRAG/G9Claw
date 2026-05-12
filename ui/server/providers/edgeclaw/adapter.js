/**
 * 9GClaw provider adapter.
 *
 * Normalizes Claude Agent SDK events and JSONL session history into the
 * provider-neutral NormalizedMessage format used by the UI. The folder is
 * named `edgeclaw` for protocol compatibility, but the SessionProvider key on the
 * wire is still `'claude'` (see PROVIDER below) so renaming the folder does
 * not break protocol compatibility with the frontend.
 *
 * @module adapters/edgeclaw
 */

import { getSessionMessages } from '../../projects.js';
import { readActivitySummaries } from '../../services/activity-traces.js';
import { createNormalizedMessage, generateMessageId } from '../types.js';
import { extractSlashCommandInvocation, isInternalContent, isInterruptedNotice } from '../utils.js';

const PROVIDER = 'claude';
const TASK_NOTIFICATION_OUTER = /<task-notification>([\s\S]*?)<\/task-notification>/i;
const TASK_FIELD_REGEX = {
  taskId: /<task-id>([\s\S]*?)<\/task-id>/i,
  outputFile: /<output-file>([\s\S]*?)<\/output-file>/i,
  status: /<status>([\s\S]*?)<\/status>/i,
  summary: /<summary>([\s\S]*?)<\/summary>/i,
  result: /<result>([\s\S]*?)<\/result>/i,
};

function asArray(value) {
  return Array.isArray(value) ? value : [value];
}

function getTimestamp(raw) {
  return raw?.timestamp || raw?.created_at || raw?.createdAt || new Date().toISOString();
}

function getBaseId(raw, suffix = '') {
  const id = raw?.uuid || raw?.id || raw?.message?.id || generateMessageId('claude');
  return suffix ? `${id}_${suffix}` : id;
}

function stringifyContent(value) {
  if (value === undefined || value === null) {
    return '';
  }

  if (typeof value === 'string') {
    return value;
  }

  if (Array.isArray(value)) {
    return value
      .map((part) => {
        if (typeof part === 'string') {
          return part;
        }
        if (typeof part?.text === 'string') {
          return part.text;
        }
        if (typeof part?.content === 'string') {
          return part.content;
        }
        return '';
      })
      .filter(Boolean)
      .join('\n');
  }

  if (typeof value.text === 'string') {
    return value.text;
  }
  if (typeof value.content === 'string') {
    return value.content;
  }

  // Defense in depth: never serialize binary attachment blocks via
  // JSON.stringify. The base64 payload is huge and should never end up in a
  // chat bubble. Callers that genuinely need a label for an attachment part
  // should use describeAttachmentPart() instead.
  if (value.type === 'image' || value.type === 'document') {
    return '';
  }

  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

// Anthropic content blocks can carry binary attachments alongside text:
//   { type: 'image',    source: { type: 'base64', media_type, data } }
//   { type: 'document', source: { type: 'base64', media_type, data } }  // PDFs
// Without this helper, the user-message normalizer falls through to
// JSON.stringify(part) and ends up rendering raw base64 as a chat bubble.
function describeAttachmentPart(part) {
  if (!part || typeof part !== 'object') return null;
  if (part.type !== 'image' && part.type !== 'document') return null;

  const source = part.source || {};
  const mediaType =
    typeof source.media_type === 'string'
      ? source.media_type
      : typeof part.media_type === 'string'
        ? part.media_type
        : '';
  const filename =
    typeof part.filename === 'string'
      ? part.filename
      : typeof part.name === 'string'
        ? part.name
        : typeof part.title === 'string'
          ? part.title
          : '';
  const url =
    source.type === 'url' && typeof source.url === 'string' ? source.url : '';

  // Use type-specific glyphs so the user can tell a PDF/document attachment
  // apart from an image at a glance. The generic 📎 paperclip used previously
  // was ambiguous (it implies "attachment" in general but reads identically
  // for any kind of file).
  let icon;
  let label;
  if (part.type === 'image') {
    icon = '🖼';
    label = mediaType ? `Image (${mediaType})` : 'Image';
  } else {
    // document — most commonly application/pdf, but Claude also accepts
    // text/plain, text/markdown, etc. via the document block.
    icon = '📄';
    if (/pdf/i.test(mediaType)) {
      label = 'PDF';
    } else if (mediaType) {
      label = `Document (${mediaType})`;
    } else {
      label = 'Document';
    }
  }

  const detail = filename || url;
  return detail ? `${icon} ${label}: ${detail}` : `${icon} ${label}`;
}

function imageFromAttachmentPart(part, index) {
  if (!part || typeof part !== 'object' || part.type !== 'image') {
    return null;
  }

  const source = part.source || {};
  const mediaType =
    typeof source.media_type === 'string'
      ? source.media_type
      : typeof part.media_type === 'string'
        ? part.media_type
        : 'image/png';
  let data = '';
  if (source.type === 'base64' && typeof source.data === 'string') {
    data = source.data.startsWith('data:')
      ? source.data
      : `data:${mediaType};base64,${source.data}`;
  } else if (source.type === 'url' && typeof source.url === 'string') {
    data = source.url;
  }

  if (!data) {
    return null;
  }

  const extension = mediaType.split('/')[1] || 'png';
  return {
    data,
    name:
      typeof part.filename === 'string'
        ? part.filename
        : typeof part.name === 'string'
          ? part.name
          : `image-${index + 1}.${extension}`,
    mimeType: mediaType,
  };
}

function parseTaskNotification(content) {
  if (typeof content !== 'string' || content.trim().length === 0) {
    return null;
  }

  const outer = content.match(TASK_NOTIFICATION_OUTER);
  if (!outer) {
    return null;
  }

  const body = outer[1];
  const extract = (regex) => {
    const m = body.match(regex);
    return m ? m[1].trim() : '';
  };

  return {
    taskId: extract(TASK_FIELD_REGEX.taskId),
    outputFile: extract(TASK_FIELD_REGEX.outputFile),
    status: extract(TASK_FIELD_REGEX.status),
    summary: extract(TASK_FIELD_REGEX.summary),
    result: extract(TASK_FIELD_REGEX.result),
  };
}

function normalizeCompactProgress(raw) {
  const source =
    raw?.compact_progress ||
    raw?.compactProgress ||
    raw?.compactMetadata ||
    raw?.metadata?.compact_progress ||
    raw?.metadata?.compactProgress ||
    (raw?.level || raw?.stage || raw?.label ? raw : null);

  if (!source || typeof source !== 'object') {
    return null;
  }

  const level = Number(source.level);
  const stage = typeof source.stage === 'string' ? source.stage : '';
  const label =
    typeof source.label === 'string'
      ? source.label
      : typeof source.stage_label === 'string'
        ? source.stage_label
        : typeof source.stageLabel === 'string'
          ? source.stageLabel
          : stage;
  const state =
    typeof source.state === 'string' && source.state
      ? source.state
      : 'running';
  const preTokens =
    typeof source.pre_tokens === 'number'
      ? source.pre_tokens
      : typeof source.preTokens === 'number'
        ? source.preTokens
        : undefined;
  const reason =
    typeof source.reason === 'string' && source.reason
      ? source.reason
      : undefined;

  if (!Number.isFinite(level) || level <= 0 || !stage) {
    return null;
  }

  return {
    level,
    stage,
    label,
    state,
    ...(typeof preTokens === 'number' && { pre_tokens: preTokens }),
    ...(reason && { reason }),
  };
}

function formatApiErrorContent(raw) {
  const errorCode =
    raw?.error?.cause?.code ||
    raw?.cause?.code ||
    raw?.error?.code ||
    raw?.code ||
    'unknown';
  const errorPath = raw?.error?.cause?.path || raw?.cause?.path || raw?.path || '';
  const retryAttempt =
    typeof raw?.retryAttempt === 'number' && typeof raw?.maxRetries === 'number'
      ? ` Retry ${raw.retryAttempt}/${raw.maxRetries}.`
      : '';
  const target = errorPath ? ` (${errorPath})` : '';
  return `API error: ${errorCode}${target}.${retryAttempt}`;
}

function repairMojibakeFilename(name) {
  const original = String(name || '').trim();
  if (!original) return original;
  try {
    const decoded = Buffer.from(original, 'latin1').toString('utf8');
    const looksMojibake = /[ÃÂÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ]/.test(original);
    if (looksMojibake && decoded && !decoded.includes('�')) {
      return decoded;
    }
  } catch {
    // Leave the original string when transcoding is not applicable.
  }
  return original;
}

function inferAttachmentMimeType(name = '', filePath = '') {
  const ext = String(name || filePath).split('.').pop()?.toLowerCase() || '';
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'txt':
    case 'md':
    case 'csv':
      return 'text/plain';
    default:
      return 'application/octet-stream';
  }
}

function parseUserAttachmentNote(content) {
  const marker = '[Files attached by user and available for reading in the project:]';
  const markerIndex = String(content || '').indexOf(marker);
  if (markerIndex < 0) {
    return { content, attachments: [] };
  }

  const visibleContent = String(content).slice(0, markerIndex).trimEnd();
  const note = String(content).slice(markerIndex + marker.length);
  const attachments = [];

  for (const rawLine of note.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line.startsWith('- ')) continue;
    const separator = line.indexOf(': ');
    if (separator < 0) continue;
    const rawName = line.slice(2, separator).trim();
    const filePath = line.slice(separator + 2).trim();
    if (!rawName || !filePath) continue;
    const name = repairMojibakeFilename(rawName);
    attachments.push({
      name,
      path: filePath,
      mimeType: inferAttachmentMimeType(name, filePath),
    });
  }

  return { content: visibleContent, attachments };
}

function createTextMessage({ id, sessionId, timestamp, role, content, images = [], attachments = [] }) {
  if (role === 'user') {
    const parsed = parseUserAttachmentNote(content);
    content = parsed.content;
    attachments = [...attachments, ...parsed.attachments];
  }

  const taskNotification = parseTaskNotification(content);
  if (taskNotification) {
    return createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'task_notification',
      status: taskNotification.status || 'completed',
      summary: taskNotification.summary || 'Background task update',
      taskResult: taskNotification.result,
      taskId: taskNotification.taskId,
      outputFile: taskNotification.outputFile,
    });
  }

  // Surface SDK-injected "[Request interrupted by user]" notices as a dedicated
  // message kind so the UI can show a visible divider where the user paused.
  if (isInterruptedNotice(content)) {
    return createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'interrupted',
      content,
    });
  }

  if (role === 'user') {
    const slashCommand = extractSlashCommandInvocation(content);
    if (slashCommand) {
      content = slashCommand;
    } else if (isInternalContent(content)) {
      return null;
    }
  }

  if (!content.trim() && images.length === 0 && attachments.length === 0) {
    return null;
  }

  const message = createNormalizedMessage({
    id,
    sessionId,
    timestamp,
    provider: PROVIDER,
    kind: 'text',
    role,
    content,
  });

  if (role === 'user' && images.length > 0) {
    message.images = images;
  }

  if (role === 'user' && attachments.length > 0) {
    message.attachments = attachments;
  }

  return message;
}

function normalizeContentPart(part, raw, sessionId, partIndex, options) {
  const timestamp = getTimestamp(raw);
  const id = getBaseId(raw, partIndex);
  const isStreamingPart = Boolean(raw?.delta || raw?.isPartial || raw?.partial);

  if (typeof part === 'string') {
    if (options.skipStreamedText && !isStreamingPart) {
      return [];
    }

    const content = part;
    if (!content.trim()) {
      return [];
    }

    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: isStreamingPart ? 'stream_delta' : 'text',
      role: 'assistant',
      content,
    })];
  }

  switch (part?.type) {
    case 'text': {
      if (options.skipStreamedText && !isStreamingPart) {
        return [];
      }

      const content = stringifyContent(part.text);
      if (!content.trim()) {
        return [];
      }

      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: isStreamingPart ? 'stream_delta' : 'text',
        role: 'assistant',
        content,
      })];
    }

    case 'thinking':
    case 'redacted_thinking': {
      if (options.skipStreamedText && !isStreamingPart) {
        return [];
      }

      const content = stringifyContent(part.thinking || part.text || part.content);
      if (!content.trim()) {
        return [];
      }

      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'thinking',
        content,
      })];
    }

    case 'tool_use': {
      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'tool_use',
        toolName: part.name || 'UnknownTool',
        toolInput: part.input ?? {},
        toolId: part.id || id,
        toolUseResult: raw?.toolUseResult,
        subagentTools: raw?.subagentTools,
      })];
    }

    case 'tool_result': {
      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'tool_result',
        toolId: part.tool_use_id || part.id || '',
        content: stringifyContent(part.content),
        isError: Boolean(part.is_error),
      })];
    }

    default:
      return [];
  }
}

function normalizeUserMessage(raw, sessionId, options) {
  if (options.includeUserText === false) {
    return [];
  }

  // SDK-injected continuation messages (skill briefings, slash-command echoes,
  // PDF page rasterizations fed back to the model, etc.) carry isMeta=true.
  // They are not real user input — hide them from the chat surface, mirroring
  // how we drop synthetic assistant messages in normalizeAssistantMessage.
  if (raw?.isMeta === true && options.sessionKind !== 'background_task') {
    return [];
  }

  const timestamp = getTimestamp(raw);
  const content = raw?.message?.content ?? raw?.content ?? '';
  const normalized = [];

  if (Array.isArray(content)) {
    const textParts = [];
    const images = [];

    content.forEach((part, index) => {
      if (part?.type === 'tool_result') {
        normalized.push(...normalizeContentPart(part, raw, sessionId, index, options));
        return;
      }

      const image = imageFromAttachmentPart(part, index);
      if (image) {
        images.push(image);
        return;
      }

      const attachmentLabel = describeAttachmentPart(part);
      if (attachmentLabel) {
        textParts.push(attachmentLabel);
        return;
      }

      const text = stringifyContent(part);
      if (text.trim()) {
        textParts.push(text);
      }
    });

    const message = createTextMessage({
      id: getBaseId(raw),
      sessionId,
      timestamp,
      role: 'user',
      content: textParts.join('\n'),
      images,
    });
    if (message) {
      normalized.push(message);
    }
    return normalized;
  }

  const message = createTextMessage({
    id: getBaseId(raw),
    sessionId,
    timestamp,
    role: 'user',
    content: stringifyContent(content),
  });
  return message ? [message] : [];
}

function normalizeAssistantMessage(raw, sessionId, options) {
  if (raw?.isApiErrorMessage === true) {
    const timestamp = getTimestamp(raw);
    const content = stringifyContent(raw?.message?.content ?? raw?.content);
    return [createNormalizedMessage({
      id: getBaseId(raw),
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'error',
      content: content.trim() || formatApiErrorContent(raw),
    })];
  }

  // The Claude Agent SDK uses `model: '<synthetic>'` to mark assistant
  // placeholders that it injects to keep the user/assistant turn pairing
  // valid for the API (e.g. `No response requested.` after an interrupted
  // turn, see conversationRecovery in claude-code-main). These have no real
  // model output and would otherwise render as a confusing empty/duplicate
  // assistant bubble alongside our `interrupted` divider, so drop them.
  if (raw?.message?.model === '<synthetic>') {
    return [];
  }

  const content = raw?.message?.content ?? raw?.content ?? '';

  if (Array.isArray(content)) {
    return content.flatMap((part, index) => normalizeContentPart(part, raw, sessionId, index, options));
  }

  return normalizeContentPart(content, raw, sessionId, 0, options);
}

// Claude Agent SDK wraps every Anthropic SSE delta in `{ type: 'stream_event', event }`
// when `includePartialMessages: true` is set. Without unwrapping the inner `event`
// the UI only renders the final assistant message in one shot, so we surface
// `text_delta` parts as `stream_delta` NormalizedMessages here.
function normalizeStreamEvent(raw, sessionId) {
  const inner = raw?.event;
  if (!inner || typeof inner !== 'object') return [];

  const timestamp = getTimestamp(raw);
  const baseId = getBaseId(raw);
  const blockIndex = typeof inner.index === 'number' ? inner.index : 0;

  if (inner.type === 'content_block_delta') {
    const delta = inner.delta;
    if (!delta || typeof delta !== 'object') return [];

    if (delta.type === 'text_delta' && typeof delta.text === 'string' && delta.text.length > 0) {
      return [createNormalizedMessage({
        id: `${baseId}_${blockIndex}_text`,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'stream_delta',
        content: delta.text,
      })];
    }
  }

  // Other inner events (message_start / content_block_start / content_block_stop /
  // message_delta / message_stop / thinking_delta / input_json_delta) are not
  // consumed by the current UI streaming path. The final SDKAssistantMessage
  // delivered after `message_stop` already carries the complete content for
  // tool_use / thinking blocks, so dropping them here is safe.
  return [];
}

function normalizeDirectEvent(raw, sessionId, options) {
  const timestamp = getTimestamp(raw);
  const id = getBaseId(raw);

  if (raw.type === 'system' && raw.subtype === 'status') {
    if (raw.status === 'compacting') {
      const compactProgress = normalizeCompactProgress(raw);
      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'status',
        text: 'compacting',
        tokens: 0,
        canInterrupt: true,
        ...(compactProgress && { compactProgress }),
      })];
    }

    if (raw.status === null) {
      return [createNormalizedMessage({
        id,
        sessionId,
        timestamp,
        provider: PROVIDER,
        kind: 'status',
        text: 'clear_status',
        tokens: 0,
        canInterrupt: false,
      })];
    }

    return [];
  }

  if (raw.type === 'system' && raw.subtype === 'compact_boundary') {
    const metadata = raw.compact_metadata || raw.compactMetadata || {};
    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'compact_boundary',
      trigger: metadata.trigger || raw.trigger || 'auto',
      preTokens: metadata.pre_tokens ?? metadata.preTokens,
      compactLevel: metadata.level,
      compactStage: metadata.stage,
      compactStageLabel: metadata.stage_label || metadata.stageLabel,
      compactMetadata: metadata,
    })];
  }

  if (raw.type === 'system' && raw.subtype === 'api_error') {
    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'error',
      content: formatApiErrorContent(raw),
    })];
  }

  if (raw.type === 'stream_event') {
    return normalizeStreamEvent(raw, sessionId);
  }

  if (raw.type === 'stream_delta' || raw.type === 'content_block_delta' || raw.type === 'assistant_delta') {
    const content = stringifyContent(raw.text ?? raw.delta?.text ?? raw.delta ?? raw.content);
    if (!content.trim()) {
      return [];
    }
    return [createNormalizedMessage({ id, sessionId, timestamp, provider: PROVIDER, kind: 'stream_delta', content })];
  }

  if (raw.type === 'tool_use') {
    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'tool_use',
      toolName: raw.name || raw.toolName || 'UnknownTool',
      toolInput: raw.input ?? raw.toolInput ?? {},
      toolId: raw.tool_use_id || raw.toolId || raw.id || id,
      toolUseResult: raw.toolUseResult,
      subagentTools: raw.subagentTools,
    })];
  }

  if (raw.type === 'tool_result') {
    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'tool_result',
      toolId: raw.tool_use_id || raw.toolId || '',
      content: stringifyContent(raw.content ?? raw.output),
      isError: Boolean(raw.is_error || raw.isError),
    })];
  }

  if (raw.type === 'result') {
    return [createNormalizedMessage({ id, sessionId, timestamp, provider: PROVIDER, kind: 'stream_end' })];
  }

  if (raw.type === 'error') {
    return [createNormalizedMessage({
      id,
      sessionId,
      timestamp,
      provider: PROVIDER,
      kind: 'error',
      content: raw.error?.message || raw.message || 'Unknown Claude error',
    })];
  }

  return [];
}

function attachToolResults(messages) {
  const toolResultMap = new Map();

  for (const message of messages) {
    if (message.kind === 'tool_result' && message.toolId) {
      toolResultMap.set(message.toolId, message);
    }
  }

  for (const message of messages) {
    if (message.kind === 'tool_use' && message.toolId && toolResultMap.has(message.toolId)) {
      const toolResult = toolResultMap.get(message.toolId);
      message.toolResult = {
        content: toolResult.content,
        isError: toolResult.isError,
        toolUseResult: toolResult.toolUseResult,
      };
    }
  }

  return messages;
}

function normalizeActivitySummary(summary, sessionId) {
  if (!summary || typeof summary !== 'object') {
    return null;
  }
  return createNormalizedMessage({
    id: `activity_summary_${summary.runId || generateMessageId('activity')}`,
    sessionId,
    timestamp: summary.endedAt || summary.startedAt || new Date().toISOString(),
    provider: PROVIDER,
    kind: 'agent_activity_summary',
    runId: summary.runId || '',
    startedAt: summary.startedAt || '',
    endedAt: summary.endedAt || '',
    durationMs: summary.durationMs || 0,
    status: summary.status || 'completed',
    toolCallCount: summary.toolCallCount || 0,
    toolErrorCount: summary.toolErrorCount || 0,
    ragSearchCount: summary.ragSearchCount || 0,
    compactCount: summary.compactCount || 0,
    keySteps: Array.isArray(summary.keySteps) ? summary.keySteps : [],
  });
}

/**
 * Normalize a raw Claude event or JSONL entry into NormalizedMessage(s).
 * @param {object} raw
 * @param {string} sessionId
 * @param {{includeUserText?: boolean, skipStreamedText?: boolean}} [options]
 * @returns {import('../types.js').NormalizedMessage[]}
 */
export function normalizeMessage(raw, sessionId, options = {}) {
  if (!raw || typeof raw !== 'object') {
    return [];
  }

  const role = raw.message?.role || raw.role;
  if (role === 'user') {
    return normalizeUserMessage(raw, sessionId, options);
  }

  if (role === 'assistant' || raw.type === 'assistant') {
    return normalizeAssistantMessage(raw, sessionId, options);
  }

  return normalizeDirectEvent(raw, sessionId, options);
}

/**
 * @type {import('../types.js').ProviderAdapter}
 */
export const edgeclawAdapter = {
  normalizeMessage,

  /**
   * Fetch session history from Claude JSONL files.
   */
  async fetchHistory(sessionId, opts = {}) {
    const {
      projectName = '',
      limit = null,
      offset = 0,
      sessionKind = null,
      parentSessionId = null,
      relativeTranscriptPath = null,
      projectPath = '',
    } = opts;

    if (!projectName) {
      return { messages: [], total: 0, hasMore: false, offset: 0, limit };
    }

    let result;
    try {
      result = await getSessionMessages(projectName, sessionId, {
        limit,
        offset,
        sessionKind,
        parentSessionId,
        relativeTranscriptPath,
      });
    } catch (error) {
      console.warn(`[ClaudeAdapter] Failed to load session ${sessionId}:`, error.message);
      return { messages: [], total: 0, hasMore: false, offset: 0, limit };
    }

    const rawMessages = Array.isArray(result) ? result : (result.messages || []);
    const total = Array.isArray(result) ? rawMessages.length : (result.total || rawMessages.length);
    const hasMore = Array.isArray(result) ? false : Boolean(result.hasMore);
    const normalized = [];

    for (const raw of rawMessages) {
      normalized.push(...normalizeMessage(raw, sessionId, { sessionKind }));
    }

    if (projectPath) {
      const summaries = await readActivitySummaries(projectPath, sessionId);
      for (const summary of summaries) {
        const normalizedSummary = normalizeActivitySummary(summary, sessionId);
        if (normalizedSummary) {
          normalized.push(normalizedSummary);
        }
      }
      normalized.sort((a, b) => Date.parse(a.timestamp || '') - Date.parse(b.timestamp || ''));
    }

    return {
      messages: attachToolResults(normalized),
      total: total + (projectPath ? normalized.filter((message) => message.kind === 'agent_activity_summary').length : 0),
      hasMore,
      offset: Array.isArray(result) ? 0 : (result.offset ?? offset),
      limit: Array.isArray(result) ? null : (result.limit ?? limit),
      tokenUsage: result?.tokenUsage || null,
    };
  },
};
