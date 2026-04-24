import { Folder } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import type { MainContentStateViewProps } from '../../types/types';
import MobileMenuButton from './MobileMenuButton';

export default function MainContentStateView({
  mode,
  isMobile,
  onMenuClick,
  chromeless = false,
}: MainContentStateViewProps) {
  const { t } = useTranslation();

  const isLoading = mode === 'loading';

  if (chromeless) {
    return (
      <div className="flex h-full flex-col bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
        {isLoading ? (
          <div className="flex flex-1 items-center justify-center">
            <div className="flex items-center gap-2 text-[13px] text-neutral-500 dark:text-neutral-400">
              <div className="h-3.5 w-3.5 animate-spin rounded-full border-b-2 border-neutral-400" />
              <span>{t('mainContent.loading', { defaultValue: 'Loading…' })}</span>
            </div>
          </div>
        ) : (
          <div className="flex flex-1 items-center justify-center">
            <div className="mx-auto max-w-[440px] px-6 text-center">
              <div className="mx-auto mb-4 flex h-10 w-10 items-center justify-center rounded-full bg-neutral-100 dark:bg-neutral-900">
                <Folder className="h-4.5 w-4.5 text-neutral-500" strokeWidth={1.75} />
              </div>
              <h2 className="mb-1 text-[15px] font-medium text-neutral-900 dark:text-neutral-100">
                {t('mainContent.chooseProject', { defaultValue: 'Pick a project to start' })}
              </h2>
              <p className="text-[13px] leading-relaxed text-neutral-500 dark:text-neutral-400">
                {t('mainContent.selectProjectDescription', {
                  defaultValue: 'Choose a project from the sidebar, or open a new one.',
                })}
              </p>
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col">
      {isMobile && (
        <div className="pwa-header-safe flex-shrink-0 border-b border-border/50 bg-background/80 p-2 backdrop-blur-sm sm:p-3">
          <MobileMenuButton onMenuClick={onMenuClick} compact />
        </div>
      )}

      {isLoading ? (
        <div className="flex flex-1 items-center justify-center">
          <div className="text-center text-muted-foreground">
            <div className="mx-auto mb-4 h-10 w-10">
              <div
                className="h-full w-full rounded-full border-[3px] border-muted border-t-primary"
                style={{
                  animation: 'spin 1s linear infinite',
                  WebkitAnimation: 'spin 1s linear infinite',
                  MozAnimation: 'spin 1s linear infinite',
                }}
              />
            </div>
            <h2 className="mb-1 text-lg font-semibold text-foreground">{t('mainContent.loading')}</h2>
            <p className="text-sm">{t('mainContent.settingUpWorkspace')}</p>
          </div>
        </div>
      ) : (
        <div className="flex flex-1 items-center justify-center">
          <div className="mx-auto max-w-md px-6 text-center">
            <div className="mx-auto mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-muted/50">
              <Folder className="h-7 w-7 text-muted-foreground" />
            </div>
            <h2 className="mb-2 text-xl font-semibold text-foreground">{t('mainContent.chooseProject')}</h2>
            <p className="mb-5 text-sm leading-relaxed text-muted-foreground">{t('mainContent.selectProjectDescription')}</p>
            <div className="rounded-xl border border-primary/10 bg-primary/5 p-3.5">
              <p className="text-sm text-primary">
                <strong>{t('mainContent.tip')}:</strong> {isMobile ? t('mainContent.createProjectMobile') : t('mainContent.createProjectDesktop')}
              </p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
