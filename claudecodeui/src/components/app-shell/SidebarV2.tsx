import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  BarChart3,
  ChevronDown,
  ChevronRight,
  Database,
  Folder,
  GitBranch,
  ListChecks,
  MessageSquare,
  PanelLeftClose,
  Plus,
  Radio,
  Settings as SettingsIcon,
  Terminal,
  type LucideIcon,
} from 'lucide-react';
import type { AppTab, Project, ProjectSession, SessionProvider } from '../../types/app';
import { useTasksSettings } from '../../contexts/TasksSettingsContext';
import { useAuth } from '../auth';
import { cn } from '../../lib/utils.js';

type ToolTab = { id: AppTab; labelKey: string; icon: LucideIcon };

// Single source of truth; mirrors the prototype "Tools" section 1:1. Order
// matters — the prototype puts Chat first, then reactive tools (Always-On),
// then dev tools (Shell/Files/Git), then horizons (Dashboard/Tasks/Memory).
const TOOL_TABS: ToolTab[] = [
  { id: 'chat',      labelKey: 'tabs.chat',      icon: MessageSquare },
  { id: 'always-on', labelKey: 'tabs.alwaysOn',  icon: Radio },
  { id: 'shell',     labelKey: 'tabs.shell',     icon: Terminal },
  { id: 'files',     labelKey: 'tabs.files',     icon: Folder },
  { id: 'git',       labelKey: 'tabs.git',       icon: GitBranch },
  { id: 'dashboard', labelKey: 'tabs.dashboard', icon: BarChart3 },
  { id: 'tasks',     labelKey: 'tabs.tasks',     icon: ListChecks },
  { id: 'memory',    labelKey: 'tabs.memory',    icon: Database },
];

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

type FlatSession = {
  sessionId: string;
  provider: SessionProvider;
  title: string;
  lastActivity: number;
};

const collectSessionsForProject = (project: Project): FlatSession[] => {
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

export type SidebarV2Props = {
  projects: Project[];
  selectedProject: Project | null;
  selectedSession: ProjectSession | null;
  activeTab: AppTab;
  isLoading: boolean;
  onSelectTab: (tab: AppTab) => void;
  onSelectProject: (project: Project) => void;
  onSelectSession: (project: Project, sessionId: string) => void;
  onStartNewSession: (project: Project | null) => void;
  onShowSettings: () => void;
  onCollapse?: () => void;
};

export default function SidebarV2({
  projects,
  selectedProject,
  selectedSession,
  activeTab,
  isLoading,
  onSelectTab,
  onSelectProject,
  onSelectSession,
  onStartNewSession,
  onShowSettings,
  onCollapse,
}: SidebarV2Props) {
  // defaultNS is 'common' and all tab labels (`tabs.*`) live there — rely on
  // that instead of namespacing so we don't have to preload `sidebar` just to
  // resolve tool labels.
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { user } = useAuth() as { user: { username?: string } | null };
  const { tasksEnabled, isTaskMasterInstalled } = useTasksSettings() as {
    tasksEnabled: boolean;
    isTaskMasterInstalled: boolean | null;
  };
  const shouldShowTasksTab = Boolean(tasksEnabled && isTaskMasterInstalled);

  // Track which projects are expanded in the sidebar tree. The selected
  // project is auto-expanded; others start collapsed to keep the list scannable.
  const [manualExpansion, setManualExpansion] = useState<Record<string, boolean>>({});

  const visibleToolTabs = useMemo(
    () => TOOL_TABS.filter((tool) => tool.id !== 'tasks' || shouldShowTasksTab),
    [shouldShowTasksTab],
  );

  const username = user?.username || 'guest';
  const initials = username.slice(0, 2).toUpperCase();

  const isExpanded = (project: Project) => {
    if (manualExpansion[project.name] !== undefined) {
      return manualExpansion[project.name];
    }
    return project.name === selectedProject?.name;
  };

  const toggleExpansion = (project: Project) => {
    setManualExpansion((prev) => ({
      ...prev,
      [project.name]: !isExpanded(project),
    }));
  };

  const handleNewChat = () => {
    onStartNewSession(selectedProject);
    onSelectTab('chat');
    if (selectedProject) {
      navigate(`/p/${encodeURIComponent(selectedProject.name)}`);
    } else {
      navigate('/');
    }
  };

  return (
    <aside
      className={cn(
        'flex h-full w-[272px] shrink-0 flex-col',
        'bg-neutral-50 text-neutral-900',
        'dark:bg-neutral-900 dark:text-neutral-100',
        'border-r border-neutral-200 dark:border-neutral-800',
      )}
    >
      {/* Header: E logo + edgeclaw wordmark + collapse */}
      <div className="flex h-12 items-center border-b border-neutral-200 px-3 dark:border-neutral-800">
        <button
          type="button"
          onClick={() => navigate('/')}
          className="flex items-center gap-2"
        >
          <span className="flex h-6 w-6 items-center justify-center rounded-md bg-neutral-900 text-[11px] font-semibold text-neutral-50 dark:bg-neutral-50 dark:text-neutral-900">
            E
          </span>
          <span className="text-[13px] font-medium tracking-tight">edgeclaw</span>
        </button>
        {onCollapse ? (
          <button
            type="button"
            onClick={onCollapse}
            aria-label="Collapse sidebar"
            className="ml-auto inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
          >
            <PanelLeftClose className="h-4 w-4" strokeWidth={1.75} />
          </button>
        ) : null}
      </div>

      {/* New chat */}
      <div className="px-3 pt-3">
        <button
          type="button"
          onClick={handleNewChat}
          className={cn(
            'flex h-9 w-full items-center gap-2 rounded-lg px-3',
            'border border-neutral-200 bg-transparent text-[13px] text-neutral-900',
            'hover:bg-neutral-100',
            'dark:border-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-800',
          )}
        >
          <Plus className="h-4 w-4" strokeWidth={1.75} />
          <span className="flex-1 text-left">{t('newChat', { defaultValue: 'New chat' })}</span>
          <kbd className="rounded border border-neutral-200 bg-white px-1.5 py-px text-[10px] text-neutral-500 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400">
            ⌘N
          </kbd>
        </button>
      </div>

      {/* Tools section */}
      <div className="px-3 pb-1 pt-3.5 text-[11px] font-medium uppercase tracking-[0.04em] text-neutral-500/90 dark:text-neutral-400/80">
        {t('sections.tools', { defaultValue: 'Tools' })}
      </div>
      <nav className="flex flex-col gap-0.5 px-2">
        {visibleToolTabs.map((tool) => {
          const Icon = tool.icon;
          const isActive = activeTab === tool.id;
          return (
            <button
              key={tool.id}
              type="button"
              onClick={() => onSelectTab(tool.id)}
              className={cn(
                'group flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-[13px] leading-tight',
                'transition-colors',
                isActive
                  ? 'bg-neutral-200/70 font-medium text-neutral-900 dark:bg-neutral-800 dark:text-neutral-100'
                  : 'text-neutral-700 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-300 dark:hover:bg-neutral-800 dark:hover:text-neutral-100',
              )}
            >
              <Icon
                className={cn(
                  'h-4 w-4 shrink-0',
                  isActive
                    ? 'text-neutral-900 dark:text-neutral-100'
                    : 'text-neutral-500 dark:text-neutral-400',
                )}
                strokeWidth={1.75}
              />
              <span className="flex-1 truncate text-left">{t(tool.labelKey)}</span>
            </button>
          );
        })}
      </nav>

      {/* Projects section */}
      <div className="flex items-center px-3 pb-1 pt-3.5">
        <span className="flex-1 text-[11px] font-medium uppercase tracking-[0.04em] text-neutral-500/90 dark:text-neutral-400/80">
          {t('sections.projects', { defaultValue: 'Projects' })}
        </span>
        <button
          type="button"
          onClick={() => onStartNewSession(null)}
          aria-label={t('newProject', { defaultValue: 'New project' })}
          className="inline-flex h-6 w-6 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
        >
          <Plus className="h-3.5 w-3.5" strokeWidth={1.75} />
        </button>
      </div>

      <div className="scrollbar-thin min-h-0 flex-1 overflow-y-auto px-2 pb-2">
        {isLoading && projects.length === 0 ? (
          <div className="px-2 py-4 text-xs text-neutral-500 dark:text-neutral-400">
            {t('loading', { defaultValue: 'Loading…' })}
          </div>
        ) : projects.length === 0 ? (
          <div className="px-2 py-4 text-xs text-neutral-500 dark:text-neutral-400">
            {t('empty.projects', { defaultValue: 'No projects yet' })}
          </div>
        ) : (
          projects.map((project) => {
            const expanded = isExpanded(project);
            const isSelected = project.name === selectedProject?.name;
            const projectSessions = collectSessionsForProject(project).slice(0, 8);
            const sessionCount =
              (project.sessions?.length ?? 0) +
              (project.codexSessions?.length ?? 0) +
              (project.cursorSessions?.length ?? 0) +
              (project.geminiSessions?.length ?? 0);

            return (
              <div key={project.name} className="space-y-0.5">
                <button
                  type="button"
                  onClick={() => {
                    onSelectProject(project);
                    toggleExpansion(project);
                  }}
                  className={cn(
                    'flex h-8 w-full items-center gap-2 rounded-lg px-2 text-[13px] transition-colors',
                    isSelected
                      ? 'bg-neutral-200/70 text-neutral-900 dark:bg-neutral-800 dark:text-neutral-100'
                      : 'text-neutral-700 hover:bg-neutral-100 dark:text-neutral-300 dark:hover:bg-neutral-800',
                  )}
                >
                  {expanded ? (
                    <ChevronDown className="h-3.5 w-3.5 shrink-0 text-neutral-500 dark:text-neutral-400" strokeWidth={1.75} />
                  ) : (
                    <ChevronRight className="h-3.5 w-3.5 shrink-0 text-neutral-500 dark:text-neutral-400" strokeWidth={1.75} />
                  )}
                  <span className="flex-1 truncate text-left">
                    {project.displayName || project.name}
                  </span>
                  {sessionCount > 0 ? (
                    <span className="text-[11px] text-neutral-500 dark:text-neutral-400">{sessionCount}</span>
                  ) : null}
                </button>

                {expanded && projectSessions.length > 0 ? (
                  <div className="mt-0.5 space-y-0.5 pl-6">
                    {projectSessions.map((session) => {
                      const isSessionActive =
                        isSelected && selectedSession?.id === session.sessionId && activeTab === 'chat';
                      return (
                        <button
                          key={session.sessionId}
                          type="button"
                          onClick={() => onSelectSession(project, session.sessionId)}
                          className={cn(
                            'block w-full rounded-md px-2 py-1.5 text-left',
                            isSessionActive
                              ? 'bg-neutral-200/70 dark:bg-neutral-800'
                              : 'hover:bg-neutral-100 dark:hover:bg-neutral-800',
                          )}
                        >
                          <div className="truncate text-[13px] text-neutral-900 dark:text-neutral-100">
                            {session.title}
                          </div>
                          <div className="text-[11px] text-neutral-500 dark:text-neutral-400">
                            {formatRelative(session.lastActivity)}
                          </div>
                        </button>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            );
          })
        )}
      </div>

      {/* Footer: avatar + user + settings */}
      <div className="flex items-center gap-2 border-t border-neutral-200 px-3 py-2.5 dark:border-neutral-800">
        <div className="flex h-7 w-7 items-center justify-center rounded-full bg-neutral-200 text-[11px] font-medium text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200">
          {initials}
        </div>
        <div className="min-w-0 flex-1 leading-tight">
          <div className="truncate text-[13px]">{username}</div>
          <div className="truncate text-[11px] text-neutral-500 dark:text-neutral-400">v0.8.2</div>
        </div>
        <button
          type="button"
          onClick={onShowSettings}
          aria-label="Settings"
          className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
        >
          <SettingsIcon className="h-4 w-4" strokeWidth={1.75} />
        </button>
      </div>
    </aside>
  );
}
