import { useTranslation } from 'react-i18next';
import {
  BarChart3,
  Database,
  Folder,
  Home,
  ListChecks,
  MessageSquare,
  Plus,
  Radio,
  type LucideIcon,
} from 'lucide-react';
import type { AppTab, Project, ProjectSession } from '../../types/app';
import { useTasksSettings } from '../../contexts/TasksSettingsContext';
import MainContent from '../main-content/view/MainContent';
import type { MainContentProps } from '../main-content/types/types';
import { cn } from '../../lib/utils.js';
import { projectDisplayName, sessionDisplayTitle, useCustomNamesVersion } from '../../lib/customNames';

type Tab = { id: AppTab; labelKey: string; icon: LucideIcon };

// Order matches the tab bar in the prototype. `home` lands first as the
// project's "you are here" landing page; chat comes next because that's where
// most work happens. Plugin tabs aren't surfaced in this static list.
//
// Shell + Source Control intentionally left out of the visible bar — both
// tools are still reachable via plugin tabs / programmatic activeTab if a
// future feature needs them, but they were noisy in the day-to-day flow.
const TABS: Tab[] = [
  { id: 'home',      labelKey: 'tabs.home',      icon: Home },
  { id: 'chat',      labelKey: 'tabs.chat',      icon: MessageSquare },
  { id: 'always-on', labelKey: 'tabs.alwaysOn',  icon: Radio },
  { id: 'files',     labelKey: 'tabs.files',     icon: Folder },
  { id: 'dashboard', labelKey: 'tabs.dashboard', icon: BarChart3 },
  { id: 'tasks',     labelKey: 'tabs.tasks',     icon: ListChecks },
  { id: 'memory',    labelKey: 'tabs.memory',    icon: Database },
];

// V2 main shell: breadcrumb header + horizontal tab bar above the active
// tool's content. The tab bar replaces the in-sidebar Tools section so the
// sidebar can stay focused on projects+sessions.
type MainAreaV2Props = MainContentProps & {
  selectedProject: Project | null;
  selectedSession: ProjectSession | null;
  activeTab: AppTab;
};

export default function MainAreaV2(props: MainAreaV2Props) {
  const { t } = useTranslation();
  const {
    selectedProject,
    selectedSession,
    activeTab,
    setActiveTab,
    onStartNewSession,
  } = props;

  const { tasksEnabled, isTaskMasterInstalled } = useTasksSettings() as {
    tasksEnabled: boolean;
    isTaskMasterInstalled: boolean | null;
  };
  const shouldShowTasksTab = Boolean(tasksEnabled && isTaskMasterInstalled);
  const visibleTabs = TABS.filter((tab) => tab.id !== 'tasks' || shouldShowTasksTab);

  // Re-render breadcrumb when the user renames a project/session via the
  // sidebar overlay (subscribes to localStorage + custom event).
  useCustomNamesVersion();

  // Breadcrumb: "ProjectName / Tab" with optional session summary appended in
  // mono. Falls back to "Home" when no project is selected so the breadcrumb
  // never collapses to "/". Project + session strings flow through the
  // customNames overlay so user renames in the sidebar reflect here too.
  const tabLabelKey = TABS.find((tab) => tab.id === activeTab)?.labelKey;
  const tabLabel = tabLabelKey
    ? t(tabLabelKey)
    : activeTab.startsWith('plugin:')
      ? activeTab.replace('plugin:', '')
      : activeTab;
  const sessionSummary = selectedSession ? sessionDisplayTitle(selectedSession) : '';

  return (
    <div className="flex h-full min-w-0 flex-col bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
      {/* Breadcrumb header */}
      <header className="flex h-12 shrink-0 items-center border-b border-neutral-200 px-6 dark:border-neutral-800">
        <div className="flex min-w-0 items-center gap-2 text-[13px]">
          <span className="text-neutral-500 dark:text-neutral-400">
            {selectedProject ? projectDisplayName(selectedProject) : t('home', { defaultValue: 'Home' })}
          </span>
          <span className="text-neutral-400/60 dark:text-neutral-500/60">/</span>
          <span className="font-medium">{tabLabel}</span>
          {sessionSummary ? (
            <span className="ml-2 truncate font-mono text-[11px] text-neutral-500 dark:text-neutral-400">
              {sessionSummary}
            </span>
          ) : null}
        </div>
      </header>

      {/* Horizontal tabs (shadcn-ish underline). Scrolls horizontally on
          narrow viewports so the labels never wrap into two rows. */}
      <div
        role="tablist"
        aria-label="Tools"
        className="scrollbar-thin flex h-10 shrink-0 items-stretch gap-0.5 overflow-x-auto border-b border-neutral-200 px-3 dark:border-neutral-800"
      >
        {visibleTabs.map((tab) => {
          const Icon = tab.icon;
          const isActive = activeTab === tab.id;
          return (
            <div key={tab.id} className="relative flex shrink-0 items-stretch">
              <button
                type="button"
                role="tab"
                aria-selected={isActive}
                onClick={() => setActiveTab(tab.id)}
                className={cn(
                  'inline-flex items-center gap-1.5 px-3 text-[13px] transition-colors',
                  // Underline indicator: bottom border colored when active.
                  isActive
                    ? 'border-b-2 border-neutral-900 font-medium text-neutral-900 dark:border-neutral-100 dark:text-neutral-100'
                    : 'border-b-2 border-transparent text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100',
                )}
              >
                <Icon className="h-3.5 w-3.5" strokeWidth={1.75} />
                <span>{t(tab.labelKey)}</span>
              </button>
              {/* +session companion next to the Chat tab. Only enabled when a
                  project is selected — without one we'd have nothing to attach
                  the new session to. */}
              {tab.id === 'chat' ? (
                <button
                  type="button"
                  onClick={() => {
                    if (!selectedProject) return;
                    onStartNewSession(selectedProject);
                    setActiveTab('chat');
                  }}
                  disabled={!selectedProject}
                  aria-label={t('newSessionInProject', { defaultValue: 'New session' }) as string}
                  title={t('newSessionInProject', { defaultValue: 'New session' }) as string}
                  className={cn(
                    'mr-1 inline-flex h-6 w-6 self-center items-center justify-center rounded-md',
                    'text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900',
                    'dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100',
                    'disabled:opacity-40 disabled:hover:bg-transparent',
                  )}
                >
                  <Plus className="h-3.5 w-3.5" strokeWidth={2} />
                </button>
              ) : null}
            </div>
          );
        })}
      </div>

      {/* Body */}
      <div className="min-h-0 flex-1 overflow-hidden">
        <MainContent {...props} />
      </div>
    </div>
  );
}
