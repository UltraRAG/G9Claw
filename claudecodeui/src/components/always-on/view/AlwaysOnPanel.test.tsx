import { describe, expect, it } from 'vitest';
import type { RunProjectCronJobNowResponse } from '../../../types/app';
import {
  buildRunNowFeedback,
  findSelectedCronJob,
  getCronJobKindLabel,
  getPayloadError,
  getStatusBadgeVariant,
  sortCronJobsByCreatedAt
} from './AlwaysOnPanel';

const jobs = [
  {
    id: 'cron-oldest',
    cron: '* * * * *',
    prompt: 'Oldest job',
    createdAt: 1713500000000,
    durable: true,
    status: 'scheduled' as const,
    latestRun: null
  },
  {
    id: 'cron-newest',
    cron: '0 * * * *',
    prompt: 'Newest job',
    createdAt: 1713520000000,
    durable: false,
    status: 'completed' as const,
    latestRun: null
  },
  {
    id: 'cron-middle',
    cron: '30 * * * *',
    prompt: 'Middle job',
    createdAt: 1713510000000,
    durable: true,
    status: 'failed' as const,
    latestRun: null
  }
];

function t(key: string, options?: Record<string, string>) {
  let message = key;
  if (key === 'alwaysOn.feedback.runNowStarted') {
    message = 'Started {{id}} immediately.';
  }
  if (key === 'alwaysOn.feedback.alreadyRunning') {
    message = 'Task {{id}} is already running.';
  }
  if (key === 'alwaysOn.flags.sessionScoped') {
    message = 'Session';
  }
  if (key === 'alwaysOn.flags.durable') {
    message = 'Durable';
  }
  if (key === 'alwaysOn.flags.oneShot') {
    message = 'One-shot';
  }
  if (key === 'alwaysOn.flags.recurring') {
    message = 'Recurring';
  }
  if (options) {
    for (const [name, value] of Object.entries(options)) {
      message = message.replace(`{{${name}}}`, value);
    }
  }
  return message;
}

describe('AlwaysOnPanel helpers', () => {
  it('sorts jobs newest first and finds the selected task', () => {
    const sortedJobs = sortCronJobsByCreatedAt(jobs);

    expect(sortedJobs.map((job) => job.id)).toEqual([
      'cron-newest',
      'cron-middle',
      'cron-oldest'
    ]);
    expect(findSelectedCronJob(sortedJobs, 'cron-middle')?.prompt).toBe('Middle job');
    expect(findSelectedCronJob(sortedJobs, 'missing-task')).toBeNull();
    expect(findSelectedCronJob(sortedJobs, null)).toBeNull();
  });

  it('builds run-now feedback for started and already-running results', () => {
    const startedResult: RunProjectCronJobNowResponse = {
      started: true
    };
    const runningResult: RunProjectCronJobNowResponse = {
      started: false,
      reason: 'already_running'
    };

    expect(buildRunNowFeedback('cron-1234', startedResult, t)).toEqual({
      tone: 'success',
      message: 'Started cron-1234 immediately.'
    });
    expect(buildRunNowFeedback('cron-1234', runningResult, t)).toEqual({
      tone: 'info',
      message: 'Task cron-1234 is already running.'
    });
  });

  it('extracts payload errors and status badge variants consistently', () => {
    expect(getPayloadError({ error: 'boom' })).toBe('boom');
    expect(getPayloadError({ error: '   ' })).toBeNull();
    expect(getPayloadError(null)).toBeNull();

    expect(getStatusBadgeVariant('running')).toBe('default');
    expect(getStatusBadgeVariant('completed')).toBe('secondary');
    expect(getStatusBadgeVariant('failed')).toBe('destructive');
    expect(getStatusBadgeVariant('scheduled')).toBe('outline');
    expect(getStatusBadgeVariant('unknown')).toBe('outline');
  });

  it('builds a combined scope and type label for the overview table', () => {
    expect(getCronJobKindLabel({ durable: false, recurring: false }, t)).toBe('Session / One-shot');
    expect(getCronJobKindLabel({ durable: true, recurring: true }, t)).toBe('Durable / Recurring');
  });
});
