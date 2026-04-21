import { AlertCircle, CheckCircle2, CircleHelp, Radio, RefreshCw, Repeat2 } from 'lucide-react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Badge, Button, ScrollArea } from '../../../shared/view/ui';
import type {
  CronJobOverview,
  CronJobOverviewStatus,
  Project,
  ProjectCronJobsResponse
} from '../../../types/app';
import { api } from '../../../utils/api';

const POLL_INTERVAL_MS = 15000;

type AlwaysOnPanelProps = {
  selectedProject: Project;
};

function formatDateTime(value?: string | number): string {
  if (value === undefined || value === null || value === '') {
    return '-';
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return '-';
  }

  return date.toLocaleString();
}

function getStatusBadgeClassName(status: CronJobOverviewStatus): string {
  switch (status) {
    case 'completed':
      return 'border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-800/60 dark:bg-emerald-900/20 dark:text-emerald-200';
    case 'failed':
      return 'border-red-200 bg-red-50 text-red-700 dark:border-red-800/60 dark:bg-red-900/20 dark:text-red-200';
    case 'scheduled':
      return 'border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800/60 dark:bg-amber-900/20 dark:text-amber-200';
    default:
      return 'border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-700 dark:bg-slate-900/20 dark:text-slate-200';
  }
}

function getStatusLabel(status: CronJobOverviewStatus, t: (key: string) => string): string {
  switch (status) {
    case 'completed':
      return t('status.completed');
    case 'failed':
      return t('status.failed');
    case 'scheduled':
      return t('alwaysOn.statusLabels.scheduled');
    default:
      return t('alwaysOn.statusLabels.unknown');
  }
}

function getRefreshErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message;
  }

  return fallback;
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
      if (!isMountedRef.current) {
        return;
      }
      setIsLoading(false);
      setIsRefreshing(false);
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
      if (job.status === 'scheduled') {
        accumulator.scheduled += 1;
      }
      return accumulator;
    }, {
      total: 0,
      recurring: 0,
      failed: 0,
      scheduled: 0
    });
  }, [jobs]);

  const jobSections = useMemo(() => {
    const durableJobs: CronJobOverview[] = [];
    const sessionJobs: CronJobOverview[] = [];

    for (const job of jobs) {
      if (job.durable === false) {
        sessionJobs.push(job);
      } else {
        durableJobs.push(job);
      }
    }

    const sortJobsByCreatedAt = (left: CronJobOverview, right: CronJobOverview) =>
      right.createdAt - left.createdAt;

    durableJobs.sort(sortJobsByCreatedAt);
    sessionJobs.sort(sortJobsByCreatedAt);

    return [
      { key: 'durable', title: t('alwaysOn.sections.durable'), jobs: durableJobs },
      { key: 'session', title: t('alwaysOn.sections.sessionScoped'), jobs: sessionJobs }
    ].filter((section) => section.jobs.length > 0);
  }, [jobs, t]);

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
    },
    {
      key: 'scheduled',
      label: t('alwaysOn.summary.scheduled'),
      value: summary.scheduled,
      icon: <CircleHelp className="h-4 w-4 text-amber-500" />
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
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
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
            <div className="space-y-4">
              {jobSections.map((section) => (
                <section key={section.key} className="space-y-3">
                  <div className="flex items-center gap-2">
                    <h3 className="text-sm font-semibold text-foreground">{section.title}</h3>
                    <Badge variant="secondary" className="px-2 py-0 text-xs">
                      {section.jobs.length}
                    </Badge>
                  </div>

                  {section.jobs.map((job) => (
                    <div
                      key={job.id}
                      className="rounded-xl border border-border bg-card/50 p-4 shadow-sm"
                    >
                      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            <h3 className="text-sm font-semibold text-foreground">{job.id}</h3>
                            <Badge
                              variant="outline"
                              className={getStatusBadgeClassName(job.status)}
                            >
                              {getStatusLabel(job.status, t)}
                            </Badge>
                            <Badge variant="outline" className="text-xs">
                              {job.durable === false
                                ? t('alwaysOn.flags.sessionScoped')
                                : t('alwaysOn.flags.durable')}
                            </Badge>
                            <Badge variant="outline" className="text-xs">
                              {job.recurring
                                ? t('alwaysOn.flags.recurring')
                                : t('alwaysOn.flags.oneShot')}
                            </Badge>
                            {job.permanent && (
                              <Badge variant="outline" className="text-xs">
                                {t('alwaysOn.flags.permanent')}
                              </Badge>
                            )}
                          </div>

                          <p className="mt-3 break-words text-sm leading-6 text-muted-foreground">
                            {job.prompt}
                          </p>
                        </div>

                        <div className="shrink-0">
                          <code className="rounded-md bg-muted px-2.5 py-1.5 text-xs text-foreground">
                            {job.cron}
                          </code>
                        </div>
                      </div>

                      <div className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                        <div className="rounded-lg border border-border/70 bg-background/70 p-3">
                          <div className="text-xs uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.fields.createdAt')}
                          </div>
                          <div className="mt-1 text-sm text-foreground">{formatDateTime(job.createdAt)}</div>
                        </div>
                        <div className="rounded-lg border border-border/70 bg-background/70 p-3">
                          <div className="text-xs uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.fields.lastFiredAt')}
                          </div>
                          <div className="mt-1 text-sm text-foreground">{formatDateTime(job.lastFiredAt)}</div>
                        </div>
                        <div className="rounded-lg border border-border/70 bg-background/70 p-3">
                          <div className="text-xs uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.fields.originSessionId')}
                          </div>
                          <div className="mt-1 break-all text-sm text-foreground">
                            {job.originSessionId || t('alwaysOn.values.notAvailable')}
                          </div>
                        </div>
                        <div className="rounded-lg border border-border/70 bg-background/70 p-3">
                          <div className="text-xs uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.fields.transcriptKey')}
                          </div>
                          <div className="mt-1 break-all text-sm text-foreground">
                            {job.transcriptKey || t('alwaysOn.values.notAvailable')}
                          </div>
                        </div>
                      </div>

                      {job.latestRun && (
                        <div className="mt-4 rounded-lg border border-border/70 bg-background/70 p-3">
                          <div className="mb-2 flex items-center gap-2 text-sm font-medium text-foreground">
                            <CheckCircle2 className="h-4 w-4 text-primary" />
                            {t('alwaysOn.latestRunTitle')}
                          </div>
                          <div className="grid gap-3 md:grid-cols-2">
                            <div>
                              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                                {t('alwaysOn.fields.summary')}
                              </div>
                              <div className="mt-1 break-words text-sm text-foreground">
                                {job.latestRun.summary || t('alwaysOn.values.notAvailable')}
                              </div>
                            </div>
                            <div>
                              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                                {t('alwaysOn.fields.lastActivity')}
                              </div>
                              <div className="mt-1 text-sm text-foreground">
                                {formatDateTime(job.latestRun.lastActivity)}
                              </div>
                            </div>
                            <div>
                              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                                {t('alwaysOn.fields.taskId')}
                              </div>
                              <div className="mt-1 break-all text-sm text-foreground">
                                {job.latestRun.taskId || t('alwaysOn.values.notAvailable')}
                              </div>
                            </div>
                            <div>
                              <div className="text-xs uppercase tracking-wide text-muted-foreground">
                                {t('alwaysOn.fields.relativeTranscriptPath')}
                              </div>
                              <div className="mt-1 break-all text-sm text-foreground">
                                {job.latestRun.relativeTranscriptPath || t('alwaysOn.values.notAvailable')}
                              </div>
                            </div>
                          </div>
                        </div>
                      )}
                    </div>
                  ))}
                </section>
              ))}
            </div>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}
