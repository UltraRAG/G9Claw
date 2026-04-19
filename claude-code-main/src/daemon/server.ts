import net from 'net'
import { unlink } from 'fs/promises'
import { resolve } from 'path'
import { CronDaemonProjectRegistry } from './projectRegistry.js'
import { ProjectRuntime } from './projectRuntime.js'
import { DaemonSessionTaskStore } from './sessionTaskStore.js'
import { getCronDaemonSocketPath } from './paths.js'
import type { CronDaemonRequest, CronDaemonResponse, DaemonCronTask } from './types.js'
import { safeParseJSON } from '../utils/json.js'
import { logForDebugging } from '../utils/debug.js'
import { addCronTask, readCronTasks, removeCronTasks } from '../utils/cronTasks.js'

export class CronDaemonServer {
  private readonly server = net.createServer(socket =>
    this.handleConnection(socket).catch(error => {
      const response: CronDaemonResponse = {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }
      socket.end(JSON.stringify(response) + '\n')
    }),
  )
  private readonly runtimes = new Map<string, ProjectRuntime>()
  private readonly sessionTaskStore = new DaemonSessionTaskStore()
  private readonly registry = new CronDaemonProjectRegistry()
  private stopping = false

  async start(): Promise<void> {
    await this.registry.load()
    for (const projectRoot of this.registry.list()) {
      this.getOrCreateRuntime(projectRoot).start()
    }

    const socketPath = getCronDaemonSocketPath()
    await unlink(socketPath).catch(() => {})

    await new Promise<void>((resolvePromise, reject) => {
      this.server.once('error', reject)
      this.server.listen(socketPath, () => {
        this.server.off('error', reject)
        resolvePromise()
      })
    })

    logForDebugging(`[CronDaemon] listening on ${socketPath}`)
  }

  async stop(): Promise<void> {
    if (this.stopping) return
    this.stopping = true
    for (const runtime of this.runtimes.values()) {
      runtime.stop()
    }
    await new Promise<void>(resolvePromise => {
      this.server.close(() => resolvePromise())
    })
    await unlink(getCronDaemonSocketPath()).catch(() => {})
  }

  private async handleConnection(socket: net.Socket): Promise<void> {
    let buffer = ''
    socket.on('data', chunk => {
      buffer += chunk.toString('utf-8')
      const newlineIndex = buffer.indexOf('\n')
      if (newlineIndex === -1) return
      const line = buffer.slice(0, newlineIndex)
      buffer = buffer.slice(newlineIndex + 1)
      void this.dispatchLine(line, socket)
    })
  }

  private async dispatchLine(line: string, socket: net.Socket): Promise<void> {
    const parsed = safeParseJSON(line, false) as CronDaemonRequest | null
    if (!parsed || typeof parsed !== 'object' || !('type' in parsed)) {
      socket.end(
        JSON.stringify({ ok: false, error: 'Invalid Cron daemon request' }) +
          '\n',
      )
      return
    }

    const response = await this.handleRequest(parsed)
    socket.end(JSON.stringify(response) + '\n')
    if (parsed.type === 'shutdown' && response.ok) {
      setTimeout(() => {
        void this.stop()
      }, 0)
    }
  }

  private async handleRequest(
    request: CronDaemonRequest,
  ): Promise<CronDaemonResponse> {
    try {
      switch (request.type) {
        case 'ping': {
          const runtimes = await Promise.all(
            [...this.runtimes.values()].map(runtime => runtime.summarize()),
          )
          return { ok: true, data: { type: 'pong', runtimes } }
        }
        case 'shutdown':
          return { ok: true, data: { type: 'shutdown' } }
        case 'create_task': {
          const projectRoot = await this.ensureRuntime(request.projectRoot)
          let createdSessionTask: DaemonCronTask | null = null
          const id = await addCronTask(
            request.cron,
            request.prompt,
            request.recurring,
            request.durable,
            request.agentId,
            {
              dir: projectRoot,
              originSessionId: request.originSessionId,
              addSessionTask: task => {
                createdSessionTask = this.sessionTaskStore.addTask(projectRoot, {
                  ...task,
                  durable: false,
                })
              },
            },
          )

          const task = request.durable
            ? (await readCronTasks(projectRoot).then(tasks =>
                tasks.find(candidate => candidate.id === id),
              ))
            : createdSessionTask

          if (!task) {
            throw new Error(`Failed to create cron task ${id}`)
          }

          return {
            ok: true,
            data: {
              type: 'create_task',
              task: {
                ...task,
                durable: request.durable,
              },
            },
          }
        }
        case 'list_tasks': {
          const projectRoot = await this.ensureRuntime(request.projectRoot)
          const durableTasks = (await readCronTasks(projectRoot)).map(task => ({
            ...task,
            durable: true as const,
          }))
          const sessionTasks = this.sessionTaskStore.listVisibleTasks(
            projectRoot,
            request.originSessionId,
          )
          return {
            ok: true,
            data: {
              type: 'list_tasks',
              tasks: [...durableTasks, ...sessionTasks],
            },
          }
        }
        case 'delete_task': {
          const projectRoot = await this.ensureRuntime(request.projectRoot)
          const deletedSessionTask = this.sessionTaskStore.deleteTask(
            projectRoot,
            request.taskId,
            request.originSessionId,
          )
          if (deletedSessionTask) {
            return {
              ok: true,
              data: { type: 'delete_task', deleted: true },
            }
          }

          const durableTasks = await readCronTasks(projectRoot)
          const exists = durableTasks.some(task => task.id === request.taskId)
          if (exists) {
            await removeCronTasks([request.taskId], projectRoot)
          }
          return {
            ok: true,
            data: { type: 'delete_task', deleted: exists },
          }
        }
      }
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  private async ensureRuntime(projectRoot: string): Promise<string> {
    const normalized = resolve(projectRoot)
    await this.registry.remember(normalized)
    this.getOrCreateRuntime(normalized).start()
    return normalized
  }

  private getOrCreateRuntime(projectRoot: string): ProjectRuntime {
    const normalized = resolve(projectRoot)
    let runtime = this.runtimes.get(normalized)
    if (!runtime) {
      runtime = new ProjectRuntime(normalized, this.sessionTaskStore)
      this.runtimes.set(normalized, runtime)
    }
    return runtime
  }
}
