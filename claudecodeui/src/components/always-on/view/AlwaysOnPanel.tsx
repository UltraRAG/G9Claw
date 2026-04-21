import { AlertCircle, Radio, RefreshCw, Repeat2 } from 'lucide-react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Badge, Button, ScrollArea } from '../../../shared/view/ui';
import type {
  CronJobOverview,
  Project,
  ProjectCronJobsResponse
} from '../../../types/app';
import { api } from '../../../utils/api';

const POLL_INTERVAL_MS = 15000;

type AlwaysOnPanelProps = {
  selectedProject: Project;
};

function formatDateTime(value?: string | number, fallback = '-'): string {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return fallback;
  }

  return date.toLocaleString();
}

function getRefreshErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message;
  }

  return fallback;
}

function getDisplayText(value: string | undefined, fallback: string): string {
  if (typeof value !== 'string') {
    return fallback;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : fallback;
}

export default function AlwaysOnPanel({ selectedProject }: AlwaysOnPanelProps) {
  const { t } = useTranslation();
  const [jobs, setJobs] = useState<CronJobOverview[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [error, setError] = useState('');
  const [lastUpdatedAt, setLastUpdatedAt] = useState<string>('');
  const isMountedRef = useRef(true);
  const requestInFlightRef = useRef(false);

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
    };
  }, []);

  const loadJobs = useCallback(async (mode: 'initial' | 'refresh' | 'poll' = 'initial') => {
    if (requestInFlightRef.current) {
      return;
    }

    requestInFlightRef.current = true;
    if (mode === 'initial') {
      setIsLoading(true);
    } else {
      setIsRefreshing(true);
    }

    try {
      const response = await api.projectCronJobs(selectedProject.name);
      let payload = null;
      try {
        payload = await response.json();
      } catch {
        payload = null;
      }

      if (!response.ok) {
        throw new Error(
          typeof payload?.error === 'string' && payload.error.trim().length > 0
            ? payload.error
            : t('alwaysOn.errors.loadFailed')
        );
      }

      const body = payload as ProjectCronJobsResponse | null;
      if (!isMountedRef.current) {
        return;
      }

      setJobs(Array.isArray(body?.jobs) ? body.jobs : []);
      setError('');
      setLastUpdatedAt(new Date().toISOString());
    } catch (loadError) {
      if (!isMountedRef.current) {
        return;
      }
      setError(getRefreshErrorMessage(loadError, t('alwaysOn.errors.loadFailed')));
    } finally {
      requestInFlightRef.current = false;
      if (isMountedRef.current) {
        setIsLoading(false);
        setIsRefreshing(false);
      }
    }
  }, [selectedProject.name, t]);

  useEffect(() => {
    void loadJobs('initial');

    const intervalId = window.setInterval(() => {
      void loadJobs('poll');
    }, POLL_INTERVAL_MS);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadJobs]);

  const summary = useMemo(() => {
    return jobs.reduce((accumulator, job) => {
      accumulator.total += 1;
      if (job.recurring) {
        accumulator.recurring += 1;
      }
      if (job.status === 'failed') {
        accumulator.failed += 1;
      }
      return accumulator;
    }, {
      total: 0,
      recurring: 0,
      failed: 0
    });
  }, [jobs]);

  const sortedJobs = useMemo(
    () => [...jobs].sort((left: CronJobOverview, right: CronJobOverview) => right.createdAt - left.createdAt),
    [jobs]
  );

  const notAvailableLabel = t('alwaysOn.values.notAvailable');

  const summaryCards = [
    {
      key: 'total',
      label: t('alwaysOn.summary.total'),
      value: summary.total,
      icon: <Radio className="h-4 w-4 text-primary" />
    },
    {
      key: 'recurring',
      label: t('alwaysOn.summary.recurring'),
      value: summary.recurring,
      icon: <Repeat2 className="h-4 w-4 text-primary" />
    },
    {
      key: 'failed',
      label: t('alwaysOn.summary.failed'),
      value: summary.failed,
      icon: <AlertCircle className="h-4 w-4 text-red-500" />
    }
  ];

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <div className="border-b border-border/60 px-4 py-4 sm:px-6">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="space-y-1">
            <h2 className="text-base font-semibold text-foreground">{t('alwaysOn.title')}</h2>
            <p className="text-sm text-muted-foreground">
              {t('alwaysOn.description')}
            </p>
            <p className="text-xs text-muted-foreground">
              {t('alwaysOn.lastUpdated', { timestamp: lastUpdatedAt ? formatDateTime(lastUpdatedAt) : t('alwaysOn.values.notUpdated') })}
            </p>
          </div>

          <Button
            type="button"
            variant="outline"
            size="sm"
            className="self-start"
            onClick={() => void loadJobs('refresh')}
            disabled={isLoading || isRefreshing}
          >
            <RefreshCw className={isRefreshing ? 'animate-spin' : ''} />
            {t('buttons.refresh')}
          </Button>
        </div>
      </div>

      <ScrollArea className="flex-1">
        <div className="space-y-6 p-4 sm:p-6">
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {summaryCards.map((card) => (
              <div
                key={card.key}
                className="rounded-xl border border-border bg-card/50 p-4 shadow-sm"
              >
                <div className="mb-3 flex items-center justify-between">
                  <span className="text-sm text-muted-foreground">{card.label}</span>
                  {card.icon}
                </div>
                <div className="text-2xl font-semibold text-foreground">{card.value}</div>
              </div>
            ))}
          </div>

          {error && (
            <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-800/60 dark:bg-red-900/20 dark:text-red-200">
              {error}
            </div>
          )}

          {isLoading ? (
            <div className="rounded-xl border border-border bg-card/40 p-10 text-center">
              <div className="mx-auto mb-4 h-10 w-10">
                <div className="h-full w-full animate-spin rounded-full border-[3px] border-muted border-t-primary" />
              </div>
              <h3 className="text-base font-medium text-foreground">{t('alwaysOn.loadingTitle')}</h3>
              <p className="mt-1 text-sm text-muted-foreground">{t('alwaysOn.loadingDescription')}</p>
            </div>
          ) : jobs.length === 0 ? (
            <div className="rounded-xl border border-dashed border-border bg-card/30 px-6 py-12 text-center">
              <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-muted/50">
                <Radio className="h-6 w-6 text-muted-foreground" />
              </div>
              <h3 className="text-base font-medium text-foreground">{t('alwaysOn.emptyTitle')}</h3>
              <p className="mt-2 text-sm text-muted-foreground">{t('alwaysOn.emptyDescription')}</p>
            </div>
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border bg-card/50 shadow-sm">
              <table className="w-full min-w-[1160px] border-collapse text-sm">
                <thead className="bg-muted/30">
                  <tr className="border-b border-border/60">
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.scope')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.type')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.jobId')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.createdAt')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.lastFiredAt')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.lastActivity')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.originSessionId')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.transcriptKey')}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {sortedJobs.map((job) => (
                    <tr key={job.id} className="border-b border-border/60 align-top last:border-b-0">
                      <td className="px-4 py-4">
                        <Badge variant="outline" className="text-xs">
                          {job.durable === false
                            ? t('alwaysOn.flags.sessionScoped')
                            : t('alwaysOn.flags.durable')}
                        </Badge>
                      </td>
                      <td className="px-4 py-4">
                        <div className="flex flex-wrap gap-2">
                          <Badge variant="outline" className="text-xs">
                            {job.recurring
                              ? t('alwaysOn.flags.recurring')
                              : t('alwaysOn.flags.oneShot')}
                          </Badge>
                          {job.permanent && (
                            <Badge variant="secondary" className="text-xs">
                              {t('alwaysOn.flags.permanent')}
                            </Badge>
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-4">
                        <div className="min-w-0 space-y-2">
                          <div className="break-all font-medium text-foreground">{job.id}</div>
                          <p
                            className="max-w-md truncate text-xs text-muted-foreground"
                            title={job.prompt}
                          >
                            {getDisplayText(job.prompt, notAvailableLabel)}
                          </p>
                          <code
                            className="block max-w-full break-all rounded-md bg-muted px-2.5 py-1.5 text-xs text-foreground"
                            title={job.cron}
                          >
                            {job.cron}
                          </code>
                        </div>
                      </td>
                      <td className="whitespace-nowrap px-4 py-4 text-foreground">
                        {formatDateTime(job.createdAt, notAvailableLabel)}
                      </td>
                      <td className="whitespace-nowrap px-4 py-4 text-foreground">
                        {formatDateTime(job.lastFiredAt, notAvailableLabel)}
                      </td>
                      <td className="whitespace-nowrap px-4 py-4 text-foreground">
                        {formatDateTime(job.latestRun?.lastActivity, notAvailableLabel)}
                      </td>
                      <td className="px-4 py-4 text-foreground">
                        <div className="max-w-56 break-all">
                          {getDisplayText(job.originSessionId, notAvailableLabel)}
                        </div>
                      </td>
                      <td className="px-4 py-4 text-foreground">
                        <div className="max-w-72 break-all">
                          {getDisplayText(job.transcriptKey, notAvailableLabel)}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}
