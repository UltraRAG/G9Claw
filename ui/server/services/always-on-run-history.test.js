import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  appendAlwaysOnRunEvent,
  getAlwaysOnRunHistory,
  getAlwaysOnRunHistoryDetail,
  getRunHistoryPath,
} from './always-on-run-history.js';

const tempDirs = [];

async function createTempDir(prefix) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

afterEach(async () => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('run history appends events and folds them by run id', async () => {
  const projectRoot = await createTempDir('always-on-run-history-');

  await appendAlwaysOnRunEvent(projectRoot, {
    runId: 'run-1',
    kind: 'plan',
    sourceId: 'plan-alpha',
    title: 'Plan Alpha',
    status: 'queued',
    timestamp: '2026-04-20T10:00:00.000Z',
    metadata: { source: 'manual' },
  });
  await appendAlwaysOnRunEvent(projectRoot, {
    runId: 'run-1',
    kind: 'plan',
    sourceId: 'plan-alpha',
    title: 'Plan Alpha',
    status: 'completed',
    timestamp: '2026-04-20T10:05:00.000Z',
    finishedAt: '2026-04-20T10:05:00.000Z',
    sessionId: 'session-1',
    output: 'Done.',
    metadata: { planFilePath: '.claude/always-on/plans/plan-alpha.md' },
  });
  await fs.appendFile(getRunHistoryPath(projectRoot), 'not json\n', 'utf8');

  const history = await getAlwaysOnRunHistory(projectRoot);
  assert.equal(history.runs.length, 1);
  assert.equal(history.runs[0].runId, 'run-1');
  assert.equal(history.runs[0].status, 'completed');
  assert.equal(history.runs[0].sourceId, 'plan-alpha');
  assert.equal(history.runs[0].session?.sessionId, 'session-1');

  const detail = await getAlwaysOnRunHistoryDetail(projectRoot, 'run-1');
  assert.match(detail.outputLog, /Done/);
  assert.equal(detail.metadata.source, 'manual');
  assert.equal(detail.metadata.planFilePath, '.claude/always-on/plans/plan-alpha.md');
});

test('run history detail returns not found for unknown run id', async () => {
  const projectRoot = await createTempDir('always-on-run-history-missing-');
  await assert.rejects(
    () => getAlwaysOnRunHistoryDetail(projectRoot, 'missing-run'),
    /Run history entry not found/,
  );
});

test('run history list filters unknown status entries', async () => {
  const projectRoot = await createTempDir('always-on-run-history-unknown-');

  await appendAlwaysOnRunEvent(projectRoot, {
    runId: 'run-visible',
    kind: 'cron',
    sourceId: 'cron-visible',
    title: 'Visible run',
    status: 'completed',
    timestamp: '2026-04-20T10:00:00.000Z',
  });
  await appendAlwaysOnRunEvent(projectRoot, {
    runId: 'run-hidden',
    kind: 'cron',
    sourceId: 'cron-hidden',
    title: 'Hidden run',
    status: 'unknown',
    timestamp: '2026-04-20T10:01:00.000Z',
  });

  const history = await getAlwaysOnRunHistory(projectRoot);
  assert.deepEqual(history.runs.map((run) => run.runId), ['run-visible']);

  const detail = await getAlwaysOnRunHistoryDetail(projectRoot, 'run-hidden');
  assert.equal(detail.status, 'unknown');
});
