import type { CronTask } from '../utils/cronTasks.js'

export type DaemonCronTask = CronTask & {
  durable: boolean
}

export type CronDaemonRequest =
  | {
      type: 'ping'
    }
  | {
      type: 'shutdown'
    }
  | {
      type: 'create_task'
      projectRoot: string
      originSessionId: string
      cron: string
      prompt: string
      recurring: boolean
      durable: boolean
      agentId?: string
    }
  | {
      type: 'list_tasks'
      projectRoot: string
      originSessionId?: string
    }
  | {
      type: 'delete_task'
      projectRoot: string
      taskId: string
      originSessionId?: string
    }

export type RuntimeSummary = {
  projectRoot: string
  durableCount: number
  sessionOnlyCount: number
  activeWorkers: number
}

export type CronDaemonResponse =
  | {
      ok: true
      data:
        | { type: 'pong'; runtimes: RuntimeSummary[] }
        | { type: 'shutdown' }
        | { type: 'create_task'; task: DaemonCronTask }
        | { type: 'list_tasks'; tasks: DaemonCronTask[] }
        | { type: 'delete_task'; deleted: boolean }
    }
  | {
      ok: false
      error: string
    }

export type CronWorkerPayload = {
  projectRoot: string
  task: DaemonCronTask
}
