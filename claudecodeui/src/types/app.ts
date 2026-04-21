export type SessionProvider = 'claude' | 'cursor' | 'codex' | 'gemini';
export type ProjectSessionKind = 'background_task';

export type AppTab = 'chat' | 'always-on' | 'files' | 'shell' | 'git' | 'tasks' | 'preview' | `plugin:${string}`;

export type CronJobOverviewStatus = 'scheduled' | 'completed' | 'failed' | 'unknown';

export interface CronJobLatestRun {
  summary?: string;
  lastActivity?: string;
  taskId?: string;
  outputFile?: string;
  relativeTranscriptPath?: string;
}

export interface CronJobOverview {
  id: string;
  cron: string;
  prompt: string;
  createdAt: number;
  durable?: boolean;
  lastFiredAt?: number;
  recurring?: boolean;
  permanent?: boolean;
  originSessionId?: string;
  transcriptKey?: string;
  status: CronJobOverviewStatus;
  latestRun?: CronJobLatestRun | null;
}

export interface ProjectCronJobsResponse {
  jobs: CronJobOverview[];
}

export interface DeleteProjectCronJobResponse {
  deleted: boolean;
}

export type CronJobRunNowReason = 'already_running' | 'not_found';

export interface RunProjectCronJobNowResponse {
  started: boolean;
  reason?: CronJobRunNowReason;
}

export interface ProjectSession {
  id: string;
  title?: string;
  summary?: string;
  name?: string;
  createdAt?: string;
  created_at?: string;
  updated_at?: string;
  lastActivity?: string;
  messageCount?: number;
  sessionKind?: ProjectSessionKind;
  parentSessionId?: string;
  relativeTranscriptPath?: string;
  transcriptKey?: string;
  taskId?: string;
  taskStatus?: string;
  outputFile?: string;
  isReadOnly?: boolean;
  __provider?: SessionProvider;
  __projectName?: string;
  [key: string]: unknown;
}

export type SessionRequestParams = {
  sessionKind?: ProjectSessionKind;
  parentSessionId?: string;
  relativeTranscriptPath?: string;
};

export function isBackgroundTaskSession(
  session: ProjectSession | null | undefined,
): session is ProjectSession & {
  sessionKind: 'background_task';
  parentSessionId: string;
  relativeTranscriptPath: string;
} {
  return (
    session?.sessionKind === 'background_task' &&
    typeof session.parentSessionId === 'string' &&
    session.parentSessionId.length > 0 &&
    typeof session.relativeTranscriptPath === 'string' &&
    session.relativeTranscriptPath.length > 0
  );
}

export function getSessionRequestParams(
  session: ProjectSession | null | undefined,
): SessionRequestParams {
  if (!isBackgroundTaskSession(session)) {
    return {};
  }

  return {
    sessionKind: session.sessionKind,
    parentSessionId: session.parentSessionId,
    relativeTranscriptPath: session.relativeTranscriptPath,
  };
}

export interface ProjectSessionMeta {
  total?: number;
  hasMore?: boolean;
  [key: string]: unknown;
}

export interface ProjectTaskmasterInfo {
  hasTaskmaster?: boolean;
  status?: string;
  metadata?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface Project {
  name: string;
  displayName: string;
  fullPath: string;
  path?: string;
  sessions?: ProjectSession[];
  cursorSessions?: ProjectSession[];
  codexSessions?: ProjectSession[];
  geminiSessions?: ProjectSession[];
  sessionMeta?: ProjectSessionMeta;
  taskmaster?: ProjectTaskmasterInfo;
  [key: string]: unknown;
}

export interface LoadingProgress {
  type?: 'loading_progress';
  phase?: string;
  current: number;
  total: number;
  currentProject?: string;
  [key: string]: unknown;
}

export interface ProjectsUpdatedMessage {
  type: 'projects_updated';
  projects: Project[];
  changedFile?: string;
  [key: string]: unknown;
}

export interface LoadingProgressMessage extends LoadingProgress {
  type: 'loading_progress';
}

export type AppSocketMessage =
  | LoadingProgressMessage
  | ProjectsUpdatedMessage
  | { type?: string;[key: string]: unknown };
