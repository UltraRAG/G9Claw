import { AlertCircle, ArrowLeft, ExternalLink, FileText, Play, Radio, RefreshCw, Repeat2, Sparkles, Trash2 } from 'lucide-react';
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Badge, Button, ScrollArea } from '../../../shared/view/ui';
import type {
  CronJobOverview,
  DiscoveryPlanOverview,
  Project,
  ProjectCronJobsResponse,
  ProjectDiscoveryPlansResponse,
  RunProjectCronJobNowResponse
} from '../../../types/app';
import { api } from '../../../utils/api';
import { Markdown } from '../../chat/view/subcomponents/Markdown';

const POLL_INTERVAL_MS = 15000;

type AlwaysOnPanelProps = {
  selectedProject: Project;
  onStartDiscoverySession: () => void | Promise<void>;
  onExecuteDiscoveryPlan: (planId: string, source?: 'manual' | 'auto') => void | Promise<void>;
  onOpenDiscoverySession: (sessionId: string) => void;
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
  status: CronJobOverview['status'] | DiscoveryPlanOverview['status']
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

function getDiscoveryPlanApprovalModeLabel(
  approvalMode: DiscoveryPlanOverview['approvalMode'],
  t: TranslateFn,
): string {
  return approvalMode === 'auto'
    ? t('alwaysOn.discovery.modes.auto', { defaultValue: 'Auto' })
    : t('alwaysOn.discovery.modes.manual', { defaultValue: 'Manual approval' });
}

function sortDiscoveryPlansByUpdatedAt(plans: DiscoveryPlanOverview[]): DiscoveryPlanOverview[] {
  return [...plans].sort((left, right) => {
    const leftUpdatedAt = new Date(left.updatedAt).getTime();
    const rightUpdatedAt = new Date(right.updatedAt).getTime();
    return (Number.isNaN(rightUpdatedAt) ? 0 : rightUpdatedAt) - (Number.isNaN(leftUpdatedAt) ? 0 : leftUpdatedAt);
  });
}

function findSelectedDiscoveryPlan(
  plans: DiscoveryPlanOverview[],
  selectedPlanId: string | null,
): DiscoveryPlanOverview | null {
  if (!selectedPlanId) {
    return null;
  }
  return plans.find((plan) => plan.id === selectedPlanId) ?? null;
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
  onExecuteDiscoveryPlan,
  onOpenDiscoverySession,
}: AlwaysOnPanelProps) {
  const { t } = useTranslation();
  const [jobs, setJobs] = useState<CronJobOverview[]>([]);
  const [plans, setPlans] = useState<DiscoveryPlanOverview[]>([]);
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
  const [selectedPlanId, setSelectedPlanId] = useState<string | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isRunningNow, setIsRunningNow] = useState(false);
  const [isExecutingPlan, setIsExecutingPlan] = useState(false);
  const [isArchivingPlan, setIsArchivingPlan] = useState(false);
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
    setSelectedPlanId(null);
    setFeedback(null);
  }, [selectedProject.name]);

  const loadOverview = useCallback(async (mode: 'initial' | 'refresh' | 'poll' = 'initial') => {
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
      const [jobsResponse, plansResponse] = await Promise.all([
        api.projectCronJobs(selectedProject.name),
        api.projectDiscoveryPlans(selectedProject.name),
      ]);

      const jobsPayload = await readJsonPayload(jobsResponse);
      const plansPayload = await readJsonPayload(plansResponse);

      if (!jobsResponse.ok) {
        throw new Error(
          typeof jobsPayload?.error === 'string' && jobsPayload.error.trim().length > 0
            ? jobsPayload.error
            : t('alwaysOn.errors.loadFailed')
        );
      }

      if (!plansResponse.ok) {
        throw new Error(
          typeof plansPayload?.error === 'string' && plansPayload.error.trim().length > 0
            ? plansPayload.error
            : t('alwaysOn.errors.loadFailed')
        );
      }

      const cronBody = jobsPayload as ProjectCronJobsResponse | null;
      const plansBody = plansPayload as ProjectDiscoveryPlansResponse | null;
      if (!isMountedRef.current) {
        return;
      }

      setJobs(Array.isArray(cronBody?.jobs) ? cronBody.jobs : []);
      setPlans(Array.isArray(plansBody?.plans) ? plansBody.plans : []);
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
    void loadOverview('initial');

    const intervalId = window.setInterval(() => {
      void loadOverview('poll');
    }, POLL_INTERVAL_MS);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [loadOverview]);

  const summary = useMemo(() => {
    const cronSummary = jobs.reduce((accumulator, job) => {
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

    const discoverySummary = plans.reduce((accumulator, plan) => {
      if (plan.approvalMode === 'manual' && plan.status === 'ready') {
        accumulator.manualPending += 1;
      }
      if (plan.status === 'running') {
        accumulator.running += 1;
      }
      return accumulator;
    }, {
      manualPending: 0,
      running: 0,
    });

    return {
      ...cronSummary,
      ...discoverySummary,
    };
  }, [jobs, plans]);

  const sortedJobs = useMemo(() => sortCronJobsByCreatedAt(jobs), [jobs]);
  const sortedPlans = useMemo(() => sortDiscoveryPlansByUpdatedAt(plans), [plans]);
  const selectedJob = useMemo(
    () => findSelectedCronJob(jobs, selectedTaskId),
    [jobs, selectedTaskId]
  );
  const selectedPlan = useMemo(
    () => findSelectedDiscoveryPlan(plans, selectedPlanId),
    [plans, selectedPlanId]
  );

  const notAvailableLabel = t('alwaysOn.values.notAvailable');
  const selectedJobStatusLabel = selectedJob ? t(`alwaysOn.status.${selectedJob.status}`) : '';
  const selectedPlanStatusLabel = selectedPlan
    ? t(`alwaysOn.status.${selectedPlan.status}`, {
        defaultValue: getDisplayText(selectedPlan.status, notAvailableLabel),
      })
    : '';

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
      key: 'manualPending',
      label: t('alwaysOn.discovery.summary.manualPending', { defaultValue: 'Manual plans' }),
      value: summary.manualPending,
      icon: <FileText className="h-4 w-4 text-primary" />
    },
    {
      key: 'discoveryRunning',
      label: t('alwaysOn.discovery.summary.running', { defaultValue: 'Running plans' }),
      value: summary.running,
      icon: <Play className="h-4 w-4 text-primary" />
    }
  ];

  const handleSelectTask = useCallback((taskId: string) => {
    setSelectedTaskId(taskId);
    setSelectedPlanId(null);
    setFeedback(null);
  }, []);

  const handleSelectPlan = useCallback((planId: string) => {
    setSelectedPlanId(planId);
    setSelectedTaskId(null);
    setFeedback(null);
  }, []);

  const handleBackToOverview = useCallback(() => {
    setSelectedTaskId(null);
    setSelectedPlanId(null);
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
      await loadOverview('refresh');
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
  }, [loadOverview, selectedJob, selectedProject.name, t]);

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

      await loadOverview('refresh');
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
  }, [loadOverview, selectedJob, selectedProject.name, t]);

  const handleExecutePlan = useCallback(async () => {
    if (!selectedPlan) {
      return;
    }

    setIsExecutingPlan(true);
    setFeedback(null);
    try {
      await onExecuteDiscoveryPlan(selectedPlan.id, 'manual');
      setFeedback({
        tone: 'success',
        message: t('alwaysOn.discovery.feedback.executionQueued', {
          id: selectedPlan.id,
          defaultValue: `Queued discovery plan ${selectedPlan.id} for execution.`,
        }),
      });
      await loadOverview('refresh');
    } catch (executeError) {
      setFeedback({
        tone: 'error',
        message: getRefreshErrorMessage(
          executeError,
          t('alwaysOn.discovery.errors.executeFailed', { defaultValue: 'Failed to execute discovery plan.' }),
        ),
      });
    } finally {
      if (isMountedRef.current) {
        setIsExecutingPlan(false);
      }
    }
  }, [loadOverview, onExecuteDiscoveryPlan, selectedPlan, t]);

  const handleArchivePlan = useCallback(async () => {
    if (!selectedPlan) {
      return;
    }

    setIsArchivingPlan(true);
    setFeedback(null);
    try {
      const response = await api.archiveProjectDiscoveryPlan(selectedProject.name, selectedPlan.id);
      const payload = await readJsonPayload(response);
      if (!response.ok) {
        throw new Error(
          getPayloadError(payload) ?? t('alwaysOn.discovery.errors.archiveFailed', { defaultValue: 'Failed to archive discovery plan.' }),
        );
      }

      setSelectedPlanId(null);
      setFeedback({
        tone: 'success',
        message: t('alwaysOn.discovery.feedback.archived', {
          id: selectedPlan.id,
          defaultValue: `Archived discovery plan ${selectedPlan.id}.`,
        }),
      });
      await loadOverview('refresh');
    } catch (archiveError) {
      setFeedback({
        tone: 'error',
        message: getRefreshErrorMessage(
          archiveError,
          t('alwaysOn.discovery.errors.archiveFailed', { defaultValue: 'Failed to archive discovery plan.' }),
        ),
      });
    } finally {
      if (isMountedRef.current) {
        setIsArchivingPlan(false);
      }
    }
  }, [loadOverview, selectedPlan, selectedProject.name, t]);

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

  const renderContextRefList = useCallback((label: string, items: string[]) => {
    return (
      <DetailField label={label}>
        {items.length > 0 ? (
          <ul className="space-y-1 text-sm text-foreground">
            {items.map((item) => (
              <li key={`${label}-${item}`} className="break-words text-muted-foreground">
                {item}
              </li>
            ))}
          </ul>
        ) : (
          <span className="text-muted-foreground">{notAvailableLabel}</span>
        )}
      </DetailField>
    );
  }, [notAvailableLabel]);

  const canRunSelectedPlan =
    selectedPlan != null &&
    selectedPlan.approvalMode === 'manual' &&
    selectedPlan.status !== 'running' &&
    selectedPlan.status !== 'queued';
  const canArchiveSelectedPlan =
    selectedPlan != null &&
    selectedPlan.status !== 'running' &&
    selectedPlan.status !== 'queued';

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
              onClick={() => void loadOverview('refresh')}
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
          {!selectedTaskId && !selectedPlanId && (
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
          ) : selectedPlanId ? (
            selectedPlan ? (
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
                        <h3 className="text-lg font-semibold text-foreground">{selectedPlan.title}</h3>
                        <p className="break-all text-sm text-muted-foreground">{selectedPlan.id}</p>
                      </div>
                    </div>

                    <div className="flex flex-wrap gap-2">
                      {canRunSelectedPlan && (
                        <Button
                          type="button"
                          variant="outline"
                          onClick={() => void handleExecutePlan()}
                          disabled={isExecutingPlan || isArchivingPlan}
                        >
                          <Play className={isExecutingPlan ? 'animate-pulse' : ''} />
                          {t('alwaysOn.actions.runNow')}
                        </Button>
                      )}
                      {selectedPlan.executionSessionId && (
                        <Button
                          type="button"
                          variant="outline"
                          onClick={() => onOpenDiscoverySession(selectedPlan.executionSessionId!)}
                        >
                          <ExternalLink className="h-4 w-4" />
                          {t('alwaysOn.discovery.actions.openSession', { defaultValue: 'Open session' })}
                        </Button>
                      )}
                      <Button
                        type="button"
                        variant="destructive"
                        onClick={() => void handleArchivePlan()}
                        disabled={!canArchiveSelectedPlan || isArchivingPlan || isExecutingPlan}
                      >
                        <Trash2 className={isArchivingPlan ? 'animate-pulse' : ''} />
                        {t('alwaysOn.discovery.actions.archive', { defaultValue: 'Archive' })}
                      </Button>
                    </div>
                  </div>
                </div>

                <div className="grid gap-4 xl:grid-cols-[minmax(0,360px)_minmax(0,1fr)]">
                  <div className="rounded-xl border border-border bg-card/50 p-4 shadow-sm">
                    <div className="mb-4 flex items-center justify-between gap-3">
                      <h4 className="text-sm font-semibold text-foreground">
                        {t('alwaysOn.discovery.detail.meta', { defaultValue: 'Plan metadata' })}
                      </h4>
                      <Badge variant={getStatusBadgeVariant(selectedPlan.status)}>
                        {selectedPlanStatusLabel}
                      </Badge>
                    </div>

                    <dl className="space-y-4">
                      <DetailField label={t('alwaysOn.discovery.fields.summary', { defaultValue: 'Summary' })}>
                        <div className="whitespace-pre-wrap break-words">{getDisplayText(selectedPlan.summary, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.rationale', { defaultValue: 'Rationale' })}>
                        <div className="whitespace-pre-wrap break-words">{getDisplayText(selectedPlan.rationale, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.approvalMode', { defaultValue: 'Approval mode' })}>
                        <Badge variant="outline" className="text-xs">
                          {getDiscoveryPlanApprovalModeLabel(selectedPlan.approvalMode, t)}
                        </Badge>
                      </DetailField>
                      <DetailField label={t('alwaysOn.fields.createdAt')}>
                        {formatDateTime(selectedPlan.createdAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.updatedAt', { defaultValue: 'Updated' })}>
                        {formatDateTime(selectedPlan.updatedAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.planFile', { defaultValue: 'Plan file' })}>
                        <div className="break-all">{getDisplayText(selectedPlan.planFilePath, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.sourceSession', { defaultValue: 'Discovery session' })}>
                        <div className="break-all">{getDisplayText(selectedPlan.sourceDiscoverySessionId, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.executionSession', { defaultValue: 'Execution session' })}>
                        <div className="break-all">{getDisplayText(selectedPlan.executionSessionId, notAvailableLabel)}</div>
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.executionStartedAt', { defaultValue: 'Execution started' })}>
                        {formatDateTime(selectedPlan.executionStartedAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.executionLastActivityAt', { defaultValue: 'Last activity' })}>
                        {formatDateTime(selectedPlan.executionLastActivityAt, notAvailableLabel)}
                      </DetailField>
                      <DetailField label={t('alwaysOn.discovery.fields.latestSummary', { defaultValue: 'Latest summary' })}>
                        <div className="whitespace-pre-wrap break-words">{getDisplayText(selectedPlan.latestSummary, notAvailableLabel)}</div>
                      </DetailField>
                      {renderContextRefList(
                        t('alwaysOn.discovery.fields.contextRefsWorkingDirectory', { defaultValue: 'Workspace signals' }),
                        selectedPlan.contextRefs.workingDirectory,
                      )}
                      {renderContextRefList(
                        t('alwaysOn.discovery.fields.contextRefsMemory', { defaultValue: 'Memory references' }),
                        selectedPlan.contextRefs.memory,
                      )}
                      {renderContextRefList(
                        t('alwaysOn.discovery.fields.contextRefsPlans', { defaultValue: 'Related plans' }),
                        selectedPlan.contextRefs.existingPlans,
                      )}
                      {renderContextRefList(
                        t('alwaysOn.discovery.fields.contextRefsCron', { defaultValue: 'Related cron jobs' }),
                        selectedPlan.contextRefs.cronJobs,
                      )}
                      {renderContextRefList(
                        t('alwaysOn.discovery.fields.contextRefsChats', { defaultValue: 'Recent chats' }),
                        selectedPlan.contextRefs.recentChats,
                      )}
                    </dl>
                  </div>

                  <div className="rounded-xl border border-border bg-card/50 p-4 shadow-sm">
                    <div className="mb-4 flex items-center justify-between gap-3">
                      <h4 className="text-sm font-semibold text-foreground">
                        {t('alwaysOn.discovery.detail.plan', { defaultValue: 'Plan content' })}
                      </h4>
                      <Badge variant="outline" className="text-xs">
                        {getDisplayText(String(selectedPlan.structureVersion), '1')}
                      </Badge>
                    </div>

                    {selectedPlan.content ? (
                      <Markdown className="prose prose-sm max-w-none dark:prose-invert">
                        {selectedPlan.content}
                      </Markdown>
                    ) : (
                      <div className="rounded-lg border border-dashed border-border bg-muted/20 px-4 py-6 text-sm text-muted-foreground">
                        {t('alwaysOn.discovery.detail.noContent', { defaultValue: 'This discovery plan does not have stored markdown content.' })}
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
                <h3 className="text-base font-medium text-foreground">
                  {t('alwaysOn.discovery.detail.missingTitle', { defaultValue: 'Discovery plan no longer available' })}
                </h3>
                <p className="mt-2 text-sm text-muted-foreground">
                  {t('alwaysOn.discovery.detail.missingDescription', { defaultValue: 'This plan may have been updated or archived since the overview was loaded.' })}
                </p>
                <div className="mt-4">
                  <Button type="button" variant="outline" onClick={handleBackToOverview}>
                    <ArrowLeft className="h-4 w-4" />
                    {t('navigation.back')}
                  </Button>
                </div>
              </div>
            )
          ) : (
            <div className="space-y-6">
              <section className="space-y-3">
                <div className="flex items-center justify-between gap-3">
                  <div>
                    <h3 className="text-sm font-semibold text-foreground">
                      {t('alwaysOn.discovery.title', { defaultValue: 'Discovery plans' })}
                    </h3>
                    <p className="text-sm text-muted-foreground">
                      {t('alwaysOn.discovery.description', { defaultValue: 'Structured plans generated by Always-On discovery before execution.' })}
                    </p>
                  </div>
                </div>

                {sortedPlans.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-border bg-card/30 px-6 py-10 text-center">
                    <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-muted/50">
                      <FileText className="h-6 w-6 text-muted-foreground" />
                    </div>
                    <h4 className="text-base font-medium text-foreground">
                      {t('alwaysOn.discovery.emptyTitle', { defaultValue: 'No discovery plans yet' })}
                    </h4>
                    <p className="mt-2 text-sm text-muted-foreground">
                      {t('alwaysOn.discovery.emptyDescription', { defaultValue: 'Run discovery to generate structured plans for follow-up work.' })}
                    </p>
                  </div>
                ) : (
                  <div className="overflow-x-auto rounded-xl border border-border bg-card/50 shadow-sm">
                    <table className="w-full min-w-[960px] border-collapse text-sm">
                      <thead className="bg-muted/30">
                        <tr className="border-b border-border/60">
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.discovery.fields.title', { defaultValue: 'Title' })}
                          </th>
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.fields.status')}
                          </th>
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.discovery.fields.approvalMode', { defaultValue: 'Approval mode' })}
                          </th>
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.discovery.fields.updatedAt', { defaultValue: 'Updated' })}
                          </th>
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.discovery.fields.executionSession', { defaultValue: 'Execution session' })}
                          </th>
                          <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            {t('alwaysOn.discovery.fields.latestSummary', { defaultValue: 'Latest summary' })}
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {sortedPlans.map((plan) => (
                          <tr key={plan.id} className="border-b border-border/60 align-top last:border-b-0">
                            <td className="px-4 py-4">
                              <button
                                type="button"
                                className="min-w-0 space-y-2 text-left transition-opacity hover:opacity-90"
                                onClick={() => handleSelectPlan(plan.id)}
                              >
                                <div className="font-medium text-foreground">{plan.title}</div>
                                <div className="max-w-md text-xs text-muted-foreground">{getDisplayText(plan.summary, notAvailableLabel)}</div>
                                <div className="text-xs font-medium text-primary">
                                  {t('alwaysOn.discovery.actions.viewDetails', { defaultValue: 'View details' })}
                                </div>
                              </button>
                            </td>
                            <td className="px-4 py-4">
                              <Badge variant={getStatusBadgeVariant(plan.status)} className="text-xs">
                                {t(`alwaysOn.status.${plan.status}`, { defaultValue: plan.status })}
                              </Badge>
                            </td>
                            <td className="px-4 py-4">
                              <Badge variant="outline" className="text-xs">
                                {getDiscoveryPlanApprovalModeLabel(plan.approvalMode, t)}
                              </Badge>
                            </td>
                            <td className="whitespace-nowrap px-4 py-4 text-foreground">
                              {formatDateTime(plan.updatedAt, notAvailableLabel)}
                            </td>
                            <td className="px-4 py-4 text-foreground">
                              <div className="max-w-64 break-all">
                                {getDisplayText(plan.executionSessionId, notAvailableLabel)}
                              </div>
                            </td>
                            <td className="px-4 py-4 text-foreground">
                              <div className="max-w-md whitespace-pre-wrap break-words text-muted-foreground">
                                {getDisplayText(plan.latestSummary, notAvailableLabel)}
                              </div>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </section>

              <section className="space-y-3">
                <div>
                  <h3 className="text-sm font-semibold text-foreground">
                    {t('alwaysOn.cron.title', { defaultValue: 'Scheduled cron jobs' })}
                  </h3>
                  <p className="text-sm text-muted-foreground">
                    {t('alwaysOn.cron.description', { defaultValue: 'Existing durable and session-scoped cron tasks for this project.' })}
                  </p>
                </div>

                {sortedJobs.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-border bg-card/30 px-6 py-10 text-center">
                    <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-muted/50">
                      <Radio className="h-6 w-6 text-muted-foreground" />
                    </div>
                    <h4 className="text-base font-medium text-foreground">{t('alwaysOn.emptyTitle')}</h4>
                    <p className="mt-2 text-sm text-muted-foreground">{t('alwaysOn.emptyDescription')}</p>
                  </div>
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
              </section>
            </div>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}
