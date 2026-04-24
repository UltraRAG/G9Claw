import { useTranslation } from 'react-i18next';
import { MoreHorizontal, Share2 } from 'lucide-react';
import type { AppTab, Project, ProjectSession } from '../../types/app';
import MainContent from '../main-content/view/MainContent';
import type { MainContentProps } from '../main-content/types/types';

const TAB_LABEL_KEY: Partial<Record<AppTab, string>> = {
  chat: 'tabs.chat',
  'always-on': 'tabs.alwaysOn',
  shell: 'tabs.shell',
  files: 'tabs.files',
  git: 'tabs.git',
  dashboard: 'tabs.dashboard',
  tasks: 'tabs.tasks',
  memory: 'tabs.memory',
};

// Wraps the legacy MainContent with a prototype-style breadcrumb header.
// MainContent renders chromeless so the pill bar / tab switcher stays off
// — the V2 Sidebar owns tab switching now.
type MainAreaV2Props = Omit<MainContentProps, 'chromeless'> & {
  selectedProject: Project | null;
  selectedSession: ProjectSession | null;
  activeTab: AppTab;
};

export default function MainAreaV2(props: MainAreaV2Props) {
  const { t } = useTranslation();
  const { selectedProject, selectedSession, activeTab } = props;

  const tabLabelKey = TAB_LABEL_KEY[activeTab];
  const tabLabel = tabLabelKey
    ? t(tabLabelKey)
    : activeTab.startsWith('plugin:')
      ? activeTab.replace('plugin:', '')
      : activeTab;

  const sessionSummary =
    (typeof selectedSession?.summary === 'string' && selectedSession.summary) ||
    (typeof selectedSession?.title === 'string' && selectedSession.title) ||
    '';

  return (
    <div className="flex h-full min-w-0 flex-col bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
      {/* Breadcrumb header */}
      <header className="flex h-12 shrink-0 items-center border-b border-neutral-200 px-6 dark:border-neutral-800">
        <div className="flex min-w-0 items-center gap-2 text-[13px]">
          <span className="text-neutral-500 dark:text-neutral-400">
            {selectedProject?.displayName || selectedProject?.name || t('home', { defaultValue: 'Home' })}
          </span>
          <span className="text-neutral-400/60 dark:text-neutral-500/60">/</span>
          <span className="font-medium">{tabLabel}</span>
          {sessionSummary ? (
            <span className="ml-2 truncate font-mono text-[11px] text-neutral-500 dark:text-neutral-400">
              {sessionSummary}
            </span>
          ) : null}
        </div>
        <div className="ml-auto flex items-center gap-1">
          <button
            type="button"
            disabled
            className="inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-[13px] text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 dark:text-neutral-400 dark:hover:bg-neutral-800"
            title={t('share', { defaultValue: 'Share (coming soon)' }) as string}
          >
            <Share2 className="h-4 w-4" strokeWidth={1.75} />
            <span>{t('share', { defaultValue: 'Share' })}</span>
          </button>
          <button
            type="button"
            className="inline-flex h-8 w-8 items-center justify-center rounded-lg text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
            aria-label={t('more', { defaultValue: 'More actions' }) as string}
          >
            <MoreHorizontal className="h-4 w-4" strokeWidth={1.75} />
          </button>
        </div>
      </header>

      {/* Body */}
      <div className="min-h-0 flex-1 overflow-hidden">
        <MainContent {...props} chromeless />
      </div>
    </div>
  );
}
