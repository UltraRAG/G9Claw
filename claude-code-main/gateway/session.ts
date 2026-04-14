/**
 * Session management for the gateway.
 *
 * Handles session tracking, SQLite persistence, reset policy evaluation,
 * and session key construction.
 *
 * Ported from hermes-agent gateway/session.py.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { join } from 'path'
import { randomUUID } from 'crypto'
import { createHash } from 'crypto'
import type {
  GatewayConfig,
  SessionEntry,
  SessionSource,
  SessionResetPolicy,
  HomeChannel,
} from './types'
import { Platform } from './types'
import { getResetPolicy } from './config'
import type { ProjectInfo } from './projects'

// ─── Per-user project selection ───

export interface UserProjectSelection {
  name: string
  path: string
  selectedAt: string
}

export interface UserProjectState {
  project: UserProjectSelection | null
  pendingSelection: boolean
  cachedProjects?: ProjectInfo[]
  /** Maps projectKey ('general' | project name) -> SDK session UUID for resume */
  sdkSessions?: Record<string, string>
}

// ─── SQLite (bun:sqlite or better-sqlite3) ───

let Database: any = null
try {
  Database = require('bun:sqlite').Database
} catch {
  try {
    Database = require('better-sqlite3')
  } catch {
    // SQLite unavailable — session persistence will use JSON only
  }
}

// ─── PII redaction helpers ───

function hashId(value: string): string {
  return createHash('sha256').update(value).digest('hex').slice(0, 12)
}

function hashSenderId(value: string): string {
  return `user_${hashId(value)}`
}

function hashChatId(value: string): string {
  const colon = value.indexOf(':')
  if (colon > 0) return `${value.slice(0, colon)}:${hashId(value.slice(colon + 1))}`
  return hashId(value)
}

const PII_SAFE_PLATFORMS = new Set([
  Platform.WHATSAPP,
  Platform.SIGNAL,
  Platform.TELEGRAM,
  Platform.BLUEBUBBLES,
])

// ─── Session key construction ───

export function buildSessionKey(
  source: SessionSource,
  groupSessionsPerUser = true,
  threadSessionsPerUser = false,
): string {
  const platform = source.platform

  if (source.chatType === 'dm') {
    if (source.chatId) {
      if (source.threadId) return `agent:main:${platform}:dm:${source.chatId}:${source.threadId}`
      return `agent:main:${platform}:dm:${source.chatId}`
    }
    if (source.threadId) return `agent:main:${platform}:dm:${source.threadId}`
    return `agent:main:${platform}:dm`
  }

  const participantId = source.userIdAlt || source.userId
  const keyParts = ['agent:main', platform, source.chatType]

  if (source.chatId) keyParts.push(source.chatId)
  if (source.threadId) keyParts.push(source.threadId)

  let isolateUser = groupSessionsPerUser
  if (source.threadId && !threadSessionsPerUser) isolateUser = false
  if (isolateUser && participantId) keyParts.push(participantId)

  return keyParts.join(':')
}

// ─── Session context prompt ───

export interface SessionContext {
  source: SessionSource
  connectedPlatforms: Platform[]
  homeChannels: Map<Platform, HomeChannel>
  sessionKey: string
  sessionId: string
  createdAt?: Date
  updatedAt?: Date
}

export function buildSessionContextPrompt(
  context: SessionContext,
  redactPii = false,
): string {
  const shouldRedact = redactPii && PII_SAFE_PLATFORMS.has(context.source.platform)
  const lines: string[] = ['## Current Session Context', '']

  const platformName =
    context.source.platform.charAt(0).toUpperCase() + context.source.platform.slice(1)

  if (context.source.platform === Platform.LOCAL) {
    lines.push(`**Source:** ${platformName} (the machine running this agent)`)
  } else {
    const src = context.source
    let desc: string
    if (shouldRedact) {
      const uname = src.userName ?? (src.userId ? hashSenderId(src.userId) : 'user')
      const cname = src.chatName ?? hashChatId(src.chatId)
      desc =
        src.chatType === 'dm'
          ? `DM with ${uname}`
          : src.chatType === 'group'
            ? `group: ${cname}`
            : `channel: ${cname}`
    } else {
      desc =
        src.chatType === 'dm'
          ? `DM with ${src.userName ?? src.userId ?? 'user'}`
          : `${src.chatType}: ${src.chatName ?? src.chatId}`
    }
    lines.push(`**Source:** ${platformName} (${desc})`)
  }

  if (context.source.chatTopic) {
    lines.push(`**Channel Topic:** ${context.source.chatTopic}`)
  }

  if (context.source.userName) {
    lines.push(`**User:** ${context.source.userName}`)
  } else if (context.source.userId) {
    const uid = shouldRedact ? hashSenderId(context.source.userId) : context.source.userId
    lines.push(`**User ID:** ${uid}`)
  }

  const platformsList = ['local (files on this machine)']
  for (const p of context.connectedPlatforms) {
    if (p !== Platform.LOCAL) platformsList.push(`${p}: Connected ✓`)
  }
  lines.push(`**Connected Platforms:** ${platformsList.join(', ')}`)

  if (context.homeChannels.size > 0) {
    lines.push('', '**Home Channels (default destinations):**')
    for (const [p, hc] of context.homeChannels) {
      const hcId = shouldRedact ? hashChatId(hc.chatId) : hc.chatId
      lines.push(`  - ${p}: ${hc.name} (ID: ${hcId})`)
    }
  }

  return lines.join('\n')
}

// ─── Session database (SQLite) ───

class SessionDB {
  private db: any

  constructor(dbPath: string) {
    if (!Database) throw new Error('SQLite not available')
    this.db = new Database(dbPath)
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        source TEXT,
        user_id TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        ended_at TEXT,
        end_reason TEXT
      );
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
      );
    `)
  }

  createSession(sessionId: string, source: string, userId?: string): void {
    this.db
      .prepare('INSERT OR IGNORE INTO sessions (session_id, source, user_id) VALUES (?, ?, ?)')
      .run(sessionId, source, userId ?? null)
  }

  endSession(sessionId: string, reason: string): void {
    this.db
      .prepare("UPDATE sessions SET ended_at = datetime('now'), end_reason = ? WHERE session_id = ?")
      .run(reason, sessionId)
  }

  addMessage(sessionId: string, role: string, content: string): void {
    this.db
      .prepare('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)')
      .run(sessionId, role, content)
  }

  getMessages(sessionId: string): Array<{ role: string; content: string; createdAt: string }> {
    return this.db
      .prepare('SELECT role, content, created_at as createdAt FROM messages WHERE session_id = ? ORDER BY id')
      .all(sessionId)
  }

  sessionCount(): number {
    return this.db.prepare('SELECT COUNT(*) as count FROM sessions').get().count
  }

  close(): void {
    this.db.close()
  }
}

// ─── Session store ───

function now(): Date {
  return new Date()
}

function generateSessionId(): string {
  const ts = new Date()
  const stamp = `${ts.getFullYear()}${String(ts.getMonth() + 1).padStart(2, '0')}${String(ts.getDate()).padStart(2, '0')}_${String(ts.getHours()).padStart(2, '0')}${String(ts.getMinutes()).padStart(2, '0')}${String(ts.getSeconds()).padStart(2, '0')}`
  return `${stamp}_${randomUUID().replace(/-/g, '').slice(0, 8)}`
}

export class SessionStore {
  private sessionsDir: string
  private config: GatewayConfig
  private entries = new Map<string, SessionEntry>()
  private loaded = false
  private db: SessionDB | null = null

  constructor(sessionsDir: string, config: GatewayConfig) {
    this.sessionsDir = sessionsDir
    this.config = config

    if (Database) {
      try {
        mkdirSync(sessionsDir, { recursive: true })
        this.db = new SessionDB(join(sessionsDir, 'sessions.db'))
      } catch (err) {
        console.warn('[gateway] SQLite session store unavailable:', err)
      }
    }
  }

  private ensureLoaded(): void {
    if (this.loaded) return
    mkdirSync(this.sessionsDir, { recursive: true })

    const sessionsFile = join(this.sessionsDir, 'sessions.json')
    if (existsSync(sessionsFile)) {
      try {
        const data = JSON.parse(readFileSync(sessionsFile, 'utf-8'))
        for (const [key, entryData] of Object.entries(data)) {
          try {
            this.entries.set(key, this.deserializeEntry(entryData as Record<string, unknown>))
          } catch {
            // Skip entries with invalid data
          }
        }
      } catch (err) {
        console.warn('[gateway] Failed to load sessions:', err)
      }
    }
    this.loaded = true
  }

  private save(): void {
    mkdirSync(this.sessionsDir, { recursive: true })
    const sessionsFile = join(this.sessionsDir, 'sessions.json')
    const data: Record<string, unknown> = {}
    for (const [key, entry] of this.entries) {
      data[key] = this.serializeEntry(entry)
    }
    writeFileSync(sessionsFile, JSON.stringify(data, null, 2), 'utf-8')
  }

  private generateSessionKey(source: SessionSource): string {
    return buildSessionKey(
      source,
      this.config.groupSessionsPerUser,
      this.config.threadSessionsPerUser,
    )
  }

  private shouldReset(entry: SessionEntry, source: SessionSource): string | null {
    const policy = getResetPolicy(this.config, source.platform, source.chatType)
    if (policy.mode === 'none') return null

    const n = now()

    if (policy.mode === 'idle' || policy.mode === 'both') {
      const deadline = new Date(entry.updatedAt.getTime() + policy.idleMinutes * 60_000)
      if (n > deadline) return 'idle'
    }

    if (policy.mode === 'daily' || policy.mode === 'both') {
      const todayReset = new Date(n)
      todayReset.setHours(policy.atHour, 0, 0, 0)
      if (n.getHours() < policy.atHour) {
        todayReset.setDate(todayReset.getDate() - 1)
      }
      if (entry.updatedAt < todayReset) return 'daily'
    }

    return null
  }

  getOrCreateSession(source: SessionSource, forceNew = false): SessionEntry {
    this.ensureLoaded()
    const sessionKey = this.generateSessionKey(source)
    const n = now()

    if (this.entries.has(sessionKey) && !forceNew) {
      const entry = this.entries.get(sessionKey)!

      let resetReason: string | null
      if (entry.suspended) {
        resetReason = 'suspended'
      } else {
        resetReason = this.shouldReset(entry, source)
      }

      if (!resetReason) {
        entry.updatedAt = n
        this.save()
        return entry
      }

      // End old session in DB
      if (this.db) {
        try { this.db.endSession(entry.sessionId, 'session_reset') } catch {}
      }
    }

    const sessionId = generateSessionId()
    const entry: SessionEntry = {
      sessionKey,
      sessionId,
      createdAt: n,
      updatedAt: n,
      origin: source,
      displayName: source.chatName,
      platform: source.platform,
      chatType: source.chatType,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      totalTokens: 0,
      lastPromptTokens: 0,
      estimatedCostUsd: 0,
      costStatus: 'unknown',
      memoryFlushed: false,
      suspended: false,
      wasAutoReset: false,
      autoResetReason: undefined,
      resetHadActivity: false,
    }

    this.entries.set(sessionKey, entry)
    this.save()

    if (this.db) {
      try {
        this.db.createSession(sessionId, source.platform, source.userId)
      } catch (err) {
        console.warn('[gateway] Failed to create SQLite session:', err)
      }
    }

    return entry
  }

  updateSession(sessionKey: string, lastPromptTokens?: number): void {
    this.ensureLoaded()
    const entry = this.entries.get(sessionKey)
    if (!entry) return
    entry.updatedAt = now()
    if (lastPromptTokens !== undefined) entry.lastPromptTokens = lastPromptTokens
    this.save()
  }

  suspendSession(sessionKey: string): boolean {
    this.ensureLoaded()
    const entry = this.entries.get(sessionKey)
    if (!entry) return false
    entry.suspended = true
    this.save()
    return true
  }

  addMessage(sessionId: string, role: string, content: string): void {
    if (this.db) {
      try { this.db.addMessage(sessionId, role, content) } catch {}
    }
  }

  getMessages(sessionId: string): Array<{ role: string; content: string }> {
    if (this.db) {
      try { return this.db.getMessages(sessionId) } catch {}
    }
    return []
  }

  getEntry(sessionKey: string): SessionEntry | undefined {
    this.ensureLoaded()
    return this.entries.get(sessionKey)
  }

  // ─── Per-user project selection ───

  private userProjects = new Map<string, UserProjectState>()
  private userProjectsLoaded = false

  private userProjectKey(userId: string | undefined, platform: Platform): string {
    return `${platform}:${userId || 'anonymous'}`
  }

  private ensureUserProjectsLoaded(): void {
    if (this.userProjectsLoaded) return
    mkdirSync(this.sessionsDir, { recursive: true })
    const filePath = join(this.sessionsDir, 'user-projects.json')
    if (existsSync(filePath)) {
      try {
        const data = JSON.parse(readFileSync(filePath, 'utf-8'))
        for (const [key, value] of Object.entries(data)) {
          const v = value as any
          this.userProjects.set(key, {
            project: v.project ?? null,
            pendingSelection: false,
            cachedProjects: undefined,
            sdkSessions: v.sdkSessions ?? {},
          })
        }
      } catch {}
    }
    this.userProjectsLoaded = true
  }

  private saveUserProjects(): void {
    mkdirSync(this.sessionsDir, { recursive: true })
    const filePath = join(this.sessionsDir, 'user-projects.json')
    const data: Record<string, unknown> = {}
    for (const [key, state] of this.userProjects) {
      data[key] = { project: state.project, sdkSessions: state.sdkSessions ?? {} }
    }
    writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8')
  }

  getUserProjectState(userId: string | undefined, platform: Platform): UserProjectState {
    this.ensureUserProjectsLoaded()
    const key = this.userProjectKey(userId, platform)
    if (!this.userProjects.has(key)) {
      this.userProjects.set(key, { project: null, pendingSelection: false })
    }
    return this.userProjects.get(key)!
  }

  setUserProject(userId: string | undefined, platform: Platform, name: string, path: string): void {
    this.ensureUserProjectsLoaded()
    const key = this.userProjectKey(userId, platform)
    const state = this.getUserProjectState(userId, platform)
    state.project = { name, path, selectedAt: new Date().toISOString() }
    state.pendingSelection = false
    state.cachedProjects = undefined
    this.userProjects.set(key, state)
    this.saveUserProjects()
  }

  clearUserProject(userId: string | undefined, platform: Platform): void {
    this.ensureUserProjectsLoaded()
    const key = this.userProjectKey(userId, platform)
    const state = this.getUserProjectState(userId, platform)
    state.project = null
    state.pendingSelection = false
    state.cachedProjects = undefined
    this.userProjects.set(key, state)
    this.saveUserProjects()
  }

  setPendingProjectSelection(userId: string | undefined, platform: Platform, pending: boolean, projects?: ProjectInfo[]): void {
    const state = this.getUserProjectState(userId, platform)
    state.pendingSelection = pending
    state.cachedProjects = pending ? projects : undefined
  }

  getSdkSessionId(userId: string | undefined, platform: Platform, projectKey: string): string | null {
    const state = this.getUserProjectState(userId, platform)
    return state.sdkSessions?.[projectKey] ?? null
  }

  setSdkSessionId(userId: string | undefined, platform: Platform, projectKey: string, sessionId: string): void {
    this.ensureUserProjectsLoaded()
    const state = this.getUserProjectState(userId, platform)
    if (!state.sdkSessions) state.sdkSessions = {}
    state.sdkSessions[projectKey] = sessionId
    this.saveUserProjects()
  }

  clearSdkSession(userId: string | undefined, platform: Platform, projectKey?: string): void {
    this.ensureUserProjectsLoaded()
    const state = this.getUserProjectState(userId, platform)
    if (!state.sdkSessions) return
    if (projectKey) {
      delete state.sdkSessions[projectKey]
    } else {
      state.sdkSessions = {}
    }
    this.saveUserProjects()
  }

  close(): void {
    if (this.db) this.db.close()
  }

  // ─── Serialization ───

  private serializeEntry(entry: SessionEntry): Record<string, unknown> {
    return {
      session_key: entry.sessionKey,
      session_id: entry.sessionId,
      created_at: entry.createdAt.toISOString(),
      updated_at: entry.updatedAt.toISOString(),
      display_name: entry.displayName,
      platform: entry.platform,
      chat_type: entry.chatType,
      input_tokens: entry.inputTokens,
      output_tokens: entry.outputTokens,
      cache_read_tokens: entry.cacheReadTokens,
      cache_write_tokens: entry.cacheWriteTokens,
      total_tokens: entry.totalTokens,
      last_prompt_tokens: entry.lastPromptTokens,
      estimated_cost_usd: entry.estimatedCostUsd,
      cost_status: entry.costStatus,
      memory_flushed: entry.memoryFlushed,
      suspended: entry.suspended,
      origin: entry.origin
        ? {
            platform: entry.origin.platform,
            chat_id: entry.origin.chatId,
            chat_name: entry.origin.chatName,
            chat_type: entry.origin.chatType,
            user_id: entry.origin.userId,
            user_name: entry.origin.userName,
            thread_id: entry.origin.threadId,
            chat_topic: entry.origin.chatTopic,
          }
        : undefined,
    }
  }

  private deserializeEntry(data: Record<string, unknown>): SessionEntry {
    let origin: SessionSource | undefined
    if (data.origin && typeof data.origin === 'object') {
      const o = data.origin as Record<string, unknown>
      origin = {
        platform: o.platform as Platform,
        chatId: String(o.chat_id ?? ''),
        chatName: o.chat_name as string | undefined,
        chatType: (o.chat_type as SessionSource['chatType']) ?? 'dm',
        userId: o.user_id as string | undefined,
        userName: o.user_name as string | undefined,
        threadId: o.thread_id as string | undefined,
        chatTopic: o.chat_topic as string | undefined,
      }
    }

    return {
      sessionKey: data.session_key as string,
      sessionId: data.session_id as string,
      createdAt: new Date(data.created_at as string),
      updatedAt: new Date(data.updated_at as string),
      origin,
      displayName: data.display_name as string | undefined,
      platform: data.platform as Platform | undefined,
      chatType: (data.chat_type as string) ?? 'dm',
      inputTokens: (data.input_tokens as number) ?? 0,
      outputTokens: (data.output_tokens as number) ?? 0,
      cacheReadTokens: (data.cache_read_tokens as number) ?? 0,
      cacheWriteTokens: (data.cache_write_tokens as number) ?? 0,
      totalTokens: (data.total_tokens as number) ?? 0,
      lastPromptTokens: (data.last_prompt_tokens as number) ?? 0,
      estimatedCostUsd: (data.estimated_cost_usd as number) ?? 0,
      costStatus: (data.cost_status as string) ?? 'unknown',
      memoryFlushed: (data.memory_flushed as boolean) ?? false,
      suspended: (data.suspended as boolean) ?? false,
      wasAutoReset: false,
      autoResetReason: undefined,
      resetHadActivity: false,
    }
  }
}
