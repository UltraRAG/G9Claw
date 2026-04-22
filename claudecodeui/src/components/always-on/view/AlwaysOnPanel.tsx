import { AlertCircle, ArrowLeft, Play, Radio, RefreshCw, Repeat2, Sparkles, Trash2 } from 'lucide-react';
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Badge, Button, ScrollArea } from '../../../shared/view/ui';
import type {
  CronJobOverview,
  Project,
  ProjectCronJobsResponse,
  RunProjectCronJobNowResponse
} from '../../../types/app';
import { api } from '../../../utils/api';

const POLL_INTERVAL_MS = 15000;

type AlwaysOnPanelProps = {
  selectedProject: Project;
  onStartDiscoverySession: () => void | Promise<void>;
};

type TranslateFn = (key: string, options?: Record<string, string>) => string;

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

async function readJsonPayload(response: Response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

export function getPayloadError(payload: unknown): string | null {
  if (
    payload &&
    typeof payload === 'object' &&
    'error' in payload &&
    typeof payload.error === 'string' &&
    payload.error.trim().length > 0
  ) {
    return payload.error;
  }
  return null;
}

export function getStatusBadgeVariant(
  status: CronJobOverview['status']
): 'default' | 'secondary' | 'destructive' | 'outline' {
  if (status === 'running') {
    return 'default';
  }
  if (status === 'completed') {
    return 'secondary';
  }
  if (status === 'failed') {
    return 'destructive';
  }
  return 'outline';
}

export function getCronJobScopeLabel(job: Pick<CronJobOverview, 'durable'>, t: TranslateFn): string {
  return job.durable === false
    ? t('alwaysOn.flags.sessionScoped')
    : t('alwaysOn.flags.durable');
}

export function getCronJobTypeLabel(job: Pick<CronJobOverview, 'recurring'>, t: TranslateFn): string {
  return job.recurring
    ? t('alwaysOn.flags.recurring')
    : t('alwaysOn.flags.oneShot');
}

export function getCronJobExecutionModeLabel(
  job: Pick<CronJobOverview, 'manualOnly'>,
  t: TranslateFn,
): string | null {
  return job.manualOnly ? t('alwaysOn.flags.manualOnly') : null;
}

export function getCronJobKindLabel(
  job: Pick<CronJobOverview, 'durable' | 'recurring'>,
  t: TranslateFn
): string {
  return `${getCronJobScopeLabel(job, t)} / ${getCronJobTypeLabel(job, t)}`;
}

export function sortCronJobsByCreatedAt(jobs: CronJobOverview[]): CronJobOverview[] {
  return [...jobs].sort((left, right) => right.createdAt - left.createdAt);
}

export function findSelectedCronJob(
  jobs: CronJobOverview[],
  selectedTaskId: string | null
): CronJobOverview | null {
  if (!selectedTaskId) {
    return null;
  }
  return jobs.find((job) => job.id === selectedTaskId) ?? null;
}

export function buildRunNowFeedback(
  jobId: string,
  result: RunProjectCronJobNowResponse | null,
  t: TranslateFn
): {
  tone: 'success' | 'info';
  message: string;
} {
  if (result?.reason === 'already_running' || result?.started === false) {
    return {
      tone: 'info',
      message: t('alwaysOn.feedback.alreadyRunning', { id: jobId })
    };
  }

  return {
    tone: 'success',
    message: t('alwaysOn.feedback.runNowStarted', { id: jobId })
  };
}

function getFeedbackClasses(tone: 'success' | 'info' | 'error'): string {
  switch (tone) {
    case 'success':
      return 'rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-700 dark:border-emerald-800/60 dark:bg-emerald-900/20 dark:text-emerald-200';
    case 'info':
      return 'rounded-xl border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-700 dark:border-blue-800/60 dark:bg-blue-900/20 dark:text-blue-200';
    case 'error':
      return 'rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-800/60 dark:bg-red-900/20 dark:text-red-200';
  }
}

function DetailField({
  label,
  children
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    <div className="space-y-1">
      <dt className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className="text-sm text-foreground">{children}</dd>
    </div>
  );
}

export default function AlwaysOnPanel({
  selectedProject,
  onStartDiscoverySession,
}: AlwaysOnPanelProps) {
  const { t } = useTranslation();
  const [jobs, setJobs] = useState<CronJobOverview[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isStartingDiscovery, setIsStartingDiscovery] = useState(false);
  const [loadError, setLoadError] = useState('');
  const [feedback, setFeedback] = useState<{
    tone: 'success' | 'info' | 'error';
    message: string;
  } | null>(null);
  const [lastUpdatedAt, setLastUpdatedAt] = useState<string>('');
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isRunningNow, setIsRunningNow] = useState(false);
  const isMountedRef = useRef(true);
  const requestInFlightRef = useRef(false);

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    setSelectedTaskId(null);
    setFeedback(null);
  }, [selectedProject.name]);

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
      setLoadError('');
      setLastUpdatedAt(new Date().toISOString());
    } catch (loadError) {
      if (!isMountedRef.current) {
        return;
      }
      setLoadError(getRefreshErrorMessage(loadError, t('alwaysOn.errors.loadFailed')));
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

  const sortedJobs = useMemo(() => sortCronJobsByCreatedAt(jobs), [jobs]);
  const selectedJob = useMemo(
    () => findSelectedCronJob(jobs, selectedTaskId),
    [jobs, selectedTaskId]
  );

  const notAvailableLabel = t('alwaysOn.values.notAvailable');
  const selectedJobStatusLabel = selectedJob ? t(`alwaysOn.status.${selectedJob.status}`) : '';

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

  const handleSelectTask = useCallback((taskId: string) => {
    setSelectedTaskId(taskId);
    setFeedback(null);
  }, []);

  const handleBackToOverview = useCallback(() => {
    setSelectedTaskId(null);
  }, []);

  const handleDeleteTask = useCallback(async () => {
    if (!selectedJob) {
      return;
    }
    if (
      typeof window !== 'undefined' &&
      !window.confirm(t('alwaysOn.confirmations.delete', { id: selectedJob.id }))
    ) {
      return;
    }

    setIsDeleting(true);
    setFeedback(null);
    try {
      const response = await api.deleteProjectCronJob(selectedProject.name, selectedJob.id);
      const payload = await readJsonPayload(response);
      if (!response.ok) {
        throw new Error(
          getPayloadError(payload) ?? t('alwaysOn.errors.deleteFailed')
        );
      }

      setSelectedTaskId(null);
      setFeedback({
        tone: 'success',
        message: t('alwaysOn.feedback.deleted', { id: selectedJob.id })
      });
      await loadJobs('refresh');
    } catch (deleteError) {
      setFeedback({
        tone: 'error',
        message: getRefreshErrorMessage(deleteError, t('alwaysOn.errors.deleteFailed'))
      });
    } finally {
      if (isMountedRef.current) {
        setIsDeleting(false);
      }
    }
  }, [loadJobs, selectedJob, selectedProject.name, t]);

  const handleRunNow = useCallback(async () => {
    if (!selectedJob) {
      return;
    }

    setIsRunningNow(true);
    setFeedback(null);
    try {
      const response = await api.runProjectCronJobNow(selectedProject.name, selectedJob.id);
      const payload = await readJsonPayload(response);
      if (!response.ok) {
        throw new Error(
          getPayloadError(payload) ?? t('alwaysOn.errors.runNowFailed')
        );
      }
      const body = payload as RunProjectCronJobNowResponse | null;

      setFeedback(buildRunNowFeedback(selectedJob.id, body, t));

      await loadJobs('refresh');
    } catch (runNowError) {
      setFeedback({
        tone: 'error',
        message: getRefreshErrorMessage(runNowError, t('alwaysOn.errors.runNowFailed'))
      });
    } finally {
      if (isMountedRef.current) {
        setIsRunningNow(false);
      }
    }
  }, [loadJobs, selectedJob, selectedProject.name, t]);

  const handleStartDiscovery = useCallback(async () => {
    if (isStartingDiscovery) {
      return;
    }

    setIsStartingDiscovery(true);
    try {
      await onStartDiscoverySession();
    } finally {
      if (isMountedRef.current) {
        setIsStartingDiscovery(false);
      }
    }
  }, [isStartingDiscovery, onStartDiscoverySession]);

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

          <div className="flex flex-wrap items-center gap-2 self-start">
            <Button
              type="button"
              variant="default"
              size="sm"
              onClick={() => void handleStartDiscovery()}
              disabled={isStartingDiscovery}
            >
              <Sparkles className={isStartingDiscovery ? 'animate-pulse' : ''} />
              {t('alwaysOn.actions.discoverTasks')}
            </Button>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => void loadJobs('refresh')}
              disabled={isLoading || isRefreshing}
            >
              <RefreshCw className={isRefreshing ? 'animate-spin' : ''} />
              {t('buttons.refresh')}
            </Button>
          </div>
        </div>
      </div>

      <ScrollArea className="flex-1">
        <div className="space-y-6 p-4 sm:p-6">
          {!selectedTaskId && (
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
          )}

          {loadError && (
            <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-800/60 dark:bg-red-900/20 dark:text-red-200">
              {loadError}
            </div>
          )}

          {feedback && (
            <div className={getFeedbackClasses(feedback.tone)}>
              {feedback.message}
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
          ) : selectedTaskId ? (
            selectedJob ? (
              <div className="space-y-4">
                <div className="rounded-xl border border-border bg-card/50 p-4 shadow-sm">
                  <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                    <div className="space-y-3">
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        className="-ml-2 w-fit"
                        onClick={handleBackToOverview}
                      >
                        <ArrowLeft className="h-4 w-4" />
                        {t('navigation.back')}
                      </Button>
                      <div className="space-y-1">
                        <h3 className="text-lg font-semibold text-foreground">{t('alwaysOn.detail.title')}</h3>
                        <p className="break-all text-sm text-muted-foreground">{selectedJob.id}</p>
                      </div>
                      {!selectedJob.recurring && (
                        <p className="max-w-2xl text-xs text-muted-foreground">
                          {t('alwaysOn.detail.oneShotRunNowHint')}
                        </p>
                      )}
                    </div>

                    <div className="flex flex-wrap gap-2">
                      <Button
                        type="button"
                        variant="outline"
                        onClick={() => void handleRunNow()}
                        disabled={isRunningNow || isDeleting}
                      >
                        <Play className={isRunningNow ? 'animate-pulse' : ''} />
                        {t('alwaysOn.actions.runNow')}
                      </Button>
                      <Button
                        type="button"
                        variant="destructive"
                        onClick={() => void handleDeleteTask()}
                        disabled={isDeleting || isRunningNow}
                      >
                        <Trash2 className={isDeleting ? 'animate-pulse' : ''} />
                        {t('buttons.delete')}
                      </Button>
                    </div>
                  </div>
                </div>

                <div className="grid gap-4 xl:grid-cols-2">
                  <div className="rounded-xl border border-border bg-card/50 p-4 shadow-sm">
                    <div className="mb-4 flex items-center justify-between gap-3">
                      <h4 className="text-sm font-semibold text-foreground">{t('alwaysOn.detail.sections.definition')}</h4>
                      <Badge variant={getStatusBadgeVariant(selectedJob.status)}>
                        {selectedJobStatusLabel}
                      </Badge>
                    </div>

                    <dl className="space-y-4">
                      <DetailField label={t('alwaysOn.fields.prompt')}>
                        <div className="whitespace-pre-wrap break-words">{getDisplayText(selectedJob.prompt, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.cron')}>
                        <code className="block rounded-md bg-muted px-2.5 py-1.5 text-xs text-foreground">
                          {selectedJob.cron}
                        </code>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.scope')}>
                        <Badge variant="outline" className="text-xs">
                          {getCronJobScopeLabel(selectedJob, t)}
                        </Badge>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.type')}>
                        <div className="flex flex-wrap gap-2">
                          <Badge variant="outline" className="text-xs">
                            {getCronJobTypeLabel(selectedJob, t)}
                          </Badge>
                          {getCronJobExecutionModeLabel(selectedJob, t) && (
                            <Badge variant="secondary" className="text-xs">
                              {getCronJobExecutionModeLabel(selectedJob, t)}
                            </Badge>
                          )}
                          {selectedJob.permanent && (
                            <Badge variant="secondary" className="text-xs">
                              {t('alwaysOn.flags.permanent')}
                            </Badge>
                          )}
                        </div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.createdAt')}>
                        {formatDateTime(selectedJob.createdAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.lastFiredAt')}>
                        {formatDateTime(selectedJob.lastFiredAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.originSessionId')}>
                        <div className="break-all">{getDisplayText(selectedJob.originSessionId, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.transcriptKey')}>
                        <div className="break-all">{getDisplayText(selectedJob.transcriptKey, notAvailableLabel)}</div>
                      </DetailField>
                    </dl>
                  </div>

                  <div className="rounded-xl border border-border bg-card/50 p-4 shadow-sm">
                    <div className="mb-4 flex items-center justify-between gap-3">
                      <h4 className="text-sm font-semibold text-foreground">{t('alwaysOn.detail.sections.latestRun')}</h4>
                      <Badge variant={getStatusBadgeVariant(selectedJob.status)}>
                        {selectedJobStatusLabel}
                      </Badge>
                    </div>

                    {selectedJob.latestRun ? (
                      <dl className="space-y-4">
                        <DetailField label={t('alwaysOn.fields.lastActivity')}>
                          {formatDateTime(selectedJob.latestRun.lastActivity, notAvailableLabel)}
                        </DetailField>
                        <DetailField label={t('alwaysOn.fields.latestRunSummary')}>
                          <div className="whitespace-pre-wrap break-words">
                            {getDisplayText(selectedJob.latestRun.summary, notAvailableLabel)}
                          </div>
                        </DetailField>
                        <DetailField label={t('alwaysOn.fields.latestRunTaskId')}>
                          <div className="break-all">{getDisplayText(selectedJob.latestRun.taskId, notAvailableLabel)}</div>
                        </DetailField>
                        <DetailField label={t('alwaysOn.fields.latestRunTranscript')}>
                          <div className="break-all">
                            {getDisplayText(selectedJob.latestRun.relativeTranscriptPath, notAvailableLabel)}
                          </div>
                        </DetailField>
                        <DetailField label={t('alwaysOn.fields.outputFile')}>
                          <div className="break-all">{getDisplayText(selectedJob.latestRun.outputFile, notAvailableLabel)}</div>
                        </DetailField>
                      </dl>
                    ) : (
                      <div className="rounded-lg border border-dashed border-border bg-muted/20 px-4 py-6 text-sm text-muted-foreground">
                        {t('alwaysOn.detail.noLatestRun')}
                      </div>
                    )}
                  </div>
                </div>
              </div>
            ) : (
              <div className="rounded-xl border border-dashed border-border bg-card/30 px-6 py-12 text-center">
                <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-muted/50">
                  <AlertCircle className="h-6 w-6 text-muted-foreground" />
                </div>
                <h3 className="text-base font-medium text-foreground">{t('alwaysOn.detail.missingTitle')}</h3>
                <p className="mt-2 text-sm text-muted-foreground">{t('alwaysOn.detail.missingDescription')}</p>
                <div className="mt-4">
                  <Button type="button" variant="outline" onClick={handleBackToOverview}>
                    <ArrowLeft className="h-4 w-4" />
                    {t('navigation.back')}
                  </Button>
                </div>
              </div>
            )
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border bg-card/50 shadow-sm">
              <table className="w-full min-w-[1160px] border-collapse text-sm">
                <thead className="bg-muted/30">
                  <tr className="border-b border-border/60">
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.kind')}
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {t('alwaysOn.fields.status')}
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
                        <div className="space-y-2">
                          <div className="font-medium text-foreground">{getCronJobKindLabel(job, t)}</div>
                          {(job.permanent || job.manualOnly) && (
                            <div className="flex flex-wrap gap-2">
                              {getCronJobExecutionModeLabel(job, t) && (
                                <Badge variant="secondary" className="text-xs">
                                  {getCronJobExecutionModeLabel(job, t)}
                                </Badge>
                              )}
                              {job.permanent && (
                                <Badge variant="secondary" className="text-xs">
                                  {t('alwaysOn.flags.permanent')}
                                </Badge>
                              )}
                            </div>
                          )}
                        </div>
                      </td>
                      <td className="px-4 py-4">
                        <Badge variant={getStatusBadgeVariant(job.status)} className="text-xs">
                          {t(`alwaysOn.status.${job.status}`)}
                        </Badge>
                      </td>
                      <td className="px-4 py-4">
                        <button
                          type="button"
                          className="min-w-0 space-y-2 text-left transition-opacity hover:opacity-90"
                          onClick={() => handleSelectTask(job.id)}
                          aria-label={t('alwaysOn.actions.viewDetails', { id: job.id })}
                        >
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
                          <div className="text-xs font-medium text-primary">
                            {t('alwaysOn.actions.viewDetails', { id: job.id })}
                          </div>
                        </button>
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
