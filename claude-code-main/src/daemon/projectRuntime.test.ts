import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { EventEmitter } from 'events'
import { mkdtemp, readFile, rm, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { ProjectRuntime } from './projectRuntime.js'
import { DaemonSessionTaskStore } from './sessionTaskStore.js'
import type { DaemonCronTask } from './types.js'
import { sleep } from '../utils/sleep.js'

describe('ProjectRuntime', () => {
  let projectRoot: string

  beforeEach(async () => {
    projectRoot = await mkdtemp(join(tmpdir(), 'project-runtime-cron-'))
  })

  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  test('persists transcriptKey for automatically fired session-only recurring tasks', async () => {
    const store = new DaemonSessionTaskStore()
    store.addTask(projectRoot, {
      id: 'task-1',
      cron: '* * * * *',
      prompt: 'ping',
      createdAt: Date.now() - 2 * 60_000,
      recurring: true,
      originSessionId: 'session-a',
      durable: false,
    })

    const runtime = new ProjectRuntime(projectRoot, store)
    const spawnedTasks: DaemonCronTask[] = []
    ;(
      runtime as unknown as {
        spawnWorkerForTask: (task: DaemonCronTask) => Promise<boolean>
      }
    ).spawnWorkerForTask = async task => {
      spawnedTasks.push(task)
      return true
    }

    try {
      runtime.start()
      await sleep(1800)
    } finally {
      await runtime.stop()
    }

    const spawnedTask = spawnedTasks[0]
    expect(spawnedTask?.durable).toBe(false)
    expect(spawnedTask?.transcriptKey?.startsWith('cron-thread-')).toBe(true)
    expect(store.getTask(projectRoot, 'task-1')?.transcriptKey).toBe(
      spawnedTask?.transcriptKey,
    )

    const raw = await readFile(
      join(projectRoot, '.claude', 'session_scheduled_tasks.json'),
      'utf-8',
    )
    expect(raw).toContain(`"transcriptKey": "${spawnedTask?.transcriptKey}"`)
    expect(raw).not.toContain('"durable"')
  })
})

class FakeChild extends EventEmitter {
  pid = 1234
  exitCode: number | null = null
  signalCode: NodeJS.Signals | null = null
  signals: NodeJS.Signals[] = []

  kill(signal?: NodeJS.Signals): boolean {
    this.signals.push(signal ?? 'SIGTERM')
    queueMicrotask(() => {
      this.exitCode = 0
      this.emit('exit', 0)
    })
    return true
  }
}

describe('ProjectRuntime worker shutdown', () => {
  let projectRoot: string
  let payloadPath: string

  beforeEach(async () => {
    projectRoot = await mkdtemp(join(tmpdir(), 'project-runtime-stop-'))
    payloadPath = join(projectRoot, 'worker-payload.json')
    await writeFile(payloadPath, '{}', 'utf-8')
  })

  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  test('sends SIGTERM to active workers and removes payload files', async () => {
    const signals: Array<{ pid: number; signal: NodeJS.Signals }> = []
    const child = new FakeChild()
    const runtime = new ProjectRuntime(
      projectRoot,
      new DaemonSessionTaskStore(),
      async (pid, signal) => {
        signals.push({ pid, signal })
        child.kill(signal)
      },
    )
    ;(runtime as any).activeWorkers.set('task-1', {
      child,
      payloadPath,
      startedAt: Date.now(),
    })

    await runtime.stop()

    expect(signals).toEqual([{ pid: 1234, signal: 'SIGTERM' }])
    expect(child.signals).toEqual(['SIGTERM'])
    expect((runtime as any).activeWorkers.size).toBe(0)
    await expect(readFile(payloadPath, 'utf-8')).rejects.toThrow()
  })
})
