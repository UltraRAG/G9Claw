import { CLAUDE_MODELS } from '../../../../shared/modelConstants';
import type { Project, ProjectSession } from '../../../types/app';
import type { ClaudeSettings, PermissionMode } from '../types/types';
import { getClaudeSettings, safeLocalStorage } from './chatStorage';

type StartClaudeSessionOptions = {
  sendMessage: (message: unknown) => void;
  selectedProject: Project;
  command: string;
  sessionId?: string | null;
  temporarySessionId?: string;
  permissionMode?: PermissionMode | string;
  basePermissionMode?: PermissionMode | string;
  claudeModel?: string;
  sessionSummary?: string | null;
  toolsSettings?: ClaudeSettings;
  images?: unknown[];
  alwaysOnPlanId?: string;
  alwaysOnExecutionToken?: string;
};

const VALID_PERMISSION_MODES = new Set<PermissionMode>([
  'default',
  'bypassPermissions',
]);
const DEFAULT_PERMISSION_MODE_KEY = 'permissionMode-default';

export const isTemporarySessionId = (sessionId: string | null | undefined) =>
  Boolean(sessionId && sessionId.startsWith('new-session-'));

export function createTemporarySessionId(): string {
  return `new-session-${Date.now()}`;
}

export function getNotificationSessionSummary(
  selectedSession: ProjectSession | null,
  fallbackInput: string,
): string | null {
  const sessionSummary =
    selectedSession?.summary || selectedSession?.name || selectedSession?.title;
  if (typeof sessionSummary === 'string' && sessionSummary.trim()) {
    const normalized = sessionSummary.replace(/\s+/g, ' ').trim();
    return normalized.length > 80
      ? `${normalized.slice(0, 77)}...`
      : normalized;
  }

  const normalizedFallback = fallbackInput.replace(/\s+/g, ' ').trim();
  if (!normalizedFallback) {
    return null;
  }

  return normalizedFallback.length > 80
    ? `${normalizedFallback.slice(0, 77)}...`
    : normalizedFallback;
}

export function getStoredClaudePermissionMode(
  selectedSession: ProjectSession | null,
): PermissionMode {
  const defaultMode = safeLocalStorage.getItem(DEFAULT_PERMISSION_MODE_KEY);
  const fallbackMode = defaultMode && VALID_PERMISSION_MODES.has(defaultMode as PermissionMode)
    ? (defaultMode as PermissionMode)
    : 'default';

  if (!selectedSession?.id) {
    return fallbackMode;
  }

  const stored = safeLocalStorage.getItem(`permissionMode-${selectedSession.id}`);
  if (stored && VALID_PERMISSION_MODES.has(stored as PermissionMode)) {
    return stored as PermissionMode;
  }

  return fallbackMode;
}

export function getSelectedProjectPath(selectedProject: Project): string {
  return selectedProject.fullPath || selectedProject.path || '';
}

export function startClaudeSessionCommand({
  sendMessage,
  selectedProject,
  command,
  sessionId,
  temporarySessionId,
  permissionMode = 'default',
  basePermissionMode,
  claudeModel,
  sessionSummary,
  toolsSettings = getClaudeSettings(),
  images,
  alwaysOnPlanId,
  alwaysOnExecutionToken,
}: StartClaudeSessionOptions): string {
  const sessionToActivate =
    sessionId || temporarySessionId || createTemporarySessionId();
  const resolvedProjectPath = getSelectedProjectPath(selectedProject);

  safeLocalStorage.setItem('selected-provider', 'claude');

  sendMessage({
    type: 'claude-command',
    command,
    options: {
      ...(sessionId ? { sessionId, resume: true } : {}),
      projectPath: resolvedProjectPath,
      cwd: resolvedProjectPath,
      toolsSettings,
      permissionMode,
      basePermissionMode,
      model: claudeModel || safeLocalStorage.getItem('claude-model') || CLAUDE_MODELS.DEFAULT,
      sessionSummary,
      ...(alwaysOnPlanId ? { alwaysOnPlanId } : {}),
      ...(alwaysOnExecutionToken ? { alwaysOnExecutionToken } : {}),
      ...(Array.isArray(images) && images.length > 0 ? { images } : {}),
    },
  });

  return sessionToActivate;
}
