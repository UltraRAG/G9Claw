/**
 * Claude provider adapter.
 *
 * Normalizes Claude SDK session history into NormalizedMessage format.
 * @module adapters/claude
 */

import { getSessionMessages } from '../../projects.js';
import { createNormalizedMessage, generateMessageId } from '../types.js';
import { extractSlashCommandInvocation, isInternalContent } from '../utils.js';

const PROVIDER = 'claude';
const TASK_NOTIFICATION_REGEX = /<task-notification>\s*<task-id>([\s\S]*?)<\/task-id>\s*<output-file>([\s\S]*?)<\/output-file>\s*<status>([\s\S]*?)<\/status>\s*<summary>([\s\S]*?)<\/summary>\s*<\/task-notification>/i;

function extractTextContent(content) {
  if (typeof content === 'string') {
    return content;
  }

  if (!Array.isArray(content)) {
    return '';
  }

  return content
    .filter((part) => part?.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('\n');
}

function parseTaskNotificationContent(content) {
  if (typeof content !== 'string' || content.trim().length === 0) {
    return null;
  }

  const match = content.match(TASK_NOTIFICATION_REGEX);
  if (!match) {
    return null;
  }

  const [, taskId = '', outputFile = '', status = '', summary = ''] = match;
  return {
    taskId: taskId.trim(),
    outputFile: outputFile.trim(),
    status: status.trim(),
    summary: summary.trim(),
  };
}

function normalizeHistoryMessages(rawMessages, sessionId) {
  const toolResultMap = new Map();
  for (const raw of rawMessages) {
    if (raw.message?.role === 'user' && Array.isArray(raw.message?.content)) {
      for (const part of raw.message.content) {
        if (part.type === 'tool_result') {
          toolResultMap.set(part.tool_use_id, {
            content: part.content,
            isError: Boolean(part.is_error),
            timestamp: raw.timestamp,
            subagentTools: raw.subagentTools,
            toolUseResult: raw.toolUseResult,
          });
        }
      }
    }
  }

  const normalized = [];
  for (const raw of rawMessages) {
    const entries = normalizeMessage(raw, sessionId);
    normalized.push(...entries);
  }

  for (const msg of normalized) {
    if (msg.kind === 'tool_use' && msg.toolId && toolResultMap.has(msg.toolId)) {
      const tr = toolResultMap.get(msg.toolId);
      msg.toolResult = {
        content: typeof tr.content === 'string' ? tr.content : JSON.stringify(tr.content),
        isError: tr.isError,
        toolUseResult: tr.toolUseResult,
      };
      msg.subagentTools = tr.subagentTools;
    }
  }

  return normalized;
}

/**
 * Normalize a raw JSONL message or realtime SDK event into NormalizedMessage(s).
 * Handles both history entries (JSONL `{ message: { role, content } }`) and
 * realtime streaming events (`content_block_delta`, `content_block_stop`, etc.).
 * @param {object} raw - A single entry from JSONL or a live SDK event
 * @param {string} sessionId
 * @param {{ includeUserText?: boolean }} [options]
 * @returns {import('../types.js').NormalizedMessage[]}
 */
export function normalizeMessage(raw, sessionId, options = {}) {
  const { includeUserText = true } = options;
  // ── Streaming events (realtime) ──────────────────────────────────────────
  if (raw.type === 'content_block_delta' && raw.delta?.text) {
    return [createNormalizedMessage({ kind: 'stream_delta', content: raw.delta.text, sessionId, provider: PROVIDER })];
  }
  if (raw.type === 'content_block_stop') {
    return [createNormalizedMessage({ kind: 'stream_end', sessionId, provider: PROVIDER })];
  }

  // ── History / full-message events ────────────────────────────────────────
  const messages = [];
  const ts = raw.timestamp || new Date().toISOString();
  const baseId = raw.uuid || generateMessageId('claude');
  const taskNotification = raw.taskNotification ||
    parseTaskNotificationContent(extractTextContent(raw.message?.content));

  if (raw.message?.role === 'user' && raw.message?.content && taskNotification) {
    return [createNormalizedMessage({
      id: baseId,
      sessionId,
      timestamp: ts,
      provider: PROVIDER,
      kind: 'task_notification',
      status: taskNotification.status || 'completed',
      summary: taskNotification.summary || 'Background task update',
      taskId: taskNotification.taskId || '',
      outputFile: taskNotification.outputFile || '',
    })];
  }

  // User message
  if (raw.message?.role === 'user' && raw.message?.content) {
    // Messages flagged `isMeta` by the Claude Code SDK are internal prompts
    // injected into the model's conversation (skill outputs, attachment
    // reminders, system context, etc.). They must never render as user
    // bubbles — that's what caused slash-command output like `/projects` to
    // appear twice (once as a fake user message, once as the assistant's
    // actual reply). We still have to let `tool_result` parts through.
    const isMetaUserMessage = raw.isMeta === true;

    if (Array.isArray(raw.message.content)) {
      // Handle tool_result parts (these must flow through even when isMeta)
      for (const part of raw.message.content) {
        if (part.type === 'tool_result') {
          messages.push(createNormalizedMessage({
            id: `${baseId}_tr_${part.tool_use_id}`,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'tool_result',
            toolId: part.tool_use_id,
            content: typeof part.content === 'string' ? part.content : JSON.stringify(part.content),
            isError: Boolean(part.is_error),
            subagentTools: raw.subagentTools,
            toolUseResult: raw.toolUseResult,
          }));
        } else if (part.type === 'text' && !isMetaUserMessage) {
          // Regular text parts from user
          const text = part.text || '';
          if (!includeUserText || !text) {
            continue;
          }
          // `<command-message>…<command-name>/foo</command-name>` envelopes
          // are the SDK's only record of what the user typed — surface them
          // as a clean "/foo" bubble instead of dropping them.
          const slashCommand = extractSlashCommandInvocation(text);
          if (slashCommand) {
            messages.push(createNormalizedMessage({
              id: `${baseId}_slash`,
              sessionId,
              timestamp: ts,
              provider: PROVIDER,
              kind: 'text',
              role: 'user',
              content: slashCommand,
            }));
            continue;
          }
          if (!isInternalContent(text)) {
            messages.push(createNormalizedMessage({
              id: `${baseId}_text`,
              sessionId,
              timestamp: ts,
              provider: PROVIDER,
              kind: 'text',
              role: 'user',
              content: text,
            }));
          }
        }
      }

      // If no text parts were found, check if it's a pure user message
      if (messages.length === 0 && !isMetaUserMessage) {
        const textParts = raw.message.content
          .filter(p => p.type === 'text')
          .map(p => p.text)
          .filter(Boolean)
          .join('\n');
        if (includeUserText && textParts) {
          const slashCommand = extractSlashCommandInvocation(textParts);
          if (slashCommand) {
            messages.push(createNormalizedMessage({
              id: `${baseId}_slash`,
              sessionId,
              timestamp: ts,
              provider: PROVIDER,
              kind: 'text',
              role: 'user',
              content: slashCommand,
            }));
          } else if (!isInternalContent(textParts)) {
            messages.push(createNormalizedMessage({
              id: `${baseId}_text`,
              sessionId,
              timestamp: ts,
              provider: PROVIDER,
              kind: 'text',
              role: 'user',
              content: textParts,
            }));
          }
        }
      }
    } else if (typeof raw.message.content === 'string' && !isMetaUserMessage) {
      const text = raw.message.content;
      if (includeUserText && text) {
        const slashCommand = extractSlashCommandInvocation(text);
        if (slashCommand) {
          messages.push(createNormalizedMessage({
            id: baseId,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'text',
            role: 'user',
            content: slashCommand,
          }));
        } else if (!isInternalContent(text)) {
          messages.push(createNormalizedMessage({
            id: baseId,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'text',
            role: 'user',
            content: text,
          }));
        }
      }
    }
    return messages;
  }

  // Thinking message
  if (raw.type === 'thinking' && raw.message?.content) {
    messages.push(createNormalizedMessage({
      id: baseId,
      sessionId,
      timestamp: ts,
      provider: PROVIDER,
      kind: 'thinking',
      content: raw.message.content,
    }));
    return messages;
  }

  // Tool use result (codex-style in Claude)
  if (raw.type === 'tool_use' && raw.toolName) {
    messages.push(createNormalizedMessage({
      id: baseId,
      sessionId,
      timestamp: ts,
      provider: PROVIDER,
      kind: 'tool_use',
      toolName: raw.toolName,
      toolInput: raw.toolInput,
      toolId: raw.toolCallId || baseId,
    }));
    return messages;
  }

  if (raw.type === 'tool_result') {
    messages.push(createNormalizedMessage({
      id: baseId,
      sessionId,
      timestamp: ts,
      provider: PROVIDER,
      kind: 'tool_result',
      toolId: raw.toolCallId || '',
      content: raw.output || '',
      isError: false,
    }));
    return messages;
  }

  // Assistant message
  if (raw.message?.role === 'assistant' && raw.message?.content) {
    if (Array.isArray(raw.message.content)) {
      let partIndex = 0;
      for (const part of raw.message.content) {
        if (part.type === 'text' && part.text) {
          messages.push(createNormalizedMessage({
            id: `${baseId}_${partIndex}`,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'text',
            role: 'assistant',
            content: part.text,
          }));
        } else if (part.type === 'tool_use') {
          messages.push(createNormalizedMessage({
            id: `${baseId}_${partIndex}`,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'tool_use',
            toolName: part.name,
            toolInput: part.input,
            toolId: part.id,
          }));
        } else if (part.type === 'thinking' && part.thinking) {
          messages.push(createNormalizedMessage({
            id: `${baseId}_${partIndex}`,
            sessionId,
            timestamp: ts,
            provider: PROVIDER,
            kind: 'thinking',
            content: part.thinking,
          }));
        }
        partIndex++;
      }
    } else if (typeof raw.message.content === 'string') {
      messages.push(createNormalizedMessage({
        id: baseId,
        sessionId,
        timestamp: ts,
        provider: PROVIDER,
        kind: 'text',
        role: 'assistant',
        content: raw.message.content,
      }));
    }
    return messages;
  }

  return messages;
}

/**
 * @type {import('../types.js').ProviderAdapter}
 */
export const claudeAdapter = {
  normalizeMessage,

  /**
   * Fetch session history from JSONL files, returning normalized messages.
   */
  async fetchHistory(sessionId, opts = {}) {
    const {
      projectName,
      limit = null,
      offset = 0,
      sessionKind = null,
      parentSessionId = null,
      relativeTranscriptPath = null,
    } = opts;
    if (!projectName) {
      return { messages: [], total: 0, hasMore: false, offset: 0, limit: null };
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
      return { messages: [], total: 0, hasMore: false, offset: 0, limit: null };
    }

    // getSessionMessages returns either an array (no limit) or { messages, total, hasMore }
    const rawMessages = Array.isArray(result) ? result : (result.messages || []);
    const total = Array.isArray(result) ? rawMessages.length : (result.total || 0);
    const hasMore = Array.isArray(result) ? false : Boolean(result.hasMore);

    const normalized = normalizeHistoryMessages(rawMessages, sessionId);

    return {
      messages: normalized,
      total,
      hasMore,
      offset,
      limit,
    };
  },
};
