import { randomUUID } from 'crypto'
import { mkdir, rm, writeFile } from 'fs/promises'
import { spawn } from 'child_process'
import { resolve } from 'path'
import {
  createCronScheduler,
  type CronScheduler,
  buildMissedTaskNotification,
} from '../utils/cronScheduler.js'
import { readCronTasks, updateCronTask, type CronTask } from '../utils/cronTasks.js'
import { logForDebugging } from '../utils/debug.js'
import { logError } from '../utils/log.js'
import { jsonStringify } from '../utils/slowOperations.js'
import { generateCronId } from '../tasks/CronBackgroundTask.js'
import { getCronDaemonWorkerPayloadDir, getCronDaemonWorkerPayloadPath } from './paths.js'
import { getDaemonWorkerCommandArgs } from './spawn.js'
import { DaemonSessionTaskStore } from './sessionTaskStore.js'
import type { CronWorkerPayload, DaemonCronTask, RuntimeSummary } from './types.js'

type ActiveWorker = {
  child: ReturnType<typeof spawn>
  payloadPath: string
  startedAt: number
}

const WORKER_SHUTDOWN_GRACE_MS = 5_000

export async function terminateProcessTree(
  pid: number,
  signal: NodeJS.Signals,
): Promise<void> {
  try {
    process.kill(-pid, signal)
  } catch (error) {
    try {
      process.kill(pid, signal)
    } catch {
      throw error
    }
  }
}

export class ProjectRuntime {
  readonly projectRoot: string
  private readonly scheduler: CronScheduler
  private readonly activeWorkers = new Map<string, ActiveWorker>()
  private started = false

  constructor(
    projectRoot: string,
    private readonly sessionTaskStore: DaemonSessionTaskStore,
    private readonly terminateWorkerTree = terminateProcessTree,
  ) {
    this.projectRoot = resolve(projectRoot)
    this.scheduler = createCronScheduler({
      dir: this.projectRoot,
      lockIdentity: `cron-daemon:${process.pid}:${this.projectRoot}`,
      runtimeTaskSource: {
        listTasks: () => this.sessionTaskStore.listProjectTasks(this.projectRoot),
        removeTasks: ids => {
          let deletedAny = false
          for (const id of ids) {
            deletedAny =
              this.sessionTaskStore.deleteTask(this.projectRoot, id) || deletedAny
          }
          if (deletedAny) {
            void this.sessionTaskStore.persistProject(this.projectRoot).catch(logError)
          }
        },
        markTasksFired: (ids, firedAt) => {
          let updatedAny = false
          for (const id of ids) {
            updatedAny =
              this.sessionTaskStore.markTaskFired(this.projectRoot, id, firedAt) ||
              updatedAny
          }
          if (updatedAny) {
            void this.sessionTaskStore.persistProject(this.projectRoot).catch(logError)
          }
        },
      },
      onFire: prompt => {
        void this.handleMissedPrompt(prompt)
      },
      onMissed: tasks => {
        void this.handleMissedTasks(tasks)
      },
      onFireTask: (task, context) => {
        return this.handleScheduledTask({
          ...task,
          durable: !context.isSession,
        }).catch(error => {
          logForDebugging(
            `[CronDaemon] failed to start scheduled task ${task.id}: ${String(error)}`,
          )
        })
      },
    })
  }

  start(): void {
    if (this.started) return
    this.started = true
    this.scheduler.start()
  }

  async stop(): Promise<void> {
    if (!this.started && this.activeWorkers.size === 0) return
    this.started = false
    this.scheduler.stop()
    await this.stopActiveWorkers()
  }

  async summarize(): Promise<RuntimeSummary> {
    const durableCount = (await readCronTasks(this.projectRoot)).length
    return {
      projectRoot: this.projectRoot,
      durableCount,
      sessionOnlyCount: this.sessionTaskStore.countForProject(this.projectRoot),
      activeWorkers: this.activeWorkers.size,
    }
  }

  isTaskRunning(taskId: string): boolean {
    return this.activeWorkers.has(taskId)
  }

  private async handleMissedTasks(tasks: CronTask[]): Promise<void> {
    if (tasks.length === 0) return
    await this.handleMissedPrompt(buildMissedTaskNotification(tasks), tasks[0])
  }

  private async handleMissedPrompt(
    prompt: string,
    exemplarTask?: Pick<CronTask, 'originSessionId'>,
  ): Promise<void> {
    const syntheticTask: DaemonCronTask = {
      id: generateCronId('cron-missed'),
      cron: '* * * * *',
      prompt,
      createdAt: Date.now(),
      originSessionId: exemplarTask?.originSessionId ?? randomUUID(),
      durable: false,
    }
    await this.spawnWorkerForTask(syntheticTask)
  }

  async launchSessionTask(task: DaemonCronTask): Promise<boolean> {
    return await this.spawnWorkerForTask(await this.prepareTask(task))
  }

  private async handleScheduledTask(task: DaemonCronTask): Promise<void> {
    await this.spawnWorkerForTask(await this.prepareTask(task))
  }

  private async prepareTask(task: DaemonCronTask): Promise<DaemonCronTask> {
    if (!task.recurring || task.transcriptKey) {
      return task
    }

    const transcriptKey = generateCronId('cron-thread')
    const originSessionId = task.originSessionId ?? randomUUID()

    if (task.durable) {
      const updated =
        (await updateCronTask(
          task.id,
          currentTask => ({
            ...currentTask,
            transcriptKey,
            originSessionId: currentTask.originSessionId ?? originSessionId,
          }),
          this.projectRoot,
        )) ?? {
          ...task,
          transcriptKey,
          originSessionId,
        }

      return {
        ...updated,
        durable: true,
      }
    }

    const updated =
      this.sessionTaskStore.updateTask(this.projectRoot, task.id, currentTask => ({
        ...currentTask,
        transcriptKey,
        originSessionId: currentTask.originSessionId ?? originSessionId,
      })) ?? {
        ...task,
        transcriptKey,
        originSessionId,
        durable: false,
      }

    if (updated) {
      await this.sessionTaskStore.persistProject(this.projectRoot)
    }

    return updated
  }

  private async spawnWorkerForTask(task: DaemonCronTask): Promise<boolean> {
    if (this.activeWorkers.has(task.id)) {
      logForDebugging(
        `[CronDaemon] skipping ${task.id}: worker already active for ${this.projectRoot}`,
      )
      return false
    }

    const workerId = randomUUID()
    await mkdir(getCronDaemonWorkerPayloadDir(), { recursive: true })
    const payloadPath = getCronDaemonWorkerPayloadPath(workerId)
    const payload: CronWorkerPayload = {
      projectRoot: this.projectRoot,
      task,
    }
    await writeFile(payloadPath, jsonStringify(payload), 'utf-8')

    const child = spawn(process.execPath, getDaemonWorkerCommandArgs(`cron:${payloadPath}`), {
      cwd: this.projectRoot,
      env: process.env,
      detached: true,
      stdio: ['ignore', 'ignore', 'pipe'],
    })

    const cleanupWorker = () => {
      const current = this.activeWorkers.get(task.id)
      if (current?.child === child) {
        this.activeWorkers.delete(task.id)
      }
      void rm(payloadPath, { force: true }).catch(() => {})
    }

    this.activeWorkers.set(task.id, {
      child,
      payloadPath,
      startedAt: Date.now(),
    })

    child.stderr?.on('data', chunk => {
      logForDebugging(
        `[CronDaemonWorker:${task.id}] ${chunk.toString('utf-8').trim()}`,
      )
    })

    child.on('error', error => {
      cleanupWorker()
      logError(error)
    })

    child.on('exit', code => {
      cleanupWorker()
      if (code !== 0) {
        logForDebugging(
          `[CronDaemon] worker for ${task.id} exited with code ${code ?? 'unknown'}`,
        )
      }
    })

    return true
  }

  private async stopActiveWorkers(): Promise<void> {
    const workers = [...this.activeWorkers.entries()]
    await Promise.all(
      workers.map(async ([taskId, worker]) => {
        await new Promise<void>(resolvePromise => {
          const { child, payloadPath } = worker
          const sendSignal = async (signal: NodeJS.Signals) => {
            if (typeof child.pid === 'number') {
              await this.terminateWorkerTree(child.pid, signal)
              return
            }
            if (!child.kill(signal)) {
              throw new Error(`Failed to send ${signal} to cron worker ${taskId}`)
            }
          }
          const cleanup = async () => {
            const current = this.activeWorkers.get(taskId)
            if (current?.child === child) {
              this.activeWorkers.delete(taskId)
            }
            await rm(payloadPath, { force: true }).catch(() => {})
          }

          if (child.exitCode !== null || child.signalCode !== null) {
            void cleanup().then(resolvePromise)
            return
          }

          let settled = false
          const finish = async () => {
            if (settled) return
            settled = true
            clearTimeout(forceKillTimer)
            await cleanup()
            resolvePromise()
          }

          const forceKillTimer = setTimeout(() => {
            if (child.exitCode === null && child.signalCode === null) {
              void sendSignal('SIGKILL').catch(error => {
                logForDebugging(
                  `[CronDaemon] failed to SIGKILL worker tree for ${taskId}: ${String(error)}`,
                )
              })
            }
          }, WORKER_SHUTDOWN_GRACE_MS)
          forceKillTimer.unref()

          child.once('exit', () => void finish())
          child.once('error', () => void finish())
          void sendSignal('SIGTERM').catch(error => {
            logForDebugging(
              `[CronDaemon] failed to SIGTERM worker tree for ${taskId}: ${String(error)}`,
            )
            void finish()
          })
        })
      }),
    )
  }
}
