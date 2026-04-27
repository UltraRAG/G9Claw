import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
} from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  Folder,
  PanelLeftClose,
  Pencil,
  Plus,
  Settings as SettingsIcon,
  Trash2,
} from 'lucide-react';
import type { AppTab, Project, ProjectSession, SessionProvider } from '../../types/app';
import { cn } from '../../lib/utils.js';
import {
  projectDisplayName,
  sessionDisplayTitle,
  setProjectCustomName,
  setSessionCustomTitle,
  useCustomNamesVersion,
} from '../../lib/customNames';

const asTimestamp = (value: unknown): number => {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
};

type FlatSession = {
  session: ProjectSession;
  sessionId: string;
  provider: SessionProvider;
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
        session: s,
        sessionId: s.id,
        provider: s.__provider ?? provider,
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
  // Opens the "Add project" wizard (local existing / new local / github clone).
  // Distinct from onStartNewSession which only spawns a chat under an existing
  // project. The Projects-section "+" wires to this.
  onCreateProject: () => void;
  // Hover-revealed trash on each project row asks the shell to confirm + delete.
  // The shell owns the confirm dialog so styling stays consistent with V2.
  onRequestDeleteProject: (project: Project) => void;
  onShowSettings: () => void;
  onCollapse?: () => void;
};

// Two-section sidebar:
//   ┌─ general ────────────────────────────────┐
//   │  · session A                             │
//   │  · session B  …                          │
//   ├─ Projects ───────────────────────────────┤
//   │  📁 project-x                            │
//   │  📁 project-y                            │
//   └──────────────────────────────────────────┘
//
// "general" is a special bucket that flattens all `general` project sessions
// directly into the sidebar — no nested expansion, no project row. Every
// other project is rendered as a single row under "Projects" without its
// session children; users dive into a project via the row, then start /
// switch sessions from the main pane (Chat tab + the +session companion in
// the tab bar). Tools live in the main area's horizontal tab bar.
//
// Rename overlay: project + session names can be relabelled inline via the
// hover-pencil button. The override lives in localStorage (see
// lib/customNames.ts) — folder names + session ids on disk are unchanged
// so all backend calls and routing stay stable.
export default function SidebarV2({
  projects,
  selectedProject,
  selectedSession,
  activeTab,
  isLoading,
  onSelectProject,
  onSelectSession,
  onStartNewSession,
  onCreateProject,
  onRequestDeleteProject,
  onShowSettings,
  onCollapse,
}: SidebarV2Props) {
  const { t } = useTranslation();
  const navigate = useNavigate();

  // Subscribe to rename overlay changes so display strings refresh after
  // we (or another tab) mutate the localStorage map.
  useCustomNamesVersion();

  // Inline-rename state. Only one row can be in edit mode at a time. We key
  // sessions by id and projects by canonical folder name.
  const [renamingProject, setRenamingProject] = useState<string | null>(null);
  const [renamingSession, setRenamingSession] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState<string>('');
  const renameInputRef = useRef<HTMLInputElement | null>(null);

  // Auto-focus + select the input contents when entering rename mode.
  useEffect(() => {
    if ((renamingProject || renamingSession) && renameInputRef.current) {
      renameInputRef.current.focus();
      renameInputRef.current.select();
    }
  }, [renamingProject, renamingSession]);

  // Split projects into the special "general" bucket vs everything else. We
  // tolerate either `name === 'general'` or `displayName === 'general'` so
  // either form of project metadata works.
  const generalProject =
    projects.find((p) => p.name === 'general' || p.displayName === 'general') ?? null;
  const otherProjects = projects.filter((p) => p !== generalProject);
  const generalSessions = generalProject ? collectSessionsForProject(generalProject) : [];
  const visibleGeneralSessions = generalSessions.slice(0, 30);

  const navToProject = useCallback(
    (name: string) => navigate(`/p/${encodeURIComponent(name)}`),
    [navigate],
  );

  const handleProjectClick = useCallback(
    (project: Project) => {
      // Don't navigate if we're currently editing this project's name —
      // the row is in input mode and a click on the input shouldn't bubble
      // to project-select. (Defensive: handlers below also stopPropagation.)
      if (renamingProject === project.name) return;
      onSelectProject(project);
      navToProject(project.name);
    },
    [navToProject, onSelectProject, renamingProject],
  );

  const handleGeneralSessionClick = useCallback(
    (sessionId: string) => {
      if (renamingSession === sessionId) return;
      if (!generalProject) return;
      onSelectSession(generalProject, sessionId);
    },
    [generalProject, onSelectSession, renamingSession],
  );

  const handleNewSessionForProject = useCallback(
    (event: MouseEvent, project: Project) => {
      event.stopPropagation();
      onStartNewSession(project);
      navToProject(project.name);
    },
    [navToProject, onStartNewSession],
  );

  const handleNewSessionForGeneral = useCallback(
    (event: MouseEvent) => {
      event.stopPropagation();
      if (!generalProject) return;
      onStartNewSession(generalProject);
      navToProject(generalProject.name);
    },
    [generalProject, navToProject, onStartNewSession],
  );

  const handleDeleteClick = useCallback(
    (event: MouseEvent, project: Project) => {
      event.stopPropagation();
      onRequestDeleteProject(project);
    },
    [onRequestDeleteProject],
  );

  // ── Rename handlers ────────────────────────────────────────────────────

  const beginRenameProject = useCallback(
    (event: MouseEvent, project: Project) => {
      event.stopPropagation();
      setRenamingSession(null);
      setRenamingProject(project.name);
      setRenameDraft(projectDisplayName(project));
    },
    [],
  );

  const beginRenameSession = useCallback(
    (event: MouseEvent, session: ProjectSession) => {
      event.stopPropagation();
      setRenamingProject(null);
      setRenamingSession(session.id);
      setRenameDraft(sessionDisplayTitle(session));
    },
    [],
  );

  const commitProjectRename = useCallback(() => {
    if (!renamingProject) return;
    // Empty string clears the override and falls back to the original
    // displayName/name — matching common UX in renamers like Finder.
    setProjectCustomName(renamingProject, renameDraft);
    setRenamingProject(null);
    setRenameDraft('');
  }, [renamingProject, renameDraft]);

  const commitSessionRename = useCallback(() => {
    if (!renamingSession) return;
    setSessionCustomTitle(renamingSession, renameDraft);
    setRenamingSession(null);
    setRenameDraft('');
  }, [renamingSession, renameDraft]);

  const cancelRename = useCallback(() => {
    setRenamingProject(null);
    setRenamingSession(null);
    setRenameDraft('');
  }, []);

  const handleRenameKey = useCallback(
    (event: KeyboardEvent<HTMLInputElement>, kind: 'project' | 'session') => {
      if (event.key === 'Enter') {
        event.preventDefault();
        if (kind === 'project') commitProjectRename();
        else commitSessionRename();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        cancelRename();
      }
    },
    [cancelRename, commitProjectRename, commitSessionRename],
  );

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

      {/* Body: scrollable content with two sections */}
      <div className="scrollbar-thin min-h-0 flex-1 overflow-y-auto px-2 pb-2">
        {isLoading && projects.length === 0 ? (
          <div className="px-2 py-4 text-xs text-neutral-500 dark:text-neutral-400">
            {t('loading', { defaultValue: 'Loading…' })}
          </div>
        ) : (
          <>
            {/* general — flat list of sessions belonging to the `general`
                project. Header has a +session companion that creates a
                fresh session in general and navigates to Chat. */}
            <section className="pt-3">
              <div className="group/general flex items-center px-3 pb-1">
                <span className="flex-1 text-[11px] font-medium uppercase tracking-[0.04em] text-neutral-500/90 dark:text-neutral-400/80">
                  general
                </span>
                {generalProject ? (
                  <button
                    type="button"
                    onClick={handleNewSessionForGeneral}
                    aria-label={t('newSessionInProject', { defaultValue: 'New session' })}
                    title={t('newSessionInProject', { defaultValue: 'New session' })}
                    className={cn(
                      'inline-flex h-6 w-6 items-center justify-center rounded-md',
                      'text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900',
                      'dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100',
                      'opacity-0 group-hover/general:opacity-100 focus-within:opacity-100',
                      '[@media(hover:none)]:opacity-100',
                    )}
                  >
                    <Plus className="h-3.5 w-3.5" strokeWidth={1.75} />
                  </button>
                ) : null}
              </div>
              {generalProject ? (
                visibleGeneralSessions.length > 0 ? (
                  <div className="space-y-0.5">
                    {visibleGeneralSessions.map(({ session, sessionId, lastActivity }) => {
                      const isSessionActive =
                        selectedProject?.name === generalProject.name &&
                        selectedSession?.id === sessionId &&
                        activeTab === 'chat';
                      const isRenaming = renamingSession === sessionId;
                      return (
                        <div
                          key={sessionId}
                          className={cn(
                            'group/session relative w-full rounded-md transition-colors',
                            isSessionActive
                              ? 'bg-neutral-200/70 dark:bg-neutral-800'
                              : 'hover:bg-neutral-100 dark:hover:bg-neutral-800',
                          )}
                        >
                          {isRenaming ? (
                            <div className="flex items-center px-2 py-1">
                              <input
                                ref={renameInputRef}
                                value={renameDraft}
                                onChange={(e) => setRenameDraft(e.target.value)}
                                onBlur={commitSessionRename}
                                onKeyDown={(e) => handleRenameKey(e, 'session')}
                                onClick={(e) => e.stopPropagation()}
                                placeholder={t('renamePlaceholder', { defaultValue: 'Rename — empty to reset' }) as string}
                                className="w-full rounded-sm border border-neutral-300 bg-white px-1.5 py-0.5 text-[12.5px] text-neutral-900 outline-none focus:border-neutral-500 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
                              />
                            </div>
                          ) : (
                            <button
                              type="button"
                              onClick={() => handleGeneralSessionClick(sessionId)}
                              className="block w-full px-2 py-1 pr-7 text-left"
                            >
                              <div className="truncate text-[12.5px] text-neutral-900 dark:text-neutral-100">
                                {sessionDisplayTitle(session)}
                              </div>
                              <div className="text-[11px] text-neutral-500 dark:text-neutral-400">
                                {formatRelative(lastActivity)}
                              </div>
                            </button>
                          )}
                          {!isRenaming ? (
                            <button
                              type="button"
                              onClick={(e) => beginRenameSession(e, session)}
                              aria-label={t('rename', { defaultValue: 'Rename' }) as string}
                              title={t('rename', { defaultValue: 'Rename' }) as string}
                              className={cn(
                                'absolute right-1 top-1 inline-flex h-6 w-6 items-center justify-center rounded-md',
                                'text-neutral-500 hover:bg-neutral-200/80 hover:text-neutral-900',
                                'dark:text-neutral-400 dark:hover:bg-neutral-700 dark:hover:text-neutral-100',
                                'opacity-0 group-hover/session:opacity-100 focus-within:opacity-100',
                                '[@media(hover:none)]:opacity-100',
                              )}
                            >
                              <Pencil className="h-3 w-3" strokeWidth={1.75} />
                            </button>
                          ) : null}
                        </div>
                      );
                    })}
                  </div>
                ) : (
                  <div className="px-3 py-1 text-[11px] text-neutral-500 dark:text-neutral-400">
                    {t('empty.sessions', { defaultValue: 'No sessions yet' })}
                  </div>
                )
              ) : (
                <div className="px-3 py-1 text-[11px] text-neutral-500 dark:text-neutral-400">
                  {t('empty.noGeneral', {
                    defaultValue: 'No general project — start one from "+ New project"',
                  })}
                </div>
              )}
            </section>

            {/* Projects — every other project as a flat row (no nested
                sessions). Header has a "+ project" button that opens the
                creation wizard. */}
            <section className="pt-4">
              <div className="flex items-center px-3 pb-1">
                <span className="flex-1 text-[11px] font-medium uppercase tracking-[0.04em] text-neutral-500/90 dark:text-neutral-400/80">
                  {t('sections.projects', { defaultValue: 'Projects' })}
                </span>
                <button
                  type="button"
                  onClick={onCreateProject}
                  aria-label={t('newProject', { defaultValue: 'New project' })}
                  title={t('newProject', { defaultValue: 'New project' })}
                  className="inline-flex h-6 w-6 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
                >
                  <Plus className="h-3.5 w-3.5" strokeWidth={1.75} />
                </button>
              </div>

              {otherProjects.length === 0 ? (
                <div className="px-3 py-1 text-[11px] text-neutral-500 dark:text-neutral-400">
                  {t('empty.projects', { defaultValue: 'No projects yet' })}
                </div>
              ) : (
                <div className="space-y-0.5">
                  {otherProjects.map((project) => {
                    const isSelected = project.name === selectedProject?.name;
                    const isRenaming = renamingProject === project.name;

                    return (
                      <div
                        key={project.name}
                        className={cn(
                          'group/project flex h-8 w-full items-center rounded-lg pr-1 text-[13px] transition-colors',
                          isSelected
                            ? 'bg-neutral-200/70 text-neutral-900 dark:bg-neutral-800 dark:text-neutral-100'
                            : 'text-neutral-700 hover:bg-neutral-100 dark:text-neutral-300 dark:hover:bg-neutral-800',
                        )}
                      >
                        {isRenaming ? (
                          // Edit mode: replace the click row with an input.
                          // Folder icon stays for visual continuity.
                          <div className="flex h-full min-w-0 flex-1 items-center gap-1.5 pl-2 pr-1">
                            <Folder
                              className={cn(
                                'h-3.5 w-3.5 shrink-0',
                                isSelected
                                  ? 'text-neutral-900 dark:text-neutral-100'
                                  : 'text-neutral-500 dark:text-neutral-400',
                              )}
                              strokeWidth={1.75}
                            />
                            <input
                              ref={renameInputRef}
                              value={renameDraft}
                              onChange={(e) => setRenameDraft(e.target.value)}
                              onBlur={commitProjectRename}
                              onKeyDown={(e) => handleRenameKey(e, 'project')}
                              onClick={(e) => e.stopPropagation()}
                              placeholder={t('renamePlaceholder', { defaultValue: 'Rename — empty to reset' }) as string}
                              className="w-full rounded-sm border border-neutral-300 bg-white px-1.5 py-0.5 text-[12.5px] text-neutral-900 outline-none focus:border-neutral-500 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-100"
                            />
                          </div>
                        ) : (
                          <button
                            type="button"
                            onClick={() => handleProjectClick(project)}
                            className="flex h-full min-w-0 flex-1 items-center gap-1.5 rounded-l-lg pl-2 pr-1 text-left"
                          >
                            <Folder
                              className={cn(
                                'h-3.5 w-3.5 shrink-0',
                                isSelected
                                  ? 'text-neutral-900 dark:text-neutral-100'
                                  : 'text-neutral-500 dark:text-neutral-400',
                              )}
                              strokeWidth={1.75}
                            />
                            <span className="flex-1 truncate">
                              {projectDisplayName(project)}
                            </span>
                          </button>
                        )}
                        {!isRenaming ? (
                          <div
                            className={cn(
                              'ml-1 flex shrink-0 items-center gap-0.5 transition-opacity',
                              '[@media(hover:none)]:opacity-100',
                              isSelected
                                ? 'opacity-100'
                                : 'opacity-0 group-hover/project:opacity-100 focus-within:opacity-100',
                            )}
                          >
                            <button
                              type="button"
                              onClick={(e) => beginRenameProject(e, project)}
                              aria-label={t('rename', { defaultValue: 'Rename' }) as string}
                              title={t('rename', { defaultValue: 'Rename' }) as string}
                              className={cn(
                                'inline-flex h-6 w-6 items-center justify-center rounded-md',
                                'text-neutral-500 hover:bg-neutral-200/70 hover:text-neutral-900',
                                'dark:text-neutral-400 dark:hover:bg-neutral-700 dark:hover:text-neutral-100',
                              )}
                            >
                              <Pencil className="h-3 w-3" strokeWidth={1.75} />
                            </button>
                            <button
                              type="button"
                              onClick={(e) => handleNewSessionForProject(e, project)}
                              aria-label={t('newSessionInProject', { defaultValue: 'New session' })}
                              title={t('newSessionInProject', { defaultValue: 'New session' })}
                              className={cn(
                                'inline-flex h-6 w-6 items-center justify-center rounded-md',
                                'text-neutral-500 hover:bg-neutral-200/70 hover:text-neutral-900',
                                'dark:text-neutral-400 dark:hover:bg-neutral-700 dark:hover:text-neutral-100',
                              )}
                            >
                              <Plus className="h-3.5 w-3.5" strokeWidth={1.75} />
                            </button>
                            <button
                              type="button"
                              onClick={(e) => handleDeleteClick(e, project)}
                              aria-label={t('deleteProject', { defaultValue: 'Delete project' })}
                              title={t('deleteProject', { defaultValue: 'Delete project' })}
                              className={cn(
                                'inline-flex h-6 w-6 items-center justify-center rounded-md',
                                'text-neutral-500 hover:bg-red-50 hover:text-red-600',
                                'dark:text-neutral-400 dark:hover:bg-red-950/40 dark:hover:text-red-400',
                                'focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-red-400',
                              )}
                            >
                              <Trash2 className="h-3.5 w-3.5" strokeWidth={1.75} />
                            </button>
                          </div>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              )}
            </section>
          </>
        )}
      </div>

      {/* Footer: just the Settings entry point. The avatar/username block was
          removed per UX request — multi-user surfaces still live behind the
          auth flow but didn't earn space in the V2 chrome. */}
      <div className="flex items-center justify-end border-t border-neutral-200 px-3 py-2 dark:border-neutral-800">
        <button
          type="button"
          onClick={onShowSettings}
          aria-label="Settings"
          title="Settings"
          className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
        >
          <SettingsIcon className="h-4 w-4" strokeWidth={1.75} />
        </button>
      </div>
    </aside>
  );
}
