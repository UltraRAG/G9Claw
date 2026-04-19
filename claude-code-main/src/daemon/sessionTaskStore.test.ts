import { describe, expect, test } from 'bun:test'
import { DaemonSessionTaskStore } from './sessionTaskStore.js'
import type { DaemonCronTask } from './types.js'

function createTask(
  overrides: Partial<DaemonCronTask> = {},
): DaemonCronTask {
  return {
    id: 'task-1',
    cron: '*/5 * * * *',
    prompt: 'ping',
    createdAt: 1,
    originSessionId: 'session-a',
    durable: false,
    ...overrides,
  }
}

describe('DaemonSessionTaskStore', () => {
  test('scopes visibility by origin session id', () => {
    const store = new DaemonSessionTaskStore()
    store.addTask('/tmp/project', createTask())
    store.addTask(
      '/tmp/project',
      createTask({ id: 'task-2', originSessionId: 'session-b' }),
    )

    expect(store.listProjectTasks('/tmp/project')).toHaveLength(2)
    expect(store.listVisibleTasks('/tmp/project', 'session-a')).toHaveLength(1)
    expect(store.listVisibleTasks('/tmp/project', 'session-a')[0]?.id).toBe(
      'task-1',
    )
  })

  test('updates and deletes session-only tasks in place', () => {
    const store = new DaemonSessionTaskStore()
    store.addTask('/tmp/project', createTask())

    const updated = store.updateTask('/tmp/project', 'task-1', task => ({
      ...task,
      transcriptKey: 'cron-thread-1',
      lastRunTaskId: 'cron-run-1',
    }))

    expect(updated?.transcriptKey).toBe('cron-thread-1')
    expect(updated?.lastRunTaskId).toBe('cron-run-1')
    expect(store.deleteTask('/tmp/project', 'task-1', 'session-a')).toBe(true)
    expect(store.listProjectTasks('/tmp/project')).toHaveLength(0)
  })
})
