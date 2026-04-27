import { useMemo, type ComponentType } from 'react';
import { useTranslation } from 'react-i18next';
import { ArrowRight, FileCode, MessageSquarePlus, Plus } from 'lucide-react';
import type { AppTab, Project, ProjectSession, SessionProvider } from '../../types/app';
import { useFileTreeData } from '../file-tree/hooks/useFileTreeData';
import { getFileIconData } from '../file-tree/constants/fileIcons';
import { cn } from '../../lib/utils.js';

// Project landing page. Shows recent sessions (left) and a top-level files
// preview (right). Each session row resumes its chat in the Chat tab; the
// Files preview links to the Files tab for the full tree. Designed to be the
// default first-impression view when a project is selected.

type HomeV2Props = {
  selectedProject: Project | null;
  onSelectTab: (tab: AppTab) => void;
  onSelectSession: (project: Project, sessionId: string) => void;
  onStartNewSession: (project: Project) => void;
  onFileOpen?: (filePath: string) => void;
};

type FlatSession = {
  sessionId: string;
  provider: SessionProvider;
  title: string;
  lastActivity: number;
};

const asTimestamp = (value: unknown): number => {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
};

const sessionTitle = (session: ProjectSession): string =>
  (typeof session.summary === 'string' && session.summary) ||
  (typeof session.title === 'string' && session.title) ||
  (typeof session.name === 'string' && session.name) ||
  session.id;

const collectSessions = (project: Project): FlatSession[] => {
  const all: Array<[SessionProvider, ProjectSession[]]> = [
    ['claude', project.sessions ?? []],
    ['codex', project.codexSessions ?? []],
    ['cursor', project.cursorSessions ?? []],
    ['gemini', project.geminiSessions ?? []],
  ];
  const entries: FlatSession[] = [];
  for (const [provider, sessions] of all) {
    for (const s of sessions) {
      entries.push({
        sessionId: s.id,
        provider: s.__provider ?? provider,
        title: sessionTitle(s),
        lastActivity: Math.max(
          asTimestamp(s.lastActivity),
          asTimestamp(s.updated_at),
          asTimestamp(s.createdAt),
          asTimestamp(s.created_at),
        ),
      });
    }
  }
  return entries.sort((a, b) => b.lastActivity - a.lastActivity);
};

const formatRelative = (ts: number): string => {
  if (!ts) return '';
  const diff = Date.now() - ts;
  if (diff < 60_000) return 'just now';
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
};

const PROVIDER_LABEL: Record<SessionProvider, string> = {
  claude: 'Claude',
  codex: 'Codex',
  cursor: 'Cursor',
  gemini: 'Gemini',
};

export default function HomeV2({
  selectedProject,
  onSelectTab,
  onSelectSession,
  onStartNewSession,
  onFileOpen,
}: HomeV2Props) {
  const { t } = useTranslation();
  const { files, loading: filesLoading } = useFileTreeData(selectedProject);

  const sessions = useMemo(
    () => (selectedProject ? collectSessions(selectedProject).slice(0, 8) : []),
    [selectedProject],
  );

  // Top-level entries only (max 12) — Home is a glance, not the full tree.
  const topLevelFiles = useMemo(() => files.slice(0, 12), [files]);

  if (!selectedProject) {
    return (
      <div className="flex h-full items-center justify-center p-8">
        <div className="max-w-md text-center">
          <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-xl bg-neutral-100 text-neutral-500 dark:bg-neutral-800 dark:text-neutral-400">
            <FileCode className="h-6 w-6" strokeWidth={1.75} />
          </div>
          <h2 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
            {t('home.empty.title', { defaultValue: 'Pick a project to get started' })}
          </h2>
          <p className="mt-1 text-sm text-neutral-500 dark:text-neutral-400">
            {t('home.empty.body', {
              defaultValue:
                'Select a project from the sidebar, or create a new one with the + button above the project list.',
            })}
          </p>
        </div>
      </div>
    );
  }

  const projectName = selectedProject.displayName || selectedProject.name;
  const projectPath = selectedProject.fullPath || selectedProject.path;

  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-5xl px-6 py-6">
        {/* Project header */}
        <div className="mb-6">
          <h1 className="truncate text-xl font-semibold tracking-tight text-neutral-900 dark:text-neutral-100">
            {projectName}
          </h1>
          {projectPath ? (
            <p className="mt-0.5 truncate font-mono text-[12px] text-neutral-500 dark:text-neutral-400">
              {projectPath}
            </p>
          ) : null}
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => onStartNewSession(selectedProject)}
              className="inline-flex h-8 items-center gap-1.5 rounded-md bg-neutral-900 px-3 text-[13px] font-medium text-neutral-50 hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              <Plus className="h-3.5 w-3.5" strokeWidth={2} />
              <span>{t('home.newSession', { defaultValue: 'New session' })}</span>
            </button>
            <button
              type="button"
              onClick={() => onSelectTab('chat')}
              className="inline-flex h-8 items-center gap-1.5 rounded-md border border-neutral-200 bg-white px-3 text-[13px] font-medium text-neutral-900 hover:bg-neutral-100 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:hover:bg-neutral-800"
            >
              <MessageSquarePlus className="h-3.5 w-3.5" strokeWidth={1.75} />
              <span>{t('home.openChat', { defaultValue: 'Open chat' })}</span>
            </button>
          </div>
        </div>

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
          {/* Recent sessions */}
          <section className="rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900">
            <header className="flex items-center justify-between border-b border-neutral-200 px-4 py-2.5 dark:border-neutral-800">
              <h2 className="text-[13px] font-semibold text-neutral-900 dark:text-neutral-100">
                {t('home.recentSessions', { defaultValue: 'Recent sessions' })}
              </h2>
              <button
                type="button"
                onClick={() => onSelectTab('chat')}
                className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[12px] text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
              >
                <span>{t('home.openTab.chat', { defaultValue: 'Open Chat' })}</span>
                <ArrowRight className="h-3 w-3" strokeWidth={1.75} />
              </button>
            </header>
            {sessions.length === 0 ? (
              <div className="px-4 py-8 text-center text-[12.5px] text-neutral-500 dark:text-neutral-400">
                {t('home.noSessions', {
                  defaultValue: 'No sessions yet. Click “New session” above to start one.',
                })}
              </div>
            ) : (
              <ul className="divide-y divide-neutral-200 dark:divide-neutral-800">
                {sessions.map((s) => (
                  <li key={s.sessionId}>
                    <button
                      type="button"
                      onClick={() => onSelectSession(selectedProject, s.sessionId)}
                      className="flex w-full items-start gap-3 px-4 py-2.5 text-left hover:bg-neutral-50 dark:hover:bg-neutral-800/60"
                    >
                      <span
                        className={cn(
                          'mt-0.5 inline-flex shrink-0 items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide',
                          'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-300',
                        )}
                      >
                        {PROVIDER_LABEL[s.provider]}
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-[13px] text-neutral-900 dark:text-neutral-100">
                          {s.title}
                        </div>
                        <div className="text-[11px] text-neutral-500 dark:text-neutral-400">
                          {formatRelative(s.lastActivity)}
                        </div>
                      </div>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Files preview */}
          <section className="rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900">
            <header className="flex items-center justify-between border-b border-neutral-200 px-4 py-2.5 dark:border-neutral-800">
              <h2 className="text-[13px] font-semibold text-neutral-900 dark:text-neutral-100">
                {t('home.files', { defaultValue: 'Files' })}
              </h2>
              <button
                type="button"
                onClick={() => onSelectTab('files')}
                className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[12px] text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
              >
                <span>{t('home.openTab.files', { defaultValue: 'Open Files' })}</span>
                <ArrowRight className="h-3 w-3" strokeWidth={1.75} />
              </button>
            </header>
            {filesLoading && topLevelFiles.length === 0 ? (
              <div className="px-4 py-8 text-center text-[12.5px] text-neutral-500 dark:text-neutral-400">
                {t('loading', { defaultValue: 'Loading…' })}
              </div>
            ) : topLevelFiles.length === 0 ? (
              <div className="px-4 py-8 text-center text-[12.5px] text-neutral-500 dark:text-neutral-400">
                {t('home.noFiles', { defaultValue: 'No files indexed for this project.' })}
              </div>
            ) : (
              <ul className="divide-y divide-neutral-200 dark:divide-neutral-800">
                {topLevelFiles.map((node) => {
                  const isDir = node.type === 'directory';
                  // getFileIconData returns a lucide-react component +
                  // Tailwind color class — not a CSS color. Capitalize the
                  // local so JSX treats it as a component, and apply the
                  // class via className (NOT style={{ color }}).
                  let Icon: ComponentType<{ className?: string; strokeWidth?: number }> =
                    FileCode;
                  let colorClass = 'text-neutral-500 dark:text-neutral-400';
                  if (!isDir) {
                    const iconData = getFileIconData(node.name);
                    Icon = iconData.icon;
                    colorClass = iconData.color;
                  }
                  return (
                    <li key={node.path}>
                      <button
                        type="button"
                        onClick={() => {
                          if (isDir) {
                            onSelectTab('files');
                          } else if (onFileOpen) {
                            onFileOpen(node.path);
                          } else {
                            onSelectTab('files');
                          }
                        }}
                        className="flex w-full items-center gap-2 px-4 py-2 text-left hover:bg-neutral-50 dark:hover:bg-neutral-800/60"
                      >
                        {isDir ? (
                          <span className="text-[13px] leading-none">📁</span>
                        ) : (
                          <Icon
                            className={cn('h-3.5 w-3.5 shrink-0', colorClass)}
                            strokeWidth={1.75}
                          />
                        )}
                        <span className="truncate text-[13px] text-neutral-900 dark:text-neutral-100">
                          {node.name}
                        </span>
                        {isDir ? (
                          <span className="ml-auto text-[11px] text-neutral-500 dark:text-neutral-400">
                            dir
                          </span>
                        ) : null}
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
