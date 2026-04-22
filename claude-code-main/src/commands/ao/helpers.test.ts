import { expect, test } from 'bun:test'
import { mkdtemp, mkdir, rm, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import {
  parseAoArgs,
  prepareAoDiscoveryPlanExecution,
} from './helpers.js'
import { readDiscoveryPlanIndex } from '../../utils/alwaysOnDiscoveryPlans.js'

async function writeDiscoveryPlan(
  projectRoot: string,
  plan: Record<string, unknown>,
): Promise<void> {
  const alwaysOnDir = join(projectRoot, '.claude', 'always-on')
  const plansDir = join(alwaysOnDir, 'plans')
  await mkdir(plansDir, { recursive: true })
  await writeFile(
    join(alwaysOnDir, 'discovery-plans.json'),
    `${JSON.stringify({ version: 1, plans: [plan] }, null, 2)}\n`,
    'utf8',
  )
  await writeFile(
    join(projectRoot, String(plan.planFilePath)),
    `# Example plan

## Context
A

## Signals Reviewed
B

## Proposed Work
C

## Execution Steps
D

## Verification
E

## Approval And Execution
F
`,
    'utf8',
  )
}

test('parseAoArgs supports list, status, run, and help fallback', () => {
  expect(parseAoArgs('')).toEqual({ action: 'help' })
  expect(parseAoArgs('list')).toEqual({ action: 'list', target: 'all' })
  expect(parseAoArgs('list cron')).toEqual({ action: 'list', target: 'cron' })
  expect(parseAoArgs('status plan plan-alpha')).toEqual({
    action: 'status',
    target: 'plan',
    id: 'plan-alpha',
  })
  expect(parseAoArgs('run cron cron-123')).toEqual({
    action: 'run',
    target: 'cron',
    id: 'cron-123',
  })
  expect(parseAoArgs('run unknown thing')).toEqual({
    action: 'help',
    error: 'Usage: /ao run <cron|plan> <id>',
  })
})

test('prepareAoDiscoveryPlanExecution throws when the plan is missing', async () => {
  const projectRoot = await mkdtemp(join(tmpdir(), 'ao-command-missing-'))

  try {
    await expect(
      prepareAoDiscoveryPlanExecution('missing-plan', {
        executionSessionId: 'session-123',
        projectRoot,
      }),
    ).rejects.toThrow('Discovery plan not found')
  } finally {
    await rm(projectRoot, { recursive: true, force: true })
  }
})

test('prepareAoDiscoveryPlanExecution rejects queued plans', async () => {
  const projectRoot = await mkdtemp(join(tmpdir(), 'ao-command-queued-'))

  try {
    await writeDiscoveryPlan(projectRoot, {
      id: 'plan-queued',
      title: 'Queued plan',
      createdAt: '2026-04-20T10:00:00.000Z',
      updatedAt: '2026-04-20T10:00:00.000Z',
      approvalMode: 'manual',
      status: 'queued',
      summary: 'Already queued.',
      rationale: 'Avoid duplicate execution.',
      dedupeKey: 'queued-plan',
      sourceDiscoverySessionId: 'discovery-session-1',
      executionStatus: 'queued',
      contextRefs: {
        workingDirectory: [],
        memory: [],
        existingPlans: [],
        cronJobs: [],
        recentChats: [],
      },
      planFilePath: '.claude/always-on/plans/plan-queued.md',
      structureVersion: 1,
    })

    await expect(
      prepareAoDiscoveryPlanExecution('plan-queued', {
        executionSessionId: 'session-queued',
        projectRoot,
      }),
    ).rejects.toThrow('Discovery plan is already queued or running')
  } finally {
    await rm(projectRoot, { recursive: true, force: true })
  }
})

test('prepareAoDiscoveryPlanExecution marks the plan running and builds a prompt', async () => {
  const projectRoot = await mkdtemp(join(tmpdir(), 'ao-command-run-'))

  try {
    await writeDiscoveryPlan(projectRoot, {
      id: 'plan-run',
      title: 'Investigate flaky tests',
      createdAt: '2026-04-20T10:00:00.000Z',
      updatedAt: '2026-04-20T10:00:00.000Z',
      approvalMode: 'manual',
      status: 'ready',
      summary: 'Stabilize flaky tests.',
      rationale: 'Keep CI healthy.',
      dedupeKey: 'flaky-tests',
      sourceDiscoverySessionId: 'discovery-session-2',
      contextRefs: {
        workingDirectory: [],
        memory: [],
        existingPlans: [],
        cronJobs: [],
        recentChats: [],
      },
      planFilePath: '.claude/always-on/plans/plan-run.md',
      structureVersion: 1,
    })

    const execution = await prepareAoDiscoveryPlanExecution('plan-run', {
      executionSessionId: 'session-run',
      projectRoot,
    })

    expect(execution.plan.status).toBe('running')
    expect(execution.plan.executionStatus).toBe('running')
    expect(execution.plan.executionSessionId).toBe('session-run')
    expect(execution.prompt).toContain('Do not enter Plan Mode.')
    expect(execution.prompt).toContain('## Execution Steps')

    const index = await readDiscoveryPlanIndex(projectRoot)
    expect(index.plans[0]).toMatchObject({
      id: 'plan-run',
      status: 'running',
      executionStatus: 'running',
      executionSessionId: 'session-run',
    })
  } finally {
    await rm(projectRoot, { recursive: true, force: true })
  }
})
