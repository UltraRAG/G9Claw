import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { randomUUID, type UUID } from 'crypto'
import { lstat, mkdtemp, readFile, readlink, rm } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import type { AppState } from '../state/AppState.js'
import {
  setCwdState,
  setIsInteractive,
  setOriginalCwd,
  setProjectRoot,
  setSessionPersistenceDisabled,
  switchSession,
} from '../bootstrap/state.js'
import { asAgentId, asSessionId } from '../types/ids.js'
import { flushSessionStorage, getAgentTranscriptPath } from '../utils/sessionStorage.js'
import {
  _resetTaskOutputDirForTest,
  getTaskOutputPath,
  waitForPendingTaskOutputOps,
} from '../utils/task/diskOutput.js'

mock.module('../query.js', () => ({
  async *query() {},
}))

const { startCronBackgroundTask } = await import('./CronBackgroundTask.js')

describe('CronBackgroundTask daemon mode', () => {
  let projectRoot: string
  let configDir: string
  const priorConfigDir = process.env.CLAUDE_CONFIG_DIR

  beforeEach(async () => {
    configDir = await mkdtemp(join(tmpdir(), 'cron-daemon-config-'))
    projectRoot = await mkdtemp(join(tmpdir(), 'cron-daemon-project-'))
    process.env.CLAUDE_CONFIG_DIR = configDir
    _resetTaskOutputDirForTest()
    setOriginalCwd(projectRoot)
    setProjectRoot(projectRoot)
    setCwdState(projectRoot)
    setIsInteractive(false)
  })

  afterEach(async () => {
    await flushSessionStorage()
    await waitForPendingTaskOutputOps()
    setSessionPersistenceDisabled(false)
    _resetTaskOutputDirForTest()
    if (priorConfigDir === undefined) {
      delete process.env.CLAUDE_CONFIG_DIR
    } else {
      process.env.CLAUDE_CONFIG_DIR = priorConfigDir
    }
    await rm(projectRoot, { recursive: true, force: true })
    await rm(configDir, { recursive: true, force: true })
  })

  test('persists sidechain transcript and output link with session persistence disabled', async () => {
    const originSessionId = randomUUID() as UUID
    switchSession(asSessionId(originSessionId))
    setSessionPersistenceDisabled(true)

    let appState = { tasks: {} } as AppState
    const notifications: string[] = []

    const result = await startCronBackgroundTask({
      task: {
        id: 'cron-task-1',
        cron: '* * * * *',
        prompt: 'cron daemon smoke test',
        createdAt: Date.now(),
        durable: false,
        originSessionId,
      },
      setAppState: updater => {
        appState = updater(appState)
      },
      notificationSink: async message => {
        notifications.push(message)
      },
      createQueryParams: async () =>
        ({
          toolUseContext: {
            options: {
              tools: [],
            },
          },
        }) as any,
    })

    expect(result.status).toBe('started')
    if (result.status !== 'started') {
      return
    }

    await result.completion
    await flushSessionStorage()
    await waitForPendingTaskOutputOps()

    const transcriptPath = getAgentTranscriptPath(asAgentId(result.transcriptKey))
    const transcript = await readFile(transcriptPath, 'utf-8')
    expect(transcript).toContain('cron daemon smoke test')

    const outputPath = getTaskOutputPath(result.runtimeTaskId)
    const outputStat = await lstat(outputPath)
    expect(outputStat.isSymbolicLink()).toBe(true)
    expect(await readlink(outputPath)).toBe(transcriptPath)

    expect(notifications).toHaveLength(1)
    expect(notifications[0]).toContain('<task-notification>')
    expect(notifications[0]).toContain(outputPath)
  })
})
