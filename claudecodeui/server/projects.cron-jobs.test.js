import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  clearProjectDirectoryCache,
  getProjectCronJobsOverview
} from './projects.js';

const originalHome = process.env.HOME;
const originalUserProfile = process.env.USERPROFILE;
const tempHomes = [];

async function createTempHome() {
  const homeDir = await fs.mkdtemp(path.join(os.tmpdir(), 'projects-cron-jobs-'));
  tempHomes.push(homeDir);
  process.env.HOME = homeDir;
  process.env.USERPROFILE = homeDir;
  clearProjectDirectoryCache();
  return homeDir;
}

async function writeProjectConfig(homeDir, projectName, projectRoot) {
  const claudeDir = path.join(homeDir, '.claude');
  await fs.mkdir(claudeDir, { recursive: true });
  await fs.writeFile(
    path.join(claudeDir, 'project-config.json'),
    JSON.stringify({
      [projectName]: {
        manuallyAdded: true,
        originalPath: projectRoot
      }
    }, null, 2),
    'utf8'
  );
}

async function writeScheduledTasks(projectRoot, tasks) {
  const configDir = path.join(projectRoot, '.claude');
  await fs.mkdir(configDir, { recursive: true });
  await fs.writeFile(
    path.join(configDir, 'scheduled_tasks.json'),
    JSON.stringify({ tasks }, null, 2),
    'utf8'
  );
}

async function writeJsonl(filePath, entries) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(
    filePath,
    `${entries.map((entry) => JSON.stringify(entry)).join('\n')}\n`,
    'utf8'
  );
}

function createTaskNotification({ taskId, outputFile, status, summary }) {
  return `<task-notification>
<task-id>${taskId}</task-id>
<output-file>${outputFile}</output-file>
<status>${status}</status>
<summary>${summary}</summary>
</task-notification>`;
}

async function createBackgroundCronArtifacts({
  homeDir,
  projectName,
  parentSessionId,
  transcriptFileName,
  status,
  summary
}) {
  const projectStoreDir = path.join(homeDir, '.claude', 'projects', projectName);
  const transcriptPath = path.join(projectStoreDir, parentSessionId, 'subagents', transcriptFileName);

  await writeJsonl(transcriptPath, [
    {
      timestamp: '2026-04-19T10:00:00.000Z',
      message: {
        role: 'user',
        content: 'Investigate the queue backlog'
      }
    },
    {
      timestamp: '2026-04-19T10:02:00.000Z',
      message: {
        role: 'assistant',
        content: [{ type: 'text', text: 'Background run complete.' }]
      }
    }
  ]);

  await writeJsonl(path.join(projectStoreDir, 'history.jsonl'), [
    {
      sessionId: parentSessionId,
      timestamp: '2026-04-19T10:03:00.000Z',
      message: {
        role: 'user',
        content: createTaskNotification({
          taskId: `task-${status}`,
          outputFile: transcriptPath,
          status,
          summary
        })
      }
    }
  ]);

  return transcriptPath;
}

afterEach(async () => {
  clearProjectDirectoryCache();

  while (tempHomes.length > 0) {
    const homeDir = tempHomes.pop();
    await fs.rm(homeDir, { recursive: true, force: true });
  }

  if (originalHome === undefined) {
    delete process.env.HOME;
  } else {
    process.env.HOME = originalHome;
  }

  if (originalUserProfile === undefined) {
    delete process.env.USERPROFILE;
  } else {
    process.env.USERPROFILE = originalUserProfile;
  }
});

test('getProjectCronJobsOverview returns an empty list when scheduled_tasks.json is missing', async () => {
  const homeDir = await createTempHome();
  const projectName = 'project-without-scheduled-tasks';
  const projectRoot = path.join(homeDir, 'workspace-no-cron');

  await fs.mkdir(projectRoot, { recursive: true });
  await writeProjectConfig(homeDir, projectName, projectRoot);

  const overview = await getProjectCronJobsOverview(projectName);

  assert.deepEqual(overview, { jobs: [] });
});

test('getProjectCronJobsOverview marks unmatched cron jobs as scheduled', async () => {
  const homeDir = await createTempHome();
  const projectName = 'project-with-scheduled-cron-only';
  const projectRoot = path.join(homeDir, 'workspace-scheduled-only');

  await fs.mkdir(projectRoot, { recursive: true });
  await writeProjectConfig(homeDir, projectName, projectRoot);
  await writeScheduledTasks(projectRoot, [
    {
      id: 'cron-1234',
      cron: '0 * * * *',
      prompt: 'Check the queue depth',
      createdAt: 1713510000000,
      recurring: true,
      originSessionId: 'origin-session-1'
    }
  ]);

  const overview = await getProjectCronJobsOverview(projectName);

  assert.equal(overview.jobs.length, 1);
  assert.equal(overview.jobs[0].status, 'scheduled');
  assert.equal(overview.jobs[0].latestRun, null);
  assert.equal(overview.jobs[0].originSessionId, 'origin-session-1');
});

test('getProjectCronJobsOverview matches recurring cron jobs to completed background sessions via transcriptKey', async () => {
  const homeDir = await createTempHome();
  const projectName = 'project-with-completed-cron';
  const projectRoot = path.join(homeDir, 'workspace-completed');
  const parentSessionId = 'parent-session-completed';
  const transcriptFileName = 'agent-cron-completed.jsonl';

  await fs.mkdir(projectRoot, { recursive: true });
  await writeProjectConfig(homeDir, projectName, projectRoot);
  await createBackgroundCronArtifacts({
    homeDir,
    projectName,
    parentSessionId,
    transcriptFileName,
    status: 'completed',
    summary: 'Cron task "Recurring cron cron-5678" completed'
  });
  await writeScheduledTasks(projectRoot, [
    {
      id: 'cron-5678',
      cron: '*/15 * * * *',
      prompt: 'Review incoming support spikes',
      createdAt: 1713511000000,
      lastFiredAt: 1713512000000,
      recurring: true,
      originSessionId: parentSessionId,
      transcriptKey: transcriptFileName
    }
  ]);

  const overview = await getProjectCronJobsOverview(projectName);

  assert.equal(overview.jobs.length, 1);
  assert.equal(overview.jobs[0].status, 'completed');
  assert.equal(overview.jobs[0].latestRun?.summary, 'Cron task "Recurring cron cron-5678" completed');
  assert.equal(
    overview.jobs[0].latestRun?.relativeTranscriptPath,
    `${parentSessionId}/subagents/${transcriptFileName}`
  );
});

test('getProjectCronJobsOverview matches recurring cron jobs to failed background sessions via transcriptKey', async () => {
  const homeDir = await createTempHome();
  const projectName = 'project-with-failed-cron';
  const projectRoot = path.join(homeDir, 'workspace-failed');
  const parentSessionId = 'parent-session-failed';
  const transcriptFileName = 'agent-cron-failed.jsonl';

  await fs.mkdir(projectRoot, { recursive: true });
  await writeProjectConfig(homeDir, projectName, projectRoot);
  await createBackgroundCronArtifacts({
    homeDir,
    projectName,
    parentSessionId,
    transcriptFileName,
    status: 'failed',
    summary: 'Cron task "Recurring cron cron-9012" failed'
  });
  await writeScheduledTasks(projectRoot, [
    {
      id: 'cron-9012',
      cron: '30 * * * *',
      prompt: 'Audit the overnight background queue',
      createdAt: 1713513000000,
      lastFiredAt: 1713513600000,
      recurring: true,
      originSessionId: parentSessionId,
      transcriptKey: transcriptFileName
    }
  ]);

  const overview = await getProjectCronJobsOverview(projectName);

  assert.equal(overview.jobs.length, 1);
  assert.equal(overview.jobs[0].status, 'failed');
  assert.equal(overview.jobs[0].latestRun?.summary, 'Cron task "Recurring cron cron-9012" failed');
  assert.equal(overview.jobs[0].latestRun?.taskId, 'task-failed');
});
