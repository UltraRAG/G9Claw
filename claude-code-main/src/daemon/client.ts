import { spawn } from 'child_process'
import {
  persistRequestedCronDaemonOwner,
  reconcileCronDaemonOwnerForCurrentProcess,
} from './ownership.js'
import { assertCronDaemonOk, sendCronDaemonRequest } from './ipc.js'
import { getDaemonCommandArgs } from './spawn.js'
import type { CronDaemonRequest, CronDaemonResponse } from './types.js'

function isDaemonUnavailableError(error: unknown): boolean {
  return (
    error instanceof Error &&
    ('code' in error &&
      (error.code === 'ENOENT' || error.code === 'ECONNREFUSED'))
  )
}

async function sleep(ms: number): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, ms))
}

async function startCronDaemonDetached(): Promise<void> {
  const child = spawn(process.execPath, getDaemonCommandArgs(), {
    cwd: process.cwd(),
    env: process.env,
    detached: true,
    stdio: 'ignore',
  })
  child.unref()
}

export async function ensureCronDaemon(): Promise<void> {
  let startedByCurrentProcess = false
  try {
    const response = await sendCronDaemonRequest({ type: 'ping' })
    assertCronDaemonOk(response)
    await reconcileCronDaemonOwnerForCurrentProcess()
    return
  } catch (error) {
    if (!isDaemonUnavailableError(error)) {
      throw error
    }
  }

  await startCronDaemonDetached()
  startedByCurrentProcess = true

  let lastError: unknown = null
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      const response = await sendCronDaemonRequest({ type: 'ping' })
      assertCronDaemonOk(response)
      if (startedByCurrentProcess) {
        await persistRequestedCronDaemonOwner()
      }
      return
    } catch (error) {
      lastError = error
      await sleep(250)
    }
  }

  throw lastError instanceof Error
    ? lastError
    : new Error('Cron daemon failed to start')
}

export async function requestCronDaemon(
  request: CronDaemonRequest,
): Promise<CronDaemonResponse> {
  await ensureCronDaemon()
  return await sendCronDaemonRequest(request)
}
