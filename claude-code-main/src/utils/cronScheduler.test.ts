import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { persistFiredRecurringTasks } from './cronScheduler.js'
import { readCronTasks, updateCronTask, writeCronTasks } from './cronTasks.js'
import { sleep } from './sleep.js'

describe('persistFiredRecurringTasks', () => {
  let dir: string

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'cron-scheduler-'))
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  test('waits for recurring transcript persistence before stamping lastFiredAt', async () => {
    const taskId = 'deadbeef'
    const createdAt = Date.now() - 5 * 60_000
    const firedAt = Date.now()

    await writeCronTasks(
      [
        {
          id: taskId,
          cron: '* * * * *',
          prompt: 'ping',
          createdAt,
          recurring: true,
          originSessionId: 'session-1',
        },
      ],
      dir,
    )

    const pendingTranscriptWrite = (async () => {
      await sleep(10)
      await updateCronTask(
        taskId,
        task => ({
          ...task,
          transcriptKey: 'cron-thread-123',
        }),
        dir,
      )
    })()

    await persistFiredRecurringTasks(
      [taskId],
      firedAt,
      [pendingTranscriptWrite],
      dir,
      async (ids, firedAtMs, targetDir) => {
        const tasks = await readCronTasks(targetDir)
        await sleep(25)
        for (const task of tasks) {
          if (ids.includes(task.id)) {
            task.lastFiredAt = firedAtMs
          }
        }
        await writeCronTasks(tasks, targetDir)
      },
    )

    await expect(readCronTasks(dir)).resolves.toContainEqual({
      id: taskId,
      cron: '* * * * *',
      prompt: 'ping',
      createdAt,
      recurring: true,
      originSessionId: 'session-1',
      transcriptKey: 'cron-thread-123',
      lastFiredAt: firedAt,
    })
  })
})
