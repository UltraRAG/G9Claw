import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import { DatabaseSync } from 'node:sqlite';
import { EdgeClawMemoryService, hashText } from '../../../edgeclaw-memory-core/lib/index.js';
import { extractProjectDirectory } from '../projects.js';

const MEMORY_ROOT_DIR = path.join(os.homedir(), '.edgeclaw', 'memory');
const MEMORY_WORKSPACES_ROOT = path.join(MEMORY_ROOT_DIR, 'workspaces');
const MEMORY_SCHEDULER_INTERVAL_MS = 60_000;

const servicesByDataDir = new Map();
const workspaceTaskChains = new Map();

let schedulerTimer = null;
let schedulerCyclePromise = null;

function normalizePath(projectPath) {
  return typeof projectPath === 'string' && projectPath.trim()
    ? path.resolve(projectPath.trim())
    : '';
}

function resolveWorkspaceDataDir(projectPath) {
  return path.join(MEMORY_WORKSPACES_ROOT, hashText(path.resolve(projectPath)));
}

function buildServiceForDataDir(dataDir, workspaceDir = dataDir) {
  return new EdgeClawMemoryService({
    workspaceDir,
    dbPath: path.join(dataDir, 'control.sqlite'),
    memoryDir: path.join(dataDir, 'memory'),
    source: 'claudecodeui',
  });
}

function readWorkspaceDirFromDataDir(dataDir) {
  const dbPath = path.join(dataDir, 'control.sqlite');
  try {
    const db = new DatabaseSync(dbPath);
    try {
      const row = db.prepare(
        'SELECT state_json FROM pipeline_state WHERE state_key = ?',
      ).get('workspaceDir');
      if (!row || typeof row.state_json !== 'string') {
        return null;
      }
      const parsed = JSON.parse(row.state_json);
      return typeof parsed === 'string' && parsed.trim()
        ? path.resolve(parsed.trim())
        : null;
    } finally {
      db.close();
    }
  } catch {
    return null;
  }
}

function getOrCreateServiceForDataDir(dataDir, workspaceDir = dataDir) {
  const normalizedDataDir = path.resolve(dataDir);
  let service = servicesByDataDir.get(normalizedDataDir);
  if (!service) {
    const restoredWorkspaceDir = readWorkspaceDirFromDataDir(normalizedDataDir);
    service = buildServiceForDataDir(normalizedDataDir, restoredWorkspaceDir ?? workspaceDir);
    servicesByDataDir.set(normalizedDataDir, service);
  }
  return {
    dataDir: normalizedDataDir,
    service,
  };
}

function getOrCreateServiceForProjectPath(projectPath) {
  const normalizedProjectPath = normalizePath(projectPath);
  if (!normalizedProjectPath) {
    throw new Error('projectPath is required');
  }
  const dataDir = resolveWorkspaceDataDir(normalizedProjectPath);
  const existing = servicesByDataDir.get(path.resolve(dataDir));
  if (existing && existing.workspaceDir !== normalizedProjectPath) {
    try {
      existing.close();
    } catch {
      // ignore close failures when refreshing workspace context
    }
    servicesByDataDir.delete(path.resolve(dataDir));
  }
  return {
    projectPath: normalizedProjectPath,
    ...getOrCreateServiceForDataDir(dataDir, normalizedProjectPath),
  };
}

function enqueueWorkspaceTask(dataDir, task) {
  const key = path.resolve(dataDir);
  const previous = workspaceTaskChains.get(key) ?? Promise.resolve();
  const next = previous
    .catch(() => undefined)
    .then(task);
  const sentinel = next.then(() => undefined, () => undefined);
  workspaceTaskChains.set(key, sentinel);
  sentinel.finally(() => {
    if (workspaceTaskChains.get(key) === sentinel) {
      workspaceTaskChains.delete(key);
    }
  });
  return next;
}

async function pathExists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function listWorkspaceDataDirs() {
  try {
    const entries = await fs.readdir(MEMORY_WORKSPACES_ROOT, { withFileTypes: true });
    const dirs = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const dataDir = path.join(MEMORY_WORKSPACES_ROOT, entry.name);
      const hasDb = await pathExists(path.join(dataDir, 'control.sqlite'));
      const hasMemoryDir = await pathExists(path.join(dataDir, 'memory'));
      if (hasDb && hasMemoryDir) {
        dirs.push(dataDir);
      }
    }
    return dirs.sort((left, right) => left.localeCompare(right));
  } catch {
    return [];
  }
}

async function executeScheduledMaintenanceForDataDir(dataDir) {
  const { service } = getOrCreateServiceForDataDir(dataDir);
  return enqueueWorkspaceTask(dataDir, async () => service.runDueScheduledMaintenance('scheduled:server_scheduler'));
}

export async function resolveProjectPathFromRequest(req) {
  const queryProjectPath = normalizePath(req.query?.projectPath);
  if (queryProjectPath) {
    return queryProjectPath;
  }

  const bodyProjectPath = normalizePath(req.body?.projectPath);
  if (bodyProjectPath) {
    return bodyProjectPath;
  }

  const projectName = typeof req.query?.projectName === 'string'
    ? req.query.projectName.trim()
    : typeof req.params?.projectName === 'string'
      ? req.params.projectName.trim()
      : '';

  if (!projectName) {
    throw new Error('projectPath or projectName is required');
  }

  return path.resolve(await extractProjectDirectory(projectName));
}

export async function getMemoryServiceForRequest(req) {
  const projectPath = await resolveProjectPathFromRequest(req);
  return getOrCreateServiceForProjectPath(projectPath);
}

export async function runManualMemoryFlush(service, dataDir, options = {}) {
  return enqueueWorkspaceTask(dataDir, async () => service.flush({
    reason: options.reason ?? 'manual',
    ...(typeof options.batchSize === 'number' ? { batchSize: options.batchSize } : {}),
    ...(Array.isArray(options.sessionKeys) ? { sessionKeys: options.sessionKeys } : {}),
  }));
}

export async function runManualMemoryDream(service, dataDir) {
  return enqueueWorkspaceTask(dataDir, async () => service.dream('manual'));
}

export async function runMemorySchedulerCycle() {
  if (schedulerCyclePromise) {
    return schedulerCyclePromise;
  }

  schedulerCyclePromise = (async () => {
    const workspaceDataDirs = await listWorkspaceDataDirs();
    for (const dataDir of workspaceDataDirs) {
      try {
        await executeScheduledMaintenanceForDataDir(dataDir);
      } catch (error) {
        console.error(`[memory-scheduler] scheduled maintenance failed for ${dataDir}:`, error);
      }
    }
  })().finally(() => {
    schedulerCyclePromise = null;
  });

  return schedulerCyclePromise;
}

export function startMemoryScheduler() {
  if (schedulerTimer) {
    return;
  }

  schedulerTimer = setInterval(() => {
    void runMemorySchedulerCycle();
  }, MEMORY_SCHEDULER_INTERVAL_MS);

  if (typeof schedulerTimer.unref === 'function') {
    schedulerTimer.unref();
  }

  void runMemorySchedulerCycle();
}

export function stopMemoryScheduler() {
  if (schedulerTimer) {
    clearInterval(schedulerTimer);
    schedulerTimer = null;
  }
}

export function closeMemoryServices() {
  stopMemoryScheduler();
  for (const service of servicesByDataDir.values()) {
    try {
      service.close();
    } catch {
      // ignore close failures during shutdown
    }
  }
  servicesByDataDir.clear();
  workspaceTaskChains.clear();
}
