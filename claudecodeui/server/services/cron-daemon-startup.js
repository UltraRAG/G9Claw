import { spawn } from 'child_process';
import { getLeakedClaudeSdkSpawnOptions } from '../claude-code-main-path.js';
import { sendCronDaemonRequest } from './cron-daemon-owner.js';

const DEFAULT_RETRY_ATTEMPTS = 20;
const DEFAULT_RETRY_DELAY_MS = 250;

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
  getLeakedClaudeSdkSpawnOptionsFn = getLeakedClaudeSdkSpawnOptions,
  cliPath = process.env.CLAUDE_CLI_PATH
} = {}) {
  const leakedSpawn = getLeakedClaudeSdkSpawnOptionsFn();
  if (leakedSpawn) {
    return {
      command: leakedSpawn.executable,
      args: [
        ...leakedSpawn.executableArgs,
        leakedSpawn.pathToClaudeCodeExecutable,
        'daemon',
        'serve'
      ]
    };
  }

  return {
    command: typeof cliPath === 'string' && cliPath.trim().length > 0 ? cliPath.trim() : 'claude',
    args: ['daemon', 'serve']
  };
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
}
