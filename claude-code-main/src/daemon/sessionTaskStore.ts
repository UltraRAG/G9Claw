import { resolve } from 'path'
import type { DaemonCronTask } from './types.js'

export class DaemonSessionTaskStore {
  private readonly tasksByProject = new Map<string, Map<string, DaemonCronTask>>()

  private normalizeProjectRoot(projectRoot: string): string {
    return resolve(projectRoot)
  }

  private getProjectTasks(projectRoot: string): Map<string, DaemonCronTask> {
    const normalized = this.normalizeProjectRoot(projectRoot)
    let tasks = this.tasksByProject.get(normalized)
    if (!tasks) {
      tasks = new Map()
      this.tasksByProject.set(normalized, tasks)
    }
    return tasks
  }

  addTask(projectRoot: string, task: DaemonCronTask): DaemonCronTask {
    const tasks = this.getProjectTasks(projectRoot)
    tasks.set(task.id, { ...task, durable: false })
    return tasks.get(task.id)!
  }

  listProjectTasks(projectRoot: string): DaemonCronTask[] {
    return [...this.getProjectTasks(projectRoot).values()]
  }

  listVisibleTasks(
    projectRoot: string,
    originSessionId?: string,
  ): DaemonCronTask[] {
    const tasks = this.listProjectTasks(projectRoot)
    if (!originSessionId) {
      return tasks
    }
    return tasks.filter(task => task.originSessionId === originSessionId)
  }

  getTask(projectRoot: string, taskId: string): DaemonCronTask | null {
    return this.getProjectTasks(projectRoot).get(taskId) ?? null
  }

  updateTask(
    projectRoot: string,
    taskId: string,
    updater: (task: DaemonCronTask) => DaemonCronTask,
  ): DaemonCronTask | null {
    const tasks = this.getProjectTasks(projectRoot)
    const existing = tasks.get(taskId)
    if (!existing) return null
    const updated = { ...updater(existing), durable: false as const }
    tasks.set(taskId, updated)
    return updated
  }

  deleteTask(
    projectRoot: string,
    taskId: string,
    originSessionId?: string,
  ): boolean {
    const normalized = this.normalizeProjectRoot(projectRoot)
    const tasks = this.tasksByProject.get(normalized)
    if (!tasks) return false
    const task = tasks.get(taskId)
    if (!task) return false
    if (originSessionId && task.originSessionId !== originSessionId) {
      return false
    }
    const deleted = tasks.delete(taskId)
    if (tasks.size === 0) {
      this.tasksByProject.delete(normalized)
    }
    return deleted
  }

  countForProject(projectRoot: string): number {
    return this.getProjectTasks(projectRoot).size
  }
}
