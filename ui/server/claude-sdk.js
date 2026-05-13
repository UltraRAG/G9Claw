/**
 * Claude SDK Integration
 *
 * This module provides SDK-based integration with Claude using the @anthropic-ai/claude-agent-sdk.
 * It mirrors the interface of claude-cli.js but uses the SDK internally for better performance
 * and maintainability.
 *
 * Key features:
 * - Direct SDK integration without child processes
 * - Session management with abort capability
 * - Options mapping between CLI and SDK formats
 * - WebSocket message streaming
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import crypto from 'crypto';
import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import {
  createNotificationEvent,
  notifyRunFailed,
  notifyRunStopped,
  notifyUserIfEnabled
} from './services/notification-orchestrator.js';
import { edgeclawAdapter } from './providers/edgeclaw/adapter.js';
import { createNormalizedMessage } from './providers/types.js';
import {
  getLeakedClaudeSdkSpawnOptions,
  resolveBundledPluginDirs
} from './claude-code-main-path.js';
import { getClaudeRuntimeModelConfig } from './utils/claude-runtime-config.js';
import {
  drainSessionCronNotifications,
  registerCronSession
} from './services/cron-session-bridge.js';
import { ActivityTracker } from './services/activity-tracker.js';

const activeSessions = new Map();
const sessionRuntimes = new Map();
const pendingToolApprovals = new Map();
const pendingCoalescenceMap = new Map();
const sessionTokenBudgets = new Map();

const TOOL_APPROVAL_TIMEOUT_MS = parseInt(process.env.CLAUDE_TOOL_APPROVAL_TIMEOUT_MS, 10) || 55000;

const TOOLS_REQUIRING_INTERACTION = new Set(['AskUserQuestion']);
const BUILT_IN_WEB_TOOLS = ['WebFetch', 'WebSearch'];
const RAG_WEB_TOOL_GUIDANCE = [
  '9GClaw RAG is enabled.',
  'For network search, web research, current public facts, source-backed answers, or user requests mentioning web/search skills, use the 9GClaw RAG skills instead of built-in web tools.',
  'The RAG entries are skills, not direct tool names. Never call tools named "9gclaw-rag:glm-web-search", "9gclaw-rag:local-knowledge", or "9gclaw-rag:rag-research".',
  'To use public web search, call the built-in Skill tool with skill="9gclaw-rag:glm-web-search" and the search query as args. To combine local knowledge and web evidence, call Skill with skill="9gclaw-rag:rag-research".',
  'After the Skill tool loads a RAG skill, follow the loaded SKILL.md and run the allowed Bash script command shown there.',
  'Do not pass --top-k to RAG scripts unless the user explicitly asks to override the configured result count; the scripts read EDGECLAW_RAG_*_TOP_K from 9GClaw config.',
  'Do not use WebFetch or WebSearch for search. If a page must be opened after search results are returned, prefer the URL snippets/citations from the RAG script unless the user explicitly asks to fetch a specific URL.',
].join('\n');

function getConfiguredContextWindow() {
  const parsed = parseInt(process.env.CONTEXT_WINDOW, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 160000;
}

function createTokenBudget(used = 0) {
  return {
    used: Math.max(0, Math.round(Number(used) || 0)),
    total: getConfiguredContextWindow(),
  };
}

function storeSessionTokenBudget(sessionId, tokenBudget) {
  if (!sessionId || !tokenBudget) {
    return tokenBudget;
  }

  const normalizedBudget = createTokenBudget(tokenBudget.used);
  const previous = sessionTokenBudgets.get(sessionId) || getSessionRuntime(sessionId)?.tokenBudget || null;

  // Do not let synthetic or provider placeholder usage records reset an
  // already-populated session back to zero. Some SDK transcript entries carry
  // usage: { input_tokens: 0, output_tokens: 0 } for text fragments.
  if (normalizedBudget.used <= 0 && previous?.used > 0) {
    return previous;
  }

  sessionTokenBudgets.set(sessionId, normalizedBudget);
  updateSessionRuntime(sessionId, { tokenBudget: normalizedBudget });
  return normalizedBudget;
}

function getSessionTokenBudget(sessionId) {
  if (!sessionId) {
    return createTokenBudget(0);
  }
  const runtimeBudget = getSessionRuntime(sessionId)?.tokenBudget;
  if (!sessionTokenBudgets.has(sessionId) && runtimeBudget) {
    sessionTokenBudgets.set(sessionId, runtimeBudget);
  }
  if (!sessionTokenBudgets.has(sessionId)) {
    sessionTokenBudgets.set(sessionId, createTokenBudget(0));
  }
  const budget = sessionTokenBudgets.get(sessionId);
  const currentTotal = getConfiguredContextWindow();
  if (budget.total !== currentTotal) {
    sessionTokenBudgets.set(sessionId, { ...budget, total: currentTotal });
    updateSessionRuntime(sessionId, { tokenBudget: sessionTokenBudgets.get(sessionId) });
  }
  return sessionTokenBudgets.get(sessionId);
}

function hasKnownSessionTokenBudget(sessionId) {
  if (!sessionId) {
    return false;
  }
  const budget = sessionTokenBudgets.get(sessionId) || getSessionRuntime(sessionId)?.tokenBudget;
  return Boolean(budget && Number(budget.used) > 0);
}

function transferSessionTokenBudget(fromSessionId, toSessionId) {
  if (!fromSessionId || !toSessionId || fromSessionId === toSessionId) {
    return;
  }
  if (!sessionTokenBudgets.has(toSessionId) && sessionTokenBudgets.has(fromSessionId)) {
    sessionTokenBudgets.set(toSessionId, sessionTokenBudgets.get(fromSessionId));
    updateSessionRuntime(toSessionId, { tokenBudget: sessionTokenBudgets.get(toSessionId) });
  }
  sessionTokenBudgets.delete(fromSessionId);
}

function sendTokenBudget(ws, sessionId, tokenBudget = getSessionTokenBudget(sessionId)) {
  ws?.send?.(createNormalizedMessage({
    kind: 'status',
    text: 'token_budget',
    tokenBudget,
    sessionId: sessionId || null,
    provider: 'claude'
  }));
}

function normalizeEnvValue(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function isEnabledEnv(value) {
  return value === '1' || value === 'true' || value === 'yes' || value === 'on';
}

function shouldDisableBuiltInWebTools() {
  return (
    isEnabledEnv(normalizeEnvValue(process.env.EDGECLAW_RAG_ENABLED).toLowerCase()) &&
    normalizeEnvValue(process.env.EDGECLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS).toLowerCase() !== '0' &&
    normalizeEnvValue(process.env.EDGECLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS).toLowerCase() !== 'false'
  );
}

function addUniqueItems(items, additions) {
  const out = Array.isArray(items) ? [...items] : [];
  for (const item of additions) {
    if (!out.includes(item)) {
      out.push(item);
    }
  }
  return out;
}

async function buildClaudeSubprocessEnv() {
  const env = { ...process.env };
  const runtimeModel = getClaudeRuntimeModelConfig().defaultModel;
  let anthropicBaseUrl = normalizeEnvValue(process.env.ANTHROPIC_BASE_URL);
  const anthropicApiKey = normalizeEnvValue(process.env.ANTHROPIC_API_KEY);

  if (anthropicBaseUrl === 'http://ccr.local') {
    const proxyPort = process.env.EDGECLAW_PROXY_PORT || process.env.PROXY_PORT || '18080';
    anthropicBaseUrl = `http://127.0.0.1:${proxyPort}`;
  }

  if (anthropicBaseUrl) {
    env.ANTHROPIC_BASE_URL = anthropicBaseUrl;
  }
  if (anthropicApiKey) {
    env.ANTHROPIC_API_KEY = anthropicApiKey;
  }
  if (runtimeModel) {
    env.ANTHROPIC_MODEL = runtimeModel;
  }
  env.CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST = '1';

  if (anthropicApiKey || anthropicBaseUrl) {
    delete env.ANTHROPIC_AUTH_TOKEN;
    delete env.CLAUDE_CODE_OAUTH_TOKEN;
  }

  try {
    const { ensureCDPUrl } = await import('./utils/globalChrome.js');
    const cdpUrl = await ensureCDPUrl();
    if (cdpUrl) {
      env.CDP_URL = cdpUrl;
    }
  } catch {
    if (process.env.CDP_URL) {
      env.CDP_URL = process.env.CDP_URL;
    }
  }

  return env;
}

function createRequestId() {
  if (typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return crypto.randomBytes(16).toString('hex');
}

function waitForToolApproval(requestId, options = {}) {
  const { timeoutMs = TOOL_APPROVAL_TIMEOUT_MS, signal, onCancel, metadata } = options;

  return new Promise(resolve => {
    let settled = false;

    const finalize = (decision) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(decision);
    };

    let timeout;

    const cleanup = () => {
      pendingToolApprovals.delete(requestId);
      if (timeout) clearTimeout(timeout);
      if (signal && abortHandler) {
        signal.removeEventListener('abort', abortHandler);
      }
    };

    // timeoutMs 0 = wait indefinitely (interactive tools)
    if (timeoutMs > 0) {
      timeout = setTimeout(() => {
        onCancel?.('timeout');
        finalize(null);
      }, timeoutMs);
    }

    const abortHandler = () => {
      onCancel?.('cancelled');
      finalize({ cancelled: true });
    };

    if (signal) {
      if (signal.aborted) {
        onCancel?.('cancelled');
        finalize({ cancelled: true });
        return;
      }
      signal.addEventListener('abort', abortHandler, { once: true });
    }

    const resolver = (decision) => {
      finalize(decision);
    };
    // Attach metadata for getPendingApprovalsForSession lookup
    if (metadata) {
      Object.assign(resolver, metadata);
    }
    pendingToolApprovals.set(requestId, resolver);
  });
}

function resolveToolApproval(requestId, decision) {
  const resolver = pendingToolApprovals.get(requestId);
  if (resolver) {
    resolver(decision);
  }
}

function buildServerPermissionKey(toolName, input) {
  if (!toolName) return null;
  if (toolName !== 'Bash') return toolName;

  let command = '';
  if (typeof input === 'string') {
    command = input.trim();
  } else if (input && typeof input === 'object' && typeof input.command === 'string') {
    command = input.command.trim();
  }

  if (!command) return toolName;
  const tokens = command.split(/\s+/);
  if (tokens[0] === 'git' && tokens[1]) {
    return `Bash(${tokens[0]} ${tokens[1]}:*)`;
  }
  return `Bash(${tokens[0]}:*)`;
}

// Match stored permission entries against a tool + input combo.
// This only supports exact tool names and the Bash(command:*) shorthand
// used by the UI; it intentionally does not implement full glob semantics,
// introduced to stay consistent with the UI's "Allow rule" format.
function matchesToolPermission(entry, toolName, input) {
  if (!entry || !toolName) {
    return false;
  }

  if (entry === toolName) {
    return true;
  }

  const bashMatch = entry.match(/^Bash\((.+):\*\)$/);
  if (toolName === 'Bash' && bashMatch) {
    const allowedPrefix = bashMatch[1];
    let command = '';

    if (typeof input === 'string') {
      command = input.trim();
    } else if (input && typeof input === 'object' && typeof input.command === 'string') {
      command = input.command.trim();
    }

    if (!command) {
      return false;
    }

    return command.startsWith(allowedPrefix);
  }

  return false;
}

/**
 * Maps CLI options to SDK-compatible options format
 * @param {Object} options - CLI options
 * @returns {Object} SDK-compatible options
 */
async function mapCliOptionsToSDK(options = {}) {
  const { sessionId, cwd, toolsSettings, permissionMode } = options;

  const sdkOptions = {};

  // Map working directory
  if (cwd) {
    sdkOptions.cwd = cwd;
  }

  // Map permission mode
  if (permissionMode && permissionMode !== 'default') {
    sdkOptions.permissionMode = permissionMode;
  }

  // Map tool settings
  const settings = toolsSettings || {
    allowedTools: [],
    disallowedTools: [],
    skipPermissions: false
  };

  // Handle tool permissions
  if (settings.skipPermissions && permissionMode !== 'plan') {
    // When skipping permissions, use bypassPermissions mode
    sdkOptions.permissionMode = 'bypassPermissions';
  }

  let allowedTools = [...(settings.allowedTools || [])];
  let disallowedTools = [...(settings.disallowedTools || [])];

  // Add plan mode default tools
  if (permissionMode === 'plan') {
    const planModeTools = ['Read', 'Task', 'exit_plan_mode', 'TodoRead', 'TodoWrite', 'WebFetch', 'WebSearch'];
    for (const tool of planModeTools) {
      if (!allowedTools.includes(tool)) {
        allowedTools.push(tool);
      }
    }
  }

  const disableBuiltInWebTools = shouldDisableBuiltInWebTools();
  if (disableBuiltInWebTools) {
    disallowedTools = addUniqueItems(disallowedTools, BUILT_IN_WEB_TOOLS);
    allowedTools = allowedTools.filter(tool => !BUILT_IN_WEB_TOOLS.includes(tool));
  }

  sdkOptions.allowedTools = allowedTools;

  // Use the tools preset to make all default built-in tools available (including AskUserQuestion).
  // This was introduced in SDK 0.1.57. Omitting this preserves existing behavior (all tools available),
  // but being explicit ensures forward compatibility and clarity.
  sdkOptions.tools = { type: 'preset', preset: 'claude_code' };

  sdkOptions.disallowedTools = disallowedTools;

  // Map model (default resolved from runtime env/config)
  sdkOptions.model = options.model || getClaudeRuntimeModelConfig().defaultModel;
  // Model logged at query start below

  // Map system prompt configuration
  sdkOptions.systemPrompt = {
    type: 'preset',
    preset: 'claude_code',  // Required to use CLAUDE.md
    ...(disableBuiltInWebTools ? { append: RAG_WEB_TOOL_GUIDANCE } : {})
  };

  // Map setting sources for CLAUDE.md loading
  // This loads CLAUDE.md from project, user (~/.config/claude/CLAUDE.md), and local directories
  sdkOptions.settingSources = ['project', 'user', 'local'];
  sdkOptions.env = await buildClaudeSubprocessEnv();
  const pluginDirs = resolveBundledPluginDirs();
  if (pluginDirs.length > 0) {
    sdkOptions.plugins = pluginDirs.map(pluginDir => ({
      type: 'local',
      path: pluginDir
    }));
  }

  // Map resume session
  if (sessionId) {
    sdkOptions.resume = sessionId;
  }

  const leakedSpawn = getLeakedClaudeSdkSpawnOptions();
  if (leakedSpawn) {
    sdkOptions.pathToClaudeCodeExecutable = leakedSpawn.pathToClaudeCodeExecutable;
    sdkOptions.executable = leakedSpawn.executable;
    sdkOptions.executableArgs = leakedSpawn.executableArgs;
    sdkOptions.extraArgs = {
      ...(sdkOptions.extraArgs || {}),
      print: null,
    };
  }

  return sdkOptions;
}

/**
 * Adds a session to the active sessions map
 * @param {string} sessionId - Session identifier
 * @param {Object} queryInstance - SDK query instance
 * @param {Array<string>} tempImagePaths - Temp image file paths for cleanup
 * @param {string} tempDir - Temp directory for cleanup
 */
function addSession(sessionId, queryInstance, tempImagePaths = [], tempDir = null, writer = null, cwd = null, activityTracker = null) {
  activeSessions.set(sessionId, {
    instance: queryInstance,
    startTime: Date.now(),
    status: 'active',
    tempImagePaths,
    tempDir,
    writer,
    cwd,
    activityTracker
  });
}

/**
 * Removes a session from the active sessions map
 * @param {string} sessionId - Session identifier
 */
function removeSession(sessionId) {
  activeSessions.delete(sessionId);
}

/**
 * Gets a session from the active sessions map
 * @param {string} sessionId - Session identifier
 * @returns {Object|undefined} Session data or undefined
 */
function getSession(sessionId) {
  return activeSessions.get(sessionId);
}

/**
 * Gets all active session IDs
 * @returns {Array<string>} Array of active session IDs
 */
function getAllSessions() {
  return Array.from(activeSessions.keys());
}

function cloneToolsSettings(toolsSettings) {
  if (!toolsSettings || typeof toolsSettings !== 'object') {
    return {
      allowedTools: [],
      disallowedTools: [],
      skipPermissions: false
    };
  }

  return {
    ...toolsSettings,
    allowedTools: Array.isArray(toolsSettings.allowedTools)
      ? [...toolsSettings.allowedTools]
      : [],
    disallowedTools: Array.isArray(toolsSettings.disallowedTools)
      ? [...toolsSettings.disallowedTools]
      : []
  };
}

function buildStoredQueryOptions(options = {}, sessionId) {
  return {
    sessionId,
    cwd: options.cwd,
    permissionMode: options.permissionMode,
    model: options.model,
    sessionSummary: options.sessionSummary,
    alwaysOnPlanId: options.alwaysOnPlanId,
    alwaysOnExecutionToken: options.alwaysOnExecutionToken,
    toolsSettings: cloneToolsSettings(options.toolsSettings)
  };
}

function createSilentWriter(sessionId = null, userId = null) {
  return {
    userId,
    send() {},
    updateWebSocket() {},
    setSessionId() {},
    getSessionId() {
      return sessionId;
    }
  };
}

function canWriteToSession(writer) {
  if (!writer) {
    return false;
  }
  if (writer.ws && typeof writer.ws.readyState === 'number') {
    return writer.ws.readyState === 1;
  }
  return typeof writer.send === 'function';
}

function createSessionRuntime(sessionId) {
  return {
    sessionId,
    writer: null,
    userId: null,
    sessionSummary: null,
    lastQueryOptions: null,
    tokenBudget: null,
    pendingCronNotifications: [],
    autoResumeInFlight: false
  };
}

function getSessionRuntime(sessionId) {
  return sessionRuntimes.get(sessionId);
}

function getOrCreateSessionRuntime(sessionId) {
  if (!sessionId) {
    return null;
  }

  let runtime = sessionRuntimes.get(sessionId);
  if (!runtime) {
    runtime = createSessionRuntime(sessionId);
    sessionRuntimes.set(sessionId, runtime);
    registerCronSession(sessionId, async (notification) => {
      await handleSessionCronNotification(sessionId, notification);
    });
  }
  return runtime;
}

function updateSessionRuntime(sessionId, fields = {}) {
  const runtime = getOrCreateSessionRuntime(sessionId);
  if (!runtime) {
    return null;
  }

  if (fields.writer) {
    runtime.writer = fields.writer;
  }
  if (fields.userId !== undefined) {
    runtime.userId = fields.userId;
  }
  if (fields.sessionSummary !== undefined) {
    runtime.sessionSummary = fields.sessionSummary;
  }
  if (fields.lastQueryOptions) {
    runtime.lastQueryOptions = fields.lastQueryOptions;
  }
  if (fields.tokenBudget !== undefined) {
    runtime.tokenBudget = fields.tokenBudget;
  }

  return runtime;
}

function createCronTaskNotificationMessage(sessionId, notification) {
  const normalizedMessages = edgeclawAdapter.normalizeMessage({
    uuid: notification.id,
    timestamp: new Date(notification.createdAt).toISOString(),
    message: {
      role: 'user',
      content: notification.message
    }
  }, sessionId);

  return normalizedMessages.find((message) => message.kind === 'task_notification') ||
    createNormalizedMessage({
      id: notification.id,
      sessionId,
      provider: 'claude',
      kind: 'task_notification',
      status: 'completed',
      summary: 'Background task update'
    });
}

function emitCronNotificationToRuntime(runtime, notification) {
  if (!runtime?.writer || !canWriteToSession(runtime.writer)) {
    return false;
  }

  runtime.writer.send(
    createCronTaskNotificationMessage(runtime.sessionId, notification)
  );
  return true;
}

function flushUndeliveredCronNotifications(sessionId) {
  const runtime = getSessionRuntime(sessionId);
  if (!runtime || !runtime.writer || !canWriteToSession(runtime.writer)) {
    return 0;
  }

  let deliveredCount = 0;
  for (const pending of runtime.pendingCronNotifications) {
    if (pending.deliveredToClient) {
      continue;
    }

    runtime.writer.send(
      createCronTaskNotificationMessage(sessionId, pending.notification)
    );
    pending.deliveredToClient = true;
    deliveredCount += 1;
  }

  return deliveredCount;
}

async function runQueuedCronNotifications(sessionId) {
  const runtime = getSessionRuntime(sessionId);
  if (
    !runtime ||
    runtime.autoResumeInFlight ||
    isClaudeSDKSessionActive(sessionId) ||
    runtime.pendingCronNotifications.length === 0 ||
    !runtime.lastQueryOptions
  ) {
    return;
  }

  const pending = runtime.pendingCronNotifications[0];
  runtime.autoResumeInFlight = true;
  let autoResumeSucceeded = false;

  try {
    await queryClaudeSDK(
      pending.notification.message,
      {
        ...runtime.lastQueryOptions,
        sessionId,
        sessionSummary: runtime.sessionSummary ?? runtime.lastQueryOptions.sessionSummary
      },
      runtime.writer || createSilentWriter(sessionId, runtime.userId),
    );
    autoResumeSucceeded = true;
  } catch (error) {
    console.error(`[cron-session-runtime] Failed to auto-resume session ${sessionId}:`, error);
  } finally {
    runtime.autoResumeInFlight = false;
    if (autoResumeSucceeded) {
      runtime.pendingCronNotifications.shift();
      if (runtime.pendingCronNotifications.length > 0) {
        void runQueuedCronNotifications(sessionId);
      }
    }
  }
}

async function handleSessionCronNotification(sessionId, notification) {
  const runtime = getOrCreateSessionRuntime(sessionId);
  if (!runtime) {
    return;
  }

  const deliveredToClient = emitCronNotificationToRuntime(runtime, notification);
  runtime.pendingCronNotifications.push({
    notification,
    deliveredToClient
  });

  if (!isClaudeSDKSessionActive(sessionId) && !runtime.autoResumeInFlight) {
    void runQueuedCronNotifications(sessionId);
  }
}

/**
 * Transforms SDK messages to WebSocket format expected by frontend
 * @param {Object} sdkMessage - SDK message object
 * @returns {Object} Transformed message ready for WebSocket
 */
function transformMessage(sdkMessage) {
  // Extract parent_tool_use_id for subagent tool grouping
  if (sdkMessage.parent_tool_use_id) {
    return {
      ...sdkMessage,
      parentToolUseId: sdkMessage.parent_tool_use_id
    };
  }
  return sdkMessage;
}

/**
 * Extracts token usage from SDK result messages
 * @param {Object} resultMessage - SDK result message
 * @param {string} sessionId - Session identifier used for local accumulation
 * @returns {Object|null} Token budget object or null
 */
function extractTokenBudget(resultMessage, sessionId) {
  const readUsageNumber = (usage, ...keys) => {
    if (!usage) return 0;
    for (const key of keys) {
      const value = usage[key];
      if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
      }
    }
    return 0;
  };

  const usageToContextTokens = (usage) => {
    const inputTokens = readUsageNumber(usage, 'input_tokens', 'inputTokens');
    const outputTokens = readUsageNumber(usage, 'output_tokens', 'outputTokens');
    const cacheReadTokens = readUsageNumber(
      usage,
      'cache_read_input_tokens',
      'cacheReadInputTokens',
    );
    const cacheCreationTokens = readUsageNumber(
      usage,
      'cache_creation_input_tokens',
      'cacheCreationInputTokens',
    );
    const explicitTotal = readUsageNumber(usage, 'total_tokens', 'totalTokens');
    return explicitTotal || inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens;
  };

  const directUsage = resultMessage?.message?.usage || resultMessage?.usage || null;
  if (directUsage) {
    const used = usageToContextTokens(directUsage);
    if (used > 0) {
      return storeSessionTokenBudget(sessionId, createTokenBudget(used));
    }
  }

  if (resultMessage.type !== 'result' || !resultMessage.modelUsage) {
    return null;
  }

  const modelUsages = Object.values(resultMessage.modelUsage).filter(Boolean);
  if (modelUsages.length === 0) {
    return null;
  }

  const hasCumulativeUsage = modelUsages.some((modelData) =>
    modelData.cumulativeInputTokens !== undefined ||
    modelData.cumulativeOutputTokens !== undefined ||
    modelData.cumulativeCacheReadInputTokens !== undefined ||
    modelData.cumulativeCacheCreationInputTokens !== undefined
  );

  const totalUsed = modelUsages.reduce((sum, modelData) => {
    const inputTokens = hasCumulativeUsage
      ? modelData.cumulativeInputTokens || 0
      : modelData.inputTokens || 0;
    const outputTokens = hasCumulativeUsage
      ? modelData.cumulativeOutputTokens || 0
      : modelData.outputTokens || 0;
    const cacheReadTokens = hasCumulativeUsage
      ? modelData.cumulativeCacheReadInputTokens || 0
      : modelData.cacheReadInputTokens || 0;
    const cacheCreationTokens = hasCumulativeUsage
      ? modelData.cumulativeCacheCreationInputTokens || 0
      : modelData.cacheCreationInputTokens || 0;
    return sum + inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens;
  }, 0);

  const previous = getSessionTokenBudget(sessionId);
  const nextUsed = hasCumulativeUsage ? totalUsed : previous.used + totalUsed;
  const nextBudget = createTokenBudget(nextUsed);

  // Token calc logged via token-budget WS event
  return storeSessionTokenBudget(sessionId, nextBudget);
}

function buildImagePrompt(command, images, sessionId) {
  if (!Array.isArray(images) || images.length === 0) {
    return command;
  }

  const content = [];
  const text = typeof command === 'string' && command.trim()
    ? command
    : 'Please review the attached image.';
  content.push({ type: 'text', text });

  for (const image of images) {
    const matches = typeof image?.data === 'string'
      ? image.data.match(/^data:([^;]+);base64,(.+)$/)
      : null;
    if (!matches) {
      console.error('Invalid image data format');
      continue;
    }

    const [, mimeType, base64Data] = matches;
    if (!['image/jpeg', 'image/png', 'image/gif', 'image/webp'].includes(mimeType)) {
      console.error(`Unsupported multimodal image type: ${mimeType}`);
      continue;
    }

    content.push({
      type: 'image',
      source: {
        type: 'base64',
        media_type: mimeType,
        data: base64Data,
      },
    });
  }

  if (content.length === 1) {
    return command;
  }

  return (async function* imagePromptStream() {
    yield {
      type: 'user',
      message: {
        role: 'user',
        content,
      },
      parent_tool_use_id: null,
      session_id: sessionId || '',
      uuid: crypto.randomUUID(),
    };
  })();
}

/**
 * Cleans up temporary image files
 * @param {Array<string>} tempImagePaths - Array of temp file paths to delete
 * @param {string} tempDir - Temp directory to remove
 */
async function cleanupTempFiles(tempImagePaths, tempDir) {
  if (!tempImagePaths || tempImagePaths.length === 0) {
    return;
  }

  try {
    // Delete individual temp files
    for (const imagePath of tempImagePaths) {
      await fs.unlink(imagePath).catch(err =>
        console.error(`Failed to delete temp image ${imagePath}:`, err)
      );
    }

    // Delete temp directory
    if (tempDir) {
      await fs.rm(tempDir, { recursive: true, force: true }).catch(err =>
        console.error(`Failed to delete temp directory ${tempDir}:`, err)
      );
    }

    // Temp files cleaned
  } catch (error) {
    console.error('Error during temp file cleanup:', error);
  }
}

/**
 * Loads MCP server configurations from ~/.claude.json
 * @param {string} cwd - Current working directory for project-specific configs
 * @returns {Object|null} MCP servers object or null if none found
 */
async function loadMcpConfig(cwd) {
  try {
    const claudeConfigPath = path.join(os.homedir(), '.claude.json');

    // Check if config file exists
    try {
      await fs.access(claudeConfigPath);
    } catch (error) {
      // File doesn't exist, return null
      // No config file
      return null;
    }

    // Read and parse config file
    let claudeConfig;
    try {
      const configContent = await fs.readFile(claudeConfigPath, 'utf8');
      claudeConfig = JSON.parse(configContent);
    } catch (error) {
      console.error('Failed to parse ~/.claude.json:', error.message);
      return null;
    }

    // Extract MCP servers (merge global and project-specific)
    let mcpServers = {};

    // Add global MCP servers
    if (claudeConfig.mcpServers && typeof claudeConfig.mcpServers === 'object') {
      mcpServers = { ...claudeConfig.mcpServers };
      // Global MCP servers loaded
    }

    // Add/override with project-specific MCP servers
    if (claudeConfig.claudeProjects && cwd) {
      const projectConfig = claudeConfig.claudeProjects[cwd];
      if (projectConfig && projectConfig.mcpServers && typeof projectConfig.mcpServers === 'object') {
        mcpServers = { ...mcpServers, ...projectConfig.mcpServers };
        // Project MCP servers merged
      }
    }

    // Return null if no servers found
    if (Object.keys(mcpServers).length === 0) {
      return null;
    }
    return mcpServers;
  } catch (error) {
    console.error('Error loading MCP config:', error.message);
    return null;
  }
}

/**
 * Executes a Claude query using the SDK
 * @param {string} command - User prompt/command
 * @param {Object} options - Query options
 * @param {Object} ws - WebSocket connection
 * @returns {Promise<void>}
 */
async function queryClaudeSDK(command, options = {}, ws) {
  const { sessionId, sessionSummary } = options;
  let capturedSessionId = sessionId;
  let tokenBudgetSessionId = sessionId || `pending:${crypto.randomUUID()}`;
  let sessionCreatedSent = false;
  let tempImagePaths = [];
  let tempDir = null;
  const activityTracker = new ActivityTracker({
    ws,
    sessionId: capturedSessionId || null,
    projectRoot: options.cwd || options.projectPath || null,
    sessionSummary,
  });

  if (sessionId) {
    updateSessionRuntime(sessionId, {
      writer: ws,
      userId: ws?.userId || null,
      sessionSummary,
      lastQueryOptions: buildStoredQueryOptions(options, sessionId)
    });
  }

  const emitNotification = (event) => {
    notifyUserIfEnabled({
      userId: ws?.userId || null,
      writer: ws,
      event
    });
  };

  try {
    activityTracker.start();
    const initialTokenBudget = getSessionTokenBudget(tokenBudgetSessionId);
    if (!sessionId || initialTokenBudget.used > 0) {
      sendTokenBudget(ws, capturedSessionId || null, initialTokenBudget);
    }

    // Map CLI options to SDK format
    const sdkOptions = await mapCliOptionsToSDK(options);

    // Load MCP configuration
    const mcpServers = await loadMcpConfig(options.cwd);
    if (mcpServers) {
      sdkOptions.mcpServers = mcpServers;
    }

    const finalCommand = buildImagePrompt(command, options.images, sessionId);

    sdkOptions.hooks = {
      Notification: [{
        matcher: '',
        hooks: [async (input) => {
          const message = typeof input?.message === 'string' ? input.message : 'Claude requires your attention.';
          emitNotification(createNotificationEvent({
            provider: 'claude',
            sessionId: capturedSessionId || sessionId || null,
            kind: 'action_required',
            code: 'agent.notification',
            meta: { message, sessionName: sessionSummary },
            severity: 'warning',
            requiresUserAction: true,
            dedupeKey: `claude:hook:notification:${capturedSessionId || sessionId || 'none'}:${message}`
          }));
          return {};
        }]
      }]
    };

    sdkOptions.canUseTool = async (toolName, input, context) => {
      const requiresInteraction = TOOLS_REQUIRING_INTERACTION.has(toolName);

      if (!requiresInteraction) {
        const isDisallowed = (sdkOptions.disallowedTools || []).some(entry =>
          matchesToolPermission(entry, toolName, input)
        );
        if (isDisallowed) {
          return { behavior: 'deny', message: 'Tool disallowed by settings' };
        }

        if (sdkOptions.permissionMode === 'bypassPermissions') {
          return { behavior: 'allow', updatedInput: input };
        }

        const isAllowed = (sdkOptions.allowedTools || []).some(entry =>
          matchesToolPermission(entry, toolName, input)
        );
        if (isAllowed) {
          return { behavior: 'allow', updatedInput: input };
        }
      }

      const permKey = buildServerPermissionKey(toolName, input);
      const effectiveSessionId = capturedSessionId || sessionId || null;
      const coalescenceKey = permKey ? `${effectiveSessionId || 'none'}:${permKey}` : null;

      if (coalescenceKey && !requiresInteraction) {
        const existing = pendingCoalescenceMap.get(coalescenceKey);
        if (existing) {
          const decision = await existing.promise;
          if (decision?.allow) {
            if (decision.rememberEntry && typeof decision.rememberEntry === 'string') {
              if (!sdkOptions.allowedTools.includes(decision.rememberEntry)) {
                sdkOptions.allowedTools.push(decision.rememberEntry);
              }
              if (Array.isArray(sdkOptions.disallowedTools)) {
                sdkOptions.disallowedTools = sdkOptions.disallowedTools.filter(entry => entry !== decision.rememberEntry);
              }
            }
            return { behavior: 'allow', updatedInput: decision.updatedInput ?? input };
          }
          if (decision?.cancelled) {
            return { behavior: 'deny', message: 'Permission request cancelled' };
          }
          return { behavior: 'deny', message: decision?.message ?? 'User denied tool use' };
        }
      }

      const requestId = createRequestId();
      let coalescenceResolve;
      if (coalescenceKey && !requiresInteraction) {
        const coalescencePromise = new Promise(resolve => { coalescenceResolve = resolve; });
        pendingCoalescenceMap.set(coalescenceKey, { requestId, promise: coalescencePromise });
      }

      const permissionMessage = createNormalizedMessage({ kind: 'permission_request', requestId, toolName, input, sessionId: effectiveSessionId, provider: 'claude' });
      ws.send(permissionMessage);
      activityTracker.observe(permissionMessage);
      emitNotification(createNotificationEvent({
        provider: 'claude',
        sessionId: effectiveSessionId,
        kind: 'action_required',
        code: 'permission.required',
        meta: { toolName, sessionName: sessionSummary },
        severity: 'warning',
        requiresUserAction: true,
        dedupeKey: `claude:permission:${effectiveSessionId || 'none'}:${permKey || requestId}`
      }));

      const decision = await waitForToolApproval(requestId, {
        timeoutMs: requiresInteraction ? 0 : undefined,
        signal: context?.signal,
        metadata: {
          _sessionId: effectiveSessionId,
          _toolName: toolName,
          _input: input,
          _receivedAt: new Date(),
        },
        onCancel: (reason) => {
          ws.send(createNormalizedMessage({ kind: 'permission_cancelled', requestId, reason, sessionId: effectiveSessionId, provider: 'claude' }));
        }
      });
      if (coalescenceKey) {
        pendingCoalescenceMap.delete(coalescenceKey);
      }
      if (coalescenceResolve) {
        coalescenceResolve(decision);
      }
      if (!decision) {
        return { behavior: 'deny', message: 'Permission request timed out' };
      }

      if (decision.cancelled) {
        return { behavior: 'deny', message: 'Permission request cancelled' };
      }

      if (decision.allow) {
        if (decision.rememberEntry && typeof decision.rememberEntry === 'string') {
          if (!sdkOptions.allowedTools.includes(decision.rememberEntry)) {
            sdkOptions.allowedTools.push(decision.rememberEntry);
          }
          if (Array.isArray(sdkOptions.disallowedTools)) {
            sdkOptions.disallowedTools = sdkOptions.disallowedTools.filter(entry => entry !== decision.rememberEntry);
          }
        }
        return { behavior: 'allow', updatedInput: decision.updatedInput ?? input };
      }

      return { behavior: 'deny', message: decision.message ?? 'User denied tool use' };
    };

    // Stream assistant text deltas to the frontend. Without this the SDK
    // only emits one whole `assistant` message per turn — users see the
    // reply land as a single block instead of typing in real time.
    sdkOptions.includePartialMessages = true;

    // Set stream-close timeout for long-running tools/sub-agents. The SDK reads
    // this synchronously in Query construction. Keep it comfortably above the
    // longest expected agent turn so a quiet parent stream does not disconnect
    // upstream while a sub-agent is still working.
    const prevStreamTimeout = process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT;
    process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT =
      process.env.EDGECLAW_STREAM_CLOSE_TIMEOUT_MS || '3600000';

    let queryInstance;
    try {
      queryInstance = query({
        prompt: finalCommand,
        options: sdkOptions
      });
    } catch (hookError) {
      // Older/newer SDK versions may not accept hook shapes yet.
      // Keep notification behavior operational via runtime events even if hook registration fails.
      console.warn('Failed to initialize Claude query with hooks, retrying without hooks:', hookError?.message || hookError);
      delete sdkOptions.hooks;
      queryInstance = query({
        prompt: finalCommand,
        options: sdkOptions
      });
    }

    // Restore immediately — Query constructor already captured the value
    if (prevStreamTimeout !== undefined) {
      process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT = prevStreamTimeout;
    } else {
      delete process.env.CLAUDE_CODE_STREAM_CLOSE_TIMEOUT;
    }

    // Track the query instance for abort capability
    if (capturedSessionId) {
      activityTracker.setSessionId(capturedSessionId);
      addSession(capturedSessionId, queryInstance, tempImagePaths, tempDir, ws, options.cwd || options.projectPath || null, activityTracker);
      updateSessionRuntime(capturedSessionId, {
        writer: ws,
        userId: ws?.userId || null,
        sessionSummary,
        lastQueryOptions: buildStoredQueryOptions(options, capturedSessionId)
      });
      void drainSessionCronNotifications(capturedSessionId);
    }

    // Process streaming messages
    console.log('Starting async generator loop for session:', capturedSessionId || 'NEW');
    for await (const message of queryInstance) {
      // Capture session ID from first message
      if (message.session_id && !capturedSessionId) {

        capturedSessionId = message.session_id;
        activityTracker.setSessionId(capturedSessionId);
        transferSessionTokenBudget(tokenBudgetSessionId, capturedSessionId);
        tokenBudgetSessionId = capturedSessionId;
        sendTokenBudget(ws, capturedSessionId, getSessionTokenBudget(tokenBudgetSessionId));
        addSession(capturedSessionId, queryInstance, tempImagePaths, tempDir, ws, options.cwd || options.projectPath || null, activityTracker);
        updateSessionRuntime(capturedSessionId, {
          writer: ws,
          userId: ws?.userId || null,
          sessionSummary,
          lastQueryOptions: buildStoredQueryOptions(options, capturedSessionId)
        });
        void drainSessionCronNotifications(capturedSessionId);

        // Set session ID on writer
        if (ws.setSessionId && typeof ws.setSessionId === 'function') {
          ws.setSessionId(capturedSessionId);
        }

        // Send session-created event only once for new sessions
        if (!sessionId && !sessionCreatedSent) {
          sessionCreatedSent = true;
          ws.send(createNormalizedMessage({
            kind: 'session_created',
            newSessionId: capturedSessionId,
            sessionId: capturedSessionId,
            provider: 'claude',
            alwaysOnPlanId: options.alwaysOnPlanId || null,
            alwaysOnExecutionToken: options.alwaysOnExecutionToken || null
          }));
        }
      } else {
        // session_id already captured
      }

      // Transform and normalize message via adapter
      const transformedMessage = transformMessage(message);
      const sid = capturedSessionId || sessionId || null;

      // Use adapter to normalize SDK events into NormalizedMessage[].
      // `skipStreamedText: true` tells the adapter to drop text/thinking
      // parts from the final assistant SDKMessage — those have already
      // been streamed out as `stream_delta` events via the partial
      // message wrapper, so re-emitting them as a fresh text bubble
      // would duplicate everything once streaming finalizes.
      const normalized = edgeclawAdapter.normalizeMessage(transformedMessage, sid, {
        includeUserText: false,
        skipStreamedText: true,
      });
      for (const msg of normalized) {
        // Preserve parentToolUseId from SDK wrapper for subagent tool grouping
        if (transformedMessage.parentToolUseId && !msg.parentToolUseId) {
          msg.parentToolUseId = transformedMessage.parentToolUseId;
        }
        activityTracker.observe(msg);
        ws.send(msg);
      }

      // Extract and send token budget updates from any SDK message carrying
      // usage. External OpenAI-compatible providers usually write usage on
      // assistant messages, while some SDK versions expose modelUsage on the
      // final result event.
      const tokenBudgetData = extractTokenBudget(message, tokenBudgetSessionId);
      if (tokenBudgetData) {
        sendTokenBudget(ws, capturedSessionId || sessionId || null, tokenBudgetData);
      }
    }

    // Clean up session on completion
    if (capturedSessionId || sessionId) {
      removeSession(capturedSessionId || sessionId);
    }

    // Clean up temporary image files
    await cleanupTempFiles(tempImagePaths, tempDir);

    await activityTracker.complete('completed');

    // Send completion event
    ws.send(createNormalizedMessage({
      kind: 'complete',
      exitCode: 0,
      isNewSession: !sessionId && !!command,
      sessionId: capturedSessionId,
      provider: 'claude',
      alwaysOnPlanId: options.alwaysOnPlanId || null,
      alwaysOnExecutionToken: options.alwaysOnExecutionToken || null
    }));
    notifyRunStopped({
      userId: ws?.userId || null,
      provider: 'claude',
      sessionId: capturedSessionId || sessionId || null,
      sessionName: sessionSummary,
      stopReason: 'completed'
    });
    if (capturedSessionId || sessionId) {
      void runQueuedCronNotifications(capturedSessionId || sessionId);
    }
    // Complete

  } catch (error) {
    console.error('SDK query error:', error);

    // Clean up session on error
    if (capturedSessionId || sessionId) {
      removeSession(capturedSessionId || sessionId);
    }

    // Clean up temporary image files on error
    await cleanupTempFiles(tempImagePaths, tempDir);

    const errorMessage = createNormalizedMessage({
      kind: 'error',
      content: error.message,
      sessionId: capturedSessionId || sessionId || null,
      provider: 'claude',
      alwaysOnPlanId: options.alwaysOnPlanId || null,
      alwaysOnExecutionToken: options.alwaysOnExecutionToken || null
    });
    activityTracker.observe(errorMessage);
    await activityTracker.complete('failed');

    // Send error to WebSocket
    ws.send(errorMessage);
    notifyRunFailed({
      userId: ws?.userId || null,
      provider: 'claude',
      sessionId: capturedSessionId || sessionId || null,
      sessionName: sessionSummary,
      error
    });
    if (capturedSessionId || sessionId) {
      void runQueuedCronNotifications(capturedSessionId || sessionId);
    }

    throw error;
  }
}

/**
 * Aborts an active SDK session
 * @param {string} sessionId - Session identifier
 * @returns {boolean} True if session was aborted, false if not found
 */
async function abortClaudeSDKSession(sessionId) {
  const session = getSession(sessionId);

  if (!session) {
    console.log(`Session ${sessionId} not found`);
    return false;
  }

  try {
    console.log(`Aborting SDK session: ${sessionId}`);

    await session.instance.interrupt().catch(() => {});
    if (typeof session.instance.close === 'function') {
      session.instance.close();
    }

    // Update session status
    session.status = 'aborted';

    // Push a synthetic "interrupted" marker to the session's writer so the UI
    // can render the divider immediately. The Claude Agent SDK only persists
    // the "[Request interrupted by user]" text into the JSONL during the next
    // user turn, which means without this push the user wouldn't see any
    // visible feedback in the chat after pressing pause until they sent
    // another message. The id is prefixed `local_interrupt_` so the frontend
    // store can dedupe it against the JSONL replay (see useSessionStore).
    if (session.writer && typeof session.writer.send === 'function') {
      try {
        session.writer.send(createNormalizedMessage({
          id: `local_interrupt_${sessionId}_${Date.now()}`,
          provider: 'claude',
          sessionId,
          kind: 'interrupted',
          content: '[Request interrupted by user]',
        }));
      } catch (sendError) {
        console.warn(`Failed to push interrupted notice for ${sessionId}:`, sendError?.message || sendError);
      }
    }

    if (session.activityTracker && typeof session.activityTracker.complete === 'function') {
      await session.activityTracker.complete('cancelled').catch((trackerError) => {
        console.warn(`Failed to finalize activity trace for ${sessionId}:`, trackerError?.message || trackerError);
      });
    }

    // Clean up temporary image files
    await cleanupTempFiles(session.tempImagePaths, session.tempDir);

    // Clean up session
    removeSession(sessionId);

    return true;
  } catch (error) {
    console.error(`Error aborting session ${sessionId}:`, error);
    return false;
  }
}

/**
 * Checks if an SDK session is currently active
 * @param {string} sessionId - Session identifier
 * @returns {boolean} True if session is active
 */
function isClaudeSDKSessionActive(sessionId) {
  const session = getSession(sessionId);
  return session && session.status === 'active';
}

/**
 * Gets all active SDK session IDs
 * @returns {Array<string>} Array of active session IDs
 */
function getActiveClaudeSDKSessions() {
  return getAllSessions();
}

function getActiveClaudeSDKSessionDetails() {
  return Array.from(activeSessions.entries()).map(([sessionId, session]) => ({
    sessionId,
    cwd: session.cwd || null,
    status: session.status
  }));
}

function getClaudeSDKSessionTokenBudget(sessionId) {
  if (!hasKnownSessionTokenBudget(sessionId)) {
    return null;
  }
  return getSessionTokenBudget(sessionId);
}

function getClaudeSDKSessionActivitySnapshot(sessionId) {
  const session = getSession(sessionId);
  if (!session?.activityTracker || typeof session.activityTracker.getSnapshot !== 'function') {
    return [];
  }
  return session.activityTracker.getSnapshot();
}

/**
 * Get pending tool approvals for a specific session.
 * @param {string} sessionId - The session ID
 * @returns {Array} Array of pending permission request objects
 */
function getPendingApprovalsForSession(sessionId) {
  const pending = [];
  for (const [requestId, resolver] of pendingToolApprovals.entries()) {
    if (resolver._sessionId === sessionId) {
      pending.push({
        requestId,
        toolName: resolver._toolName || 'UnknownTool',
        input: resolver._input,
        context: resolver._context,
        sessionId,
        receivedAt: resolver._receivedAt || new Date(),
      });
    }
  }
  return pending;
}

/**
 * Reconnect a session's WebSocketWriter to a new raw WebSocket.
 * Called when client reconnects (e.g. page refresh) while SDK is still running.
 * @param {string} sessionId - The session ID
 * @param {Object} newRawWs - The new raw WebSocket connection
 * @returns {boolean} True if writer was successfully reconnected
 */
function reconnectSessionWriter(sessionId, newRawWs) {
  const runtime = getSessionRuntime(sessionId);
  if (!runtime?.writer?.updateWebSocket) return false;
  runtime.writer.updateWebSocket(newRawWs);
  const activeSession = getSession(sessionId);
  if (activeSession?.writer?.updateWebSocket && activeSession.writer !== runtime.writer) {
    activeSession.writer.updateWebSocket(newRawWs);
  }
  if (activeSession?.activityTracker?.setWriter) {
    activeSession.activityTracker.setWriter(activeSession.writer || runtime.writer);
  }
  flushUndeliveredCronNotifications(sessionId);
  void drainSessionCronNotifications(sessionId).then(() => {
    flushUndeliveredCronNotifications(sessionId);
    if (!isClaudeSDKSessionActive(sessionId) && !runtime.autoResumeInFlight) {
      void runQueuedCronNotifications(sessionId);
    }
  });
  console.log(`[RECONNECT] Writer swapped for session ${sessionId}`);
  return true;
}

// Export public API
export {
  queryClaudeSDK,
  abortClaudeSDKSession,
  isClaudeSDKSessionActive,
  getActiveClaudeSDKSessions,
  getActiveClaudeSDKSessionDetails,
  getClaudeSDKSessionTokenBudget,
  getClaudeSDKSessionActivitySnapshot,
  resolveToolApproval,
  getPendingApprovalsForSession,
  reconnectSessionWriter
};
