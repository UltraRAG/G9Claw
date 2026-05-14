import { AlertTriangle, Folder, RefreshCw } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import type { MainContentStateViewProps } from '../../types/types';

export default function MainContentStateView({ mode, message, onRetry }: MainContentStateViewProps) {
  const { t } = useTranslation();

  const isLoading = mode === 'loading';
  const isError = mode === 'error';

  return (
    <div className="flex h-full flex-col bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
      {isLoading ? (
        <div className="flex flex-1 items-center justify-center">
          <div className="flex items-center gap-2 text-[13px] text-neutral-500 dark:text-neutral-400">
            <div className="h-3.5 w-3.5 animate-spin rounded-full border-b-2 border-neutral-400" />
            <span>{t('mainContent.loading', { defaultValue: 'Loading…' })}</span>
          </div>
        </div>
      ) : isError ? (
        <div className="flex flex-1 items-center justify-center">
          <div className="mx-auto max-w-[460px] px-6 text-center">
            <div className="mx-auto mb-4 flex h-10 w-10 items-center justify-center rounded-full bg-amber-50 dark:bg-amber-950/30">
              <AlertTriangle className="h-4.5 w-4.5 text-amber-600 dark:text-amber-400" strokeWidth={1.75} />
            </div>
            <h2 className="mb-1 text-[15px] font-medium text-neutral-900 dark:text-neutral-100">
              {t('mainContent.loadFailed', { defaultValue: 'Could not load projects' })}
            </h2>
            <p className="text-[13px] leading-relaxed text-neutral-500 dark:text-neutral-400">
              {message || t('mainContent.loadFailedDescription', {
                defaultValue: 'The project index did not respond. Retry after the server finishes indexing.',
              })}
            </p>
            {onRetry ? (
              <button
                type="button"
                onClick={onRetry}
                className="mt-4 inline-flex h-8 items-center gap-1.5 rounded-md border border-neutral-200 px-3 text-[13px] font-medium text-neutral-700 transition hover:bg-neutral-50 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
              >
                <RefreshCw className="h-3.5 w-3.5" strokeWidth={1.75} />
                {t('mainContent.retry', { defaultValue: 'Retry' })}
              </button>
            ) : null}
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
