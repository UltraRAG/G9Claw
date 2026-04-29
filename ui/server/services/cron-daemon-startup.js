import path from 'path';
import { promises as fs } from 'fs';
import os from 'os';
import { spawn } from 'child_process';
import { resolveClaudeCodeMainRoot } from '../claude-code-main-path.js';
import { sendCronDaemonRequest } from './cron-daemon-owner.js';

const DEFAULT_RETRY_ATTEMPTS = 20;
const DEFAULT_RETRY_DELAY_MS = 250;
const START_LOCK_STALE_MS = 30000;

function getClaudeConfigHomeDir() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

function getCronDaemonStartLockPath() {
  return path.join(getClaudeConfigHomeDir(), 'cron-daemon', 'start.lock');
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export function isCronDaemonUnavailableError(error) {
  return Boolean(
    error instanceof Error &&
    'code' in error &&
    (error.code === 'ENOENT' || error.code === 'ECONNREFUSED')
  );
}

export function buildCronDaemonSpawnCommand({
  resolveClaudeCodeMainRootFn = resolveClaudeCodeMainRoot,
  cliPath = process.env.CLAUDE_CLI_PATH
} = {}) {
  const localClaudeCodeMainRoot = resolveClaudeCodeMainRootFn();
  if (localClaudeCodeMainRoot) {
    const preloadPath = path.join(localClaudeCodeMainRoot, 'preload.ts');
    const daemonMainPath = path.join(localClaudeCodeMainRoot, 'src', 'daemon', 'main.ts');
    return {
      command: 'bun',
      args: [
        '--preload',
        preloadPath,
        '-e',
        `const { daemonMain } = await import(${JSON.stringify(daemonMainPath)}); await daemonMain(['serve'])`
      ]
    };
  }

  return {
    command: typeof cliPath === 'string' && cliPath.trim().length > 0 ? cliPath.trim() : 'claude',
    args: ['daemon', 'serve']
  };
}

async function acquireStartLock() {
  const lockPath = getCronDaemonStartLockPath();
  await fs.mkdir(path.dirname(lockPath), { recursive: true });
  try {
    const handle = await fs.open(lockPath, 'wx');
    await handle.writeFile(`${process.pid}\n`, 'utf8');
    await handle.close();
    return async () => {
      await fs.rm(lockPath, { force: true }).catch(() => {});
    };
  } catch (error) {
    if (error?.code !== 'EEXIST') {
      throw error;
    }
  }

  const ageMs = await fs.stat(lockPath)
    .then((stats) => Date.now() - stats.mtimeMs)
    .catch(() => 0);
  if (ageMs > START_LOCK_STALE_MS) {
    await fs.rm(lockPath, { force: true }).catch(() => {});
    return await acquireStartLock();
  }
  return null;
}

export async function pingCronDaemon({
  sendCronDaemonRequestFn = sendCronDaemonRequest
} = {}) {
  const response = await sendCronDaemonRequestFn({ type: 'ping' });
  if (!response?.ok || response.data?.type !== 'pong') {
    throw new Error('Unexpected Cron daemon ping response');
  }
  return response;
}

export function startCronDaemonDetached({
  spawnFn = spawn,
  buildCronDaemonSpawnCommandFn = buildCronDaemonSpawnCommand
} = {}) {
  const { command, args } = buildCronDaemonSpawnCommandFn();
  const child = spawnFn(command, args, {
    cwd: process.cwd(),
    env: process.env,
    detached: true,
    stdio: 'ignore'
  });
  if (typeof child?.unref === 'function') {
    child.unref();
  }
  return child;
}

export async function ensureCronDaemonForUiStartup({
  sendCronDaemonRequestFn = sendCronDaemonRequest,
  spawnFn = spawn,
  buildCronDaemonSpawnCommandFn = buildCronDaemonSpawnCommand,
  sleepFn = sleep,
  retryAttempts = DEFAULT_RETRY_ATTEMPTS,
  retryDelayMs = DEFAULT_RETRY_DELAY_MS
} = {}) {
  try {
    return await pingCronDaemon({ sendCronDaemonRequestFn });
  } catch (error) {
    if (!isCronDaemonUnavailableError(error)) {
      throw error;
    }
  }

  const releaseStartLock = await acquireStartLock();
  if (releaseStartLock) {
    try {
      try {
        return await pingCronDaemon({ sendCronDaemonRequestFn });
      } catch {
        // We own startup now; any unhealthy ping means this process should spawn.
      }

      startCronDaemonDetached({
        spawnFn,
        buildCronDaemonSpawnCommandFn
      });

      let lastError = null;
      for (let attempt = 0; attempt < retryAttempts; attempt += 1) {
        try {
          return await pingCronDaemon({ sendCronDaemonRequestFn });
        } catch (error) {
          lastError = error;
          if (attempt < retryAttempts - 1) {
            await sleepFn(retryDelayMs);
          }
        }
      }

      throw lastError instanceof Error ? lastError : new Error('Cron daemon failed to start');
    } finally {
      await releaseStartLock();
    }
  }

  let lastError = null;
  for (let attempt = 0; attempt < retryAttempts; attempt += 1) {
    try {
      return await pingCronDaemon({ sendCronDaemonRequestFn });
    } catch (error) {
      lastError = error;
      if (attempt < retryAttempts - 1) {
        await sleepFn(retryDelayMs);
      }
    }
  }

  throw lastError instanceof Error ? lastError : new Error('Cron daemon failed to start');
}
