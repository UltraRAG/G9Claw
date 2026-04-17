import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import {
  type CaseTraceRecord,
  type DashboardOverview,
  type DreamPipelineStatus,
  type DreamTraceRecord,
  type IndexTraceRecord,
  type IndexingSettings,
  type L0SessionRecord,
  MEMORY_EXPORT_FORMAT_VERSION,
  type MemoryExportBundle,
  type MemoryEntryEditFields,
  type MemoryFileRecord,
  type MemoryImportResult,
  type MemoryImportableBundle,
  type MemoryManifestEntry,
  type MemoryMessage,
  type MemorySnapshotFileRecord,
  type MemoryTransferCounts,
  type MemoryUiSnapshot,
} from "../types.js";
import { FileMemoryStore, type FileMemoryStoreOptions } from "../file-memory.js";
import { hashText, nowIso } from "../utils/id.js";

interface SqlStatement {
  all(...params: unknown[]): unknown[];
  get(...params: unknown[]): unknown;
  run(...params: unknown[]): unknown;
}

interface SqlDatabase {
  exec(sql: string): void;
  prepare(sql: string): SqlStatement;
  close(): void;
}

type DbRow = Record<string, unknown>;

const INDEXING_SETTINGS_STATE_KEY = "indexingSettings" as const;
const LAST_INDEXED_AT_STATE_KEY = "lastIndexedAt" as const;
const LAST_DREAM_AT_STATE_KEY = "lastDreamAt" as const;
const LAST_DREAM_STATUS_STATE_KEY = "lastDreamStatus" as const;
const LAST_DREAM_SUMMARY_STATE_KEY = "lastDreamSummary" as const;
const RECENT_CASE_TRACES_STATE_KEY = "recentCaseTraces" as const;
const RECENT_INDEX_TRACES_STATE_KEY = "recentIndexTraces" as const;
const RECENT_DREAM_TRACES_STATE_KEY = "recentDreamTraces" as const;
const GLOBAL_MEMORY_PREFIX = "global/";
const GLOBAL_USER_PROFILE_RELATIVE_PATH = "UserIdentity/user-profile.md";
const GLOBAL_USER_NOTES_RELATIVE_DIR = "UserIdentityNotes";

export class MemoryBundleValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MemoryBundleValidationError";
  }
}

export interface ClearMemoryResult {
  cleared: {
    l0Sessions: number;
    pipelineState: number;
    memoryFiles: number;
    projectMetas: number;
  };
  clearedAt: string;
}

export interface RepairMemoryResult {
  inspected: number;
  updated: number;
  removed: number;
  rebuilt: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseJson<T>(raw: string, fallback: T): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function normalizeString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function normalizeMessages(value: unknown): MemoryMessage[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is Record<string, unknown> => isRecord(item))
    .map((item) => ({
      ...(typeof item.msgId === "string" && item.msgId.trim() ? { msgId: item.msgId } : {}),
      role: typeof item.role === "string" && item.role.trim() ? item.role : "user",
      content: typeof item.content === "string" ? item.content : "",
    }));
}

function normalizeL0Row(row: DbRow): L0SessionRecord {
  return {
    l0IndexId: String(row.l0_index_id),
    sessionKey: String(row.session_key),
    timestamp: String(row.timestamp),
    messages: normalizeMessages(parseJson(String(row.messages_json ?? "[]"), [])),
    source: String(row.source ?? ""),
    indexed: Boolean(row.indexed),
    createdAt: String(row.created_at),
  };
}

function sanitizeTraceArray<T extends object>(
  value: unknown,
  key: keyof T & string,
  sortKey: keyof T & string,
): T[] {
  if (!Array.isArray(value)) return [];
  const sorted = value
    .filter((item): item is T => {
      if (!isRecord(item)) return false;
      const keyed = item as Record<string, unknown>;
      return typeof keyed[key] === "string" && typeof keyed[sortKey] === "string";
    })
    .sort((left, right) => {
      const rightValue = (right as Record<string, unknown>)[sortKey];
      const leftValue = (left as Record<string, unknown>)[sortKey];
      return String(rightValue).localeCompare(String(leftValue));
    });
  const seen = new Set<string>();
  const next: T[] = [];
  for (const item of sorted) {
    const id = String((item as Record<string, unknown>)[key]);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    next.push(item);
  }
  return next;
}

function normalizeIndexTraceRecord(record: IndexTraceRecord): IndexTraceRecord {
  const isNoOp = typeof record.isNoOp === "boolean"
    ? record.isNoOp
    : record.status === "completed" && record.storedResults.length === 0;
  const displayStatus = typeof record.displayStatus === "string" && record.displayStatus.trim()
    ? record.displayStatus
    : record.status === "error"
      ? "Error"
      : isNoOp
        ? "No-op"
        : record.status === "running"
          ? "Running"
          : "Completed";
  return {
    ...record,
    isNoOp,
    displayStatus,
  };
}

function normalizeDreamTraceRecord(record: DreamTraceRecord): DreamTraceRecord {
  const isNoOp = typeof record.isNoOp === "boolean"
    ? record.isNoOp
    : record.status !== "error"
      && record.outcome.deletedFiles === 0
      && record.outcome.rewrittenProjects === 0
      && !record.outcome.profileUpdated;
  const displayStatus = typeof record.displayStatus === "string" && record.displayStatus.trim()
    ? record.displayStatus
    : record.status === "error"
      ? "Error"
      : isNoOp
        ? "No-op"
        : record.status === "running"
          ? "Running"
          : "Completed";
  return {
    ...record,
    isNoOp,
    displayStatus,
  };
}

function sanitizeDreamStatus(value: unknown): DreamPipelineStatus | undefined {
  return value === "running" || value === "success" || value === "skipped" || value === "failed"
    ? value
    : undefined;
}

function clampInt(value: unknown, fallback: number, min: number, max: number): number {
  const numeric = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
      ? Number.parseInt(value, 10)
      : Number.NaN;
  if (!Number.isFinite(numeric)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(numeric)));
}

function sanitizeIndexingSettings(input: unknown, defaults: IndexingSettings): IndexingSettings {
  const record = isRecord(input) ? input : {};
  return {
    reasoningMode: record.reasoningMode === "accuracy_first" ? "accuracy_first" : defaults.reasoningMode,
    autoIndexIntervalMinutes: clampInt(record.autoIndexIntervalMinutes, defaults.autoIndexIntervalMinutes, 0, 10_080),
    autoDreamIntervalMinutes: clampInt(record.autoDreamIntervalMinutes, defaults.autoDreamIntervalMinutes, 0, 10_080),
  };
}

function normalizeSnapshotRelativePath(value: unknown, index: number): string {
  const raw = normalizeString(value).trim().replace(/\\/g, "/");
  if (!raw) {
    throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
  }
  if (isAbsolute(raw)) {
    throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
  }
  const segments = raw.split("/").filter(Boolean);
  if (
    segments.length === 0
    || segments.some((segment) => segment === "." || segment === "..")
  ) {
    throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
  }
  return segments.join("/");
}

function normalizeSnapshotFileRecord(value: unknown, index: number): MemorySnapshotFileRecord {
  if (!isRecord(value)) throw new MemoryBundleValidationError(`Invalid files[${index}]`);
  if (typeof value.content !== "string") {
    throw new MemoryBundleValidationError(`Invalid files[${index}].content`);
  }
  return {
    relativePath: normalizeSnapshotRelativePath(value.relativePath, index),
    content: value.content,
  };
}

function hasLegacyMultiProjectPath(relativePath: string): boolean {
  return relativePath.startsWith("projects/")
    || relativePath.includes("/project.meta.md");
}

function normalizeMemoryBundle(value: unknown): MemoryImportableBundle {
  if (!isRecord(value)) throw new MemoryBundleValidationError("Invalid memory bundle");
  const metadata = {
    exportedAt: normalizeString(value.exportedAt).trim() || nowIso(),
    ...(typeof value.lastIndexedAt === "string" && value.lastIndexedAt.trim() ? { lastIndexedAt: value.lastIndexedAt.trim() } : {}),
    ...(typeof value.lastDreamAt === "string" && value.lastDreamAt.trim() ? { lastDreamAt: value.lastDreamAt.trim() } : {}),
    ...(sanitizeDreamStatus(value.lastDreamStatus) ? { lastDreamStatus: sanitizeDreamStatus(value.lastDreamStatus)! } : {}),
    ...(typeof value.lastDreamSummary === "string" && value.lastDreamSummary.trim()
      ? { lastDreamSummary: value.lastDreamSummary.trim() }
      : {}),
    ...(sanitizeTraceArray<CaseTraceRecord>(value.recentCaseTraces, "caseId", "startedAt").length > 0
      ? { recentCaseTraces: sanitizeTraceArray<CaseTraceRecord>(value.recentCaseTraces, "caseId", "startedAt") }
      : {}),
    ...(sanitizeTraceArray<IndexTraceRecord>(value.recentIndexTraces, "indexTraceId", "startedAt").length > 0
      ? { recentIndexTraces: sanitizeTraceArray<IndexTraceRecord>(value.recentIndexTraces, "indexTraceId", "startedAt") }
      : {}),
    ...(sanitizeTraceArray<DreamTraceRecord>(value.recentDreamTraces, "dreamTraceId", "startedAt").length > 0
      ? { recentDreamTraces: sanitizeTraceArray<DreamTraceRecord>(value.recentDreamTraces, "dreamTraceId", "startedAt") }
      : {}),
  };
  if (value.formatVersion === MEMORY_EXPORT_FORMAT_VERSION) {
    if (!Array.isArray(value.files)) {
      throw new MemoryBundleValidationError("Invalid memory snapshot bundle files");
    }
    const files = value.files.map((item, index) => normalizeSnapshotFileRecord(item, index));
    const seenPaths = new Set<string>();
    for (const record of files) {
      if (seenPaths.has(record.relativePath)) {
        throw new MemoryBundleValidationError(`Duplicate imported snapshot file path: ${record.relativePath}`);
      }
      seenPaths.add(record.relativePath);
      if (hasLegacyMultiProjectPath(record.relativePath)) {
        throw new MemoryBundleValidationError(
          "Legacy multi-project memory bundles are not supported in current-project memory mode",
        );
      }
    }
    return {
      formatVersion: MEMORY_EXPORT_FORMAT_VERSION,
      ...metadata,
      files,
    };
  }
  throw new MemoryBundleValidationError(
    `Unsupported memory bundle formatVersion. Expected ${MEMORY_EXPORT_FORMAT_VERSION}.`,
  );
}

function isPathWithinRoot(rootDir: string, targetPath: string): boolean {
  const rel = relative(resolve(rootDir), resolve(targetPath));
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function normalizeRelativePath(relativePath: string): string {
  return relativePath.replace(/\\/g, "/");
}

function isGlobalRelativePath(relativePath: string): boolean {
  return normalizeRelativePath(relativePath).startsWith(GLOBAL_MEMORY_PREFIX);
}

function toExposedGlobalRelativePath(relativePath: string): string {
  const normalized = normalizeRelativePath(relativePath);
  return normalized.startsWith(GLOBAL_MEMORY_PREFIX)
    ? normalized
    : `${GLOBAL_MEMORY_PREFIX}${normalized}`;
}

function toInternalGlobalRelativePath(relativePath: string): string {
  const normalized = normalizeRelativePath(relativePath);
  return normalized.startsWith(GLOBAL_MEMORY_PREFIX)
    ? normalized.slice(GLOBAL_MEMORY_PREFIX.length)
    : normalized;
}

function sortManifestEntries(entries: MemoryManifestEntry[]): MemoryManifestEntry[] {
  return [...entries].sort((left, right) => {
    if (right.updatedAt !== left.updatedAt) return right.updatedAt.localeCompare(left.updatedAt);
    return left.relativePath.localeCompare(right.relativePath);
  });
}

async function loadSqlDatabaseFactory(): Promise<(dbPath: string) => SqlDatabase> {
  if (typeof (globalThis as { Bun?: unknown }).Bun !== "undefined") {
    const bunSqliteModuleName = "bun:sqlite";
    const bunSqlite = await import(bunSqliteModuleName) as {
      Database: new (path: string, options?: { create?: boolean }) => {
        exec(sql: string): void;
        query(sql: string): SqlStatement;
        close(): void;
      };
    };
    return (dbPath: string) => {
      const db = new bunSqlite.Database(dbPath, { create: true });
      return {
        exec: (sql: string) => db.exec(sql),
        prepare: (sql: string) => db.query(sql),
        close: () => db.close(),
      };
    };
  }

  const nodeSqlite = await import("node:sqlite");
  return (dbPath: string) => {
    const db = new nodeSqlite.DatabaseSync(dbPath);
    return {
      exec: (sql: string) => db.exec(sql),
      prepare: (sql: string) => db.prepare(sql),
      close: () => db.close(),
    };
  };
}

const createSqlDatabase = await loadSqlDatabaseFactory();

function createSiblingTempPath(targetDir: string, label: string): string {
  const parentDir = dirname(targetDir);
  return join(
    parentDir,
    `.${basename(targetDir)}.${label}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
  );
}

export class MemoryRepository {
  private readonly db: SqlDatabase;
  private readonly workspaceMemory: FileMemoryStore;
  private readonly globalUserMemory: FileMemoryStore;

  constructor(
    dbPath: string,
    options: {
      memoryDir?: string;
      globalRootDir?: string;
    } = {},
  ) {
    mkdirSync(dirname(dbPath), { recursive: true });
    const memoryDir = options.memoryDir ?? join(dirname(dbPath), "memory");
    const globalRootDir = options.globalRootDir ?? join(dirname(dirname(memoryDir)), "global");
    mkdirSync(memoryDir, { recursive: true });
    mkdirSync(globalRootDir, { recursive: true });
    this.db = createSqlDatabase(dbPath);
    this.globalUserMemory = new FileMemoryStore(globalRootDir, {
      manageProjectMeta: false,
      manageProjectFiles: false,
      manageUserProfile: true,
      userProfileRelativePath: GLOBAL_USER_PROFILE_RELATIVE_PATH,
      userNotesRelativeDir: GLOBAL_USER_NOTES_RELATIVE_DIR,
      appendOnlyUserEntries: true,
      enableManifest: false,
    });
    this.workspaceMemory = new FileMemoryStore(memoryDir, {
      manageProjectMeta: true,
      manageProjectFiles: true,
      manageUserProfile: false,
      enableManifest: true,
      manifestUserEntriesProvider: () => this.listGlobalMemoryEntries(),
    });
    this.init();
  }

  private init(): void {
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS l0_sessions (
        l0_index_id TEXT PRIMARY KEY,
        session_key TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        messages_json TEXT NOT NULL,
        source TEXT NOT NULL,
        indexed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_l0_sessions_session ON l0_sessions(session_key);
      CREATE INDEX IF NOT EXISTS idx_l0_sessions_pending ON l0_sessions(indexed, timestamp);
      CREATE TABLE IF NOT EXISTS pipeline_state (
        state_key TEXT PRIMARY KEY,
        state_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    `);
    this.migratePipelineStateTable();
  }

  private migratePipelineStateTable(): void {
    const columns = this.db.prepare("PRAGMA table_info(pipeline_state)").all() as DbRow[];
    const columnNames = new Set(
      columns
        .map((column) => String(column.name ?? "").trim())
        .filter(Boolean),
    );
    if (columnNames.has("state_json") && !columnNames.has("state_value")) return;
    if (!columnNames.has("state_json") && !columnNames.has("state_value")) return;
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS pipeline_state_v2 (
        state_key TEXT PRIMARY KEY,
        state_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      INSERT INTO pipeline_state_v2 (state_key, state_json, updated_at)
      SELECT
        state_key,
        COALESCE(state_json, state_value),
        updated_at
      FROM pipeline_state;
      DROP TABLE pipeline_state;
      ALTER TABLE pipeline_state_v2 RENAME TO pipeline_state;
    `);
  }

  close(): void {
    this.db.close();
  }

  getFileMemoryStore(): FileMemoryStore {
    return this.workspaceMemory;
  }

  getGlobalUserStore(): FileMemoryStore {
    return this.globalUserMemory;
  }

  repairWorkspaceManifest() {
    return this.workspaceMemory.repairManifests();
  }

  getUserSummary(): ReturnType<FileMemoryStore["getUserSummary"]> {
    const summary = this.globalUserMemory.getUserSummary();
    return {
      ...summary,
      files: summary.files.map((entry) => this.mapGlobalManifestEntry(entry)),
    };
  }

  private mapGlobalManifestEntry(entry: MemoryManifestEntry): MemoryManifestEntry {
    return {
      ...entry,
      relativePath: toExposedGlobalRelativePath(entry.relativePath),
    };
  }

  private mapGlobalFileRecord(record: MemoryFileRecord): MemoryFileRecord {
    return {
      ...record,
      relativePath: toExposedGlobalRelativePath(record.relativePath),
    };
  }

  private listGlobalMemoryEntries(options: {
    kinds?: Array<"user" | "feedback" | "project">;
    query?: string;
    limit?: number;
    offset?: number;
    scope?: "global" | "project";
    includeDeprecated?: boolean;
  } = {}): MemoryManifestEntry[] {
    const kinds = options.kinds?.filter((kind) => kind === "user");
    if (options.scope === "project") return [];
    if (options.kinds && (!kinds || kinds.length === 0)) return [];
    return this.globalUserMemory.listMemoryEntries({
      ...(kinds ? { kinds } : { kinds: ["user"] }),
      ...(options.query ? { query: options.query } : {}),
      ...(typeof options.limit === "number" ? { limit: options.limit } : {}),
      ...(typeof options.offset === "number" ? { offset: options.offset } : {}),
      scope: "global",
      includeDeprecated: options.includeDeprecated,
    }).map((entry) => this.mapGlobalManifestEntry(entry));
  }

  private readPipelineState<T>(key: string, fallback: T): T {
    const row = this.db.prepare("SELECT state_json FROM pipeline_state WHERE state_key = ?").get(key) as DbRow | undefined;
    if (!row || typeof row.state_json !== "string") return fallback;
    return parseJson(row.state_json, fallback);
  }

  getPipelineState<T = unknown>(key: string): T | undefined {
    const row = this.db.prepare("SELECT state_json FROM pipeline_state WHERE state_key = ?").get(key) as DbRow | undefined;
    if (!row || typeof row.state_json !== "string") return undefined;
    return parseJson<T | undefined>(row.state_json, undefined);
  }

  setPipelineState(key: string, value: unknown): void {
    this.db.prepare(`
      INSERT INTO pipeline_state (state_key, state_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(state_key) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at
    `).run(key, JSON.stringify(value), nowIso());
  }

  deletePipelineState(key: string): void {
    this.db.prepare("DELETE FROM pipeline_state WHERE state_key = ?").run(key);
  }

  insertL0Session(record: L0SessionRecord): void {
    const createdAt = record.createdAt || nowIso();
    this.db.prepare(`
      INSERT INTO l0_sessions (
        l0_index_id,
        session_key,
        timestamp,
        messages_json,
        source,
        indexed,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(l0_index_id) DO UPDATE SET
        session_key = excluded.session_key,
        timestamp = excluded.timestamp,
        messages_json = excluded.messages_json,
        source = excluded.source,
        indexed = excluded.indexed,
        created_at = excluded.created_at
    `).run(
      record.l0IndexId,
      record.sessionKey,
      record.timestamp,
      JSON.stringify(record.messages),
      record.source || "openclaw",
      record.indexed ? 1 : 0,
      createdAt,
    );
  }

  listPendingSessionKeys(limit = 50, preferredSessionKeys?: string[]): string[] {
    const normalizedPreferred = Array.isArray(preferredSessionKeys)
      ? preferredSessionKeys.filter((item): item is string => typeof item === "string" && item.trim().length > 0)
      : [];
    if (normalizedPreferred.length > 0) {
      const placeholders = normalizedPreferred.map(() => "?").join(", ");
      const rows = this.db.prepare(`
        SELECT DISTINCT session_key, MIN(timestamp) AS first_timestamp
        FROM l0_sessions
        WHERE indexed = 0 AND session_key IN (${placeholders})
        GROUP BY session_key
        ORDER BY first_timestamp ASC
      `).all(...normalizedPreferred) as DbRow[];
      return rows.map((row) => String(row.session_key)).slice(0, Math.max(1, limit));
    }
    const rows = this.db.prepare(`
      SELECT DISTINCT session_key, MIN(timestamp) AS first_timestamp
      FROM l0_sessions
      WHERE indexed = 0
      GROUP BY session_key
      ORDER BY first_timestamp ASC
      LIMIT ?
    `).all(Math.max(1, limit)) as DbRow[];
    return rows.map((row) => String(row.session_key));
  }

  getEarliestPendingTimestamp(preferredSessionKeys?: string[]): string | undefined {
    const normalizedPreferred = Array.isArray(preferredSessionKeys)
      ? preferredSessionKeys.filter((item): item is string => typeof item === "string" && item.trim().length > 0)
      : [];
    if (normalizedPreferred.length > 0) {
      const placeholders = normalizedPreferred.map(() => "?").join(", ");
      const row = this.db.prepare(`
        SELECT MIN(timestamp) AS first_timestamp
        FROM l0_sessions
        WHERE indexed = 0 AND session_key IN (${placeholders})
      `).get(...normalizedPreferred) as DbRow | undefined;
      return typeof row?.first_timestamp === "string" && row.first_timestamp.trim()
        ? row.first_timestamp
        : undefined;
    }
    const row = this.db.prepare(`
      SELECT MIN(timestamp) AS first_timestamp
      FROM l0_sessions
      WHERE indexed = 0
    `).get() as DbRow | undefined;
    return typeof row?.first_timestamp === "string" && row.first_timestamp.trim()
      ? row.first_timestamp
      : undefined;
  }

  listUnindexedL0BySession(sessionKey: string): L0SessionRecord[] {
    const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE session_key = ? AND indexed = 0
      ORDER BY timestamp ASC, created_at ASC
    `).all(sessionKey) as DbRow[];
    return rows.map((row) => normalizeL0Row(row));
  }

  getLatestL0Before(sessionKey: string, timestamp: string, createdAt: string): L0SessionRecord | undefined {
    const row = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE session_key = ?
        AND (timestamp < ? OR (timestamp = ? AND created_at < ?))
      ORDER BY timestamp DESC, created_at DESC
      LIMIT 1
    `).get(sessionKey, timestamp, timestamp, createdAt) as DbRow | undefined;
    return row ? normalizeL0Row(row) : undefined;
  }

  markL0Indexed(ids: string[]): void {
    const uniqueIds = Array.from(new Set(ids.filter((item) => typeof item === "string" && item.trim().length > 0)));
    if (uniqueIds.length === 0) return;
    const placeholders = uniqueIds.map(() => "?").join(", ");
    this.db.prepare(`UPDATE l0_sessions SET indexed = 1 WHERE l0_index_id IN (${placeholders})`).run(...uniqueIds);
  }

  getL0ByIds(ids: string[]): L0SessionRecord[] {
    const uniqueIds = Array.from(new Set(ids.filter((item) => typeof item === "string" && item.trim().length > 0)));
    if (uniqueIds.length === 0) return [];
    const placeholders = uniqueIds.map(() => "?").join(", ");
    const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE l0_index_id IN (${placeholders})
      ORDER BY timestamp DESC, created_at DESC
    `).all(...uniqueIds) as DbRow[];
    return rows.map((row) => normalizeL0Row(row));
  }

  listRecentL0(limit = 20, offset = 0): L0SessionRecord[] {
    const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      ORDER BY timestamp DESC, created_at DESC
      LIMIT ? OFFSET ?
    `).all(Math.max(1, limit), Math.max(0, offset)) as DbRow[];
    return rows.map((row) => normalizeL0Row(row));
  }

  listAllL0(): L0SessionRecord[] {
    const rows = this.db.prepare("SELECT * FROM l0_sessions ORDER BY timestamp ASC, created_at ASC").all() as DbRow[];
    return rows.map((row) => normalizeL0Row(row));
  }

  repairL0Sessions(transform: (record: L0SessionRecord) => MemoryMessage[]): RepairMemoryResult {
    const rows = this.listAllL0();
    let updated = 0;
    let removed = 0;
    for (const row of rows) {
      const nextMessages = transform(row);
      if (nextMessages.length === 0) {
        this.db.prepare("DELETE FROM l0_sessions WHERE l0_index_id = ?").run(row.l0IndexId);
        removed += 1;
        continue;
      }
      if (JSON.stringify(nextMessages) === JSON.stringify(row.messages)) continue;
      this.db.prepare("UPDATE l0_sessions SET messages_json = ?, indexed = 0 WHERE l0_index_id = ?")
        .run(JSON.stringify(nextMessages), row.l0IndexId);
      updated += 1;
    }
    return {
      inspected: rows.length,
      updated,
      removed,
      rebuilt: updated > 0 || removed > 0,
    };
  }

  saveCaseTrace(record: CaseTraceRecord, limit = 30): void {
    const next = sanitizeTraceArray<CaseTraceRecord>(
      [record, ...this.readPipelineState<unknown[]>(RECENT_CASE_TRACES_STATE_KEY, [])],
      "caseId",
      "startedAt",
    ).slice(0, Math.max(1, limit));
    this.setPipelineState(RECENT_CASE_TRACES_STATE_KEY, next);
  }

  listRecentCaseTraces(limit = 30): CaseTraceRecord[] {
    return sanitizeTraceArray<CaseTraceRecord>(
      this.readPipelineState<unknown[]>(RECENT_CASE_TRACES_STATE_KEY, []),
      "caseId",
      "startedAt",
    ).slice(0, Math.max(1, limit));
  }

  getCaseTrace(caseId: string): CaseTraceRecord | undefined {
    return this.listRecentCaseTraces(200).find((item) => item.caseId === caseId);
  }

  saveIndexTrace(record: IndexTraceRecord, limit = 30): void {
    const next = sanitizeTraceArray<IndexTraceRecord>(
      [record, ...this.readPipelineState<unknown[]>(RECENT_INDEX_TRACES_STATE_KEY, [])],
      "indexTraceId",
      "startedAt",
    ).map((item) => normalizeIndexTraceRecord(item)).slice(0, Math.max(1, limit));
    this.setPipelineState(RECENT_INDEX_TRACES_STATE_KEY, next);
  }

  listRecentIndexTraces(limit = 30): IndexTraceRecord[] {
    return sanitizeTraceArray<IndexTraceRecord>(
      this.readPipelineState<unknown[]>(RECENT_INDEX_TRACES_STATE_KEY, []),
      "indexTraceId",
      "startedAt",
    ).map((item) => normalizeIndexTraceRecord(item)).slice(0, Math.max(1, limit));
  }

  getIndexTrace(indexTraceId: string): IndexTraceRecord | undefined {
    return this.listRecentIndexTraces(200).find((item) => item.indexTraceId === indexTraceId);
  }

  saveDreamTrace(record: DreamTraceRecord, limit = 30): void {
    const next = sanitizeTraceArray<DreamTraceRecord>(
      [record, ...this.readPipelineState<unknown[]>(RECENT_DREAM_TRACES_STATE_KEY, [])],
      "dreamTraceId",
      "startedAt",
    ).map((item) => normalizeDreamTraceRecord(item)).slice(0, Math.max(1, limit));
    this.setPipelineState(RECENT_DREAM_TRACES_STATE_KEY, next);
  }

  listRecentDreamTraces(limit = 30): DreamTraceRecord[] {
    return sanitizeTraceArray<DreamTraceRecord>(
      this.readPipelineState<unknown[]>(RECENT_DREAM_TRACES_STATE_KEY, []),
      "dreamTraceId",
      "startedAt",
    ).map((item) => normalizeDreamTraceRecord(item)).slice(0, Math.max(1, limit));
  }

  getDreamTrace(dreamTraceId: string): DreamTraceRecord | undefined {
    return this.listRecentDreamTraces(200).find((item) => item.dreamTraceId === dreamTraceId);
  }

  getIndexingSettings(defaults: IndexingSettings): IndexingSettings {
    return sanitizeIndexingSettings(this.getPipelineState(INDEXING_SETTINGS_STATE_KEY), defaults);
  }

  saveIndexingSettings(partial: Partial<IndexingSettings>, defaults: IndexingSettings): IndexingSettings {
    const current = this.getIndexingSettings(defaults);
    const next = sanitizeIndexingSettings({ ...current, ...partial }, defaults);
    this.setPipelineState(INDEXING_SETTINGS_STATE_KEY, next);
    return next;
  }

  private buildTransferCounts(workspaceStore: FileMemoryStore, globalStore: FileMemoryStore): MemoryTransferCounts {
    const workspaceImported = workspaceStore.exportBundleRecords({ includeTmp: true });
    const globalImported = globalStore.exportBundleRecords({ includeTmp: true });
    const memoryFiles = [...workspaceImported.memoryFiles, ...globalImported.memoryFiles];
    return {
      managedFiles: workspaceStore.exportSnapshotFiles().length + globalStore.exportSnapshotFiles().length,
      memoryFiles: memoryFiles.length,
      project: memoryFiles.filter((item) => item.type === "project").length,
      feedback: memoryFiles.filter((item) => item.type === "feedback").length,
      user: memoryFiles.filter((item) => item.type === "user").length,
      tmp: 0,
      projectMetas: workspaceImported.projectMetas.length,
    };
  }

  private materializeSnapshotBundle(
    rootDir: string,
    files: MemorySnapshotFileRecord[],
    options: FileMemoryStoreOptions,
  ): FileMemoryStore {
    mkdirSync(rootDir, { recursive: true });
    for (const record of files) {
      const absolutePath = resolve(rootDir, record.relativePath);
      if (!isPathWithinRoot(rootDir, absolutePath) || absolutePath === resolve(rootDir)) {
        throw new MemoryBundleValidationError(`Invalid imported snapshot file path: ${record.relativePath}`);
      }
      mkdirSync(dirname(absolutePath), { recursive: true });
      writeFileSync(absolutePath, record.content, "utf-8");
    }
    const store = new FileMemoryStore(rootDir, options);
    store.repairManifests();
    return store;
  }

  private stageImportBundle(bundle: MemoryImportableBundle): {
    stagedWorkspaceRoot: string;
    stagedGlobalRoot: string;
    counts: MemoryTransferCounts;
  } {
    const workspaceFiles = bundle.files.filter((record) => !isGlobalRelativePath(record.relativePath));
    const globalFiles = bundle.files
      .filter((record) => isGlobalRelativePath(record.relativePath))
      .map((record) => ({
        ...record,
        relativePath: toInternalGlobalRelativePath(record.relativePath),
      }));
    const liveWorkspaceRoot = this.workspaceMemory.getRootDir();
    const liveGlobalRoot = this.globalUserMemory.getRootDir();
    const stagedWorkspaceRoot = createSiblingTempPath(liveWorkspaceRoot, "import");
    const stagedGlobalRoot = createSiblingTempPath(liveGlobalRoot, "import");
    mkdirSync(stagedWorkspaceRoot, { recursive: true });
    mkdirSync(stagedGlobalRoot, { recursive: true });
    try {
      const stagedWorkspaceStore = this.materializeSnapshotBundle(stagedWorkspaceRoot, workspaceFiles, {
        manageProjectMeta: true,
        manageProjectFiles: true,
        manageUserProfile: false,
        enableManifest: true,
      });
      const stagedGlobalStore = this.materializeSnapshotBundle(stagedGlobalRoot, globalFiles, {
        manageProjectMeta: false,
        manageProjectFiles: false,
        manageUserProfile: true,
        userProfileRelativePath: GLOBAL_USER_PROFILE_RELATIVE_PATH,
        userNotesRelativeDir: GLOBAL_USER_NOTES_RELATIVE_DIR,
        appendOnlyUserEntries: true,
        enableManifest: false,
      });
      return {
        stagedWorkspaceRoot,
        stagedGlobalRoot,
        counts: this.buildTransferCounts(stagedWorkspaceStore, stagedGlobalStore),
      };
    } catch (error) {
      rmSync(stagedWorkspaceRoot, { recursive: true, force: true });
      rmSync(stagedGlobalRoot, { recursive: true, force: true });
      throw error;
    }
  }

  private swapInStagedMemoryRoot(liveRoot: string, stagedRoot: string): void {
    const backupRoot = createSiblingTempPath(liveRoot, "backup");
    let movedLiveRoot = false;
    try {
      if (existsSync(liveRoot)) {
        renameSync(liveRoot, backupRoot);
        movedLiveRoot = true;
      }
      renameSync(stagedRoot, liveRoot);
    } catch (error) {
      if (existsSync(stagedRoot)) {
        rmSync(stagedRoot, { recursive: true, force: true });
      }
      if (movedLiveRoot && !existsSync(liveRoot) && existsSync(backupRoot)) {
        renameSync(backupRoot, liveRoot);
      }
      throw error;
    }
    if (movedLiveRoot && existsSync(backupRoot)) {
      try {
        rmSync(backupRoot, { recursive: true, force: true });
      } catch {
        // Best-effort cleanup; the live memory root has already been swapped in.
      }
    }
  }

  private resetImportedRuntimeState(bundle: MemoryImportableBundle): void {
    this.db.exec("DELETE FROM l0_sessions;");
    for (const key of [
      RECENT_CASE_TRACES_STATE_KEY,
      RECENT_INDEX_TRACES_STATE_KEY,
      RECENT_DREAM_TRACES_STATE_KEY,
      LAST_INDEXED_AT_STATE_KEY,
      LAST_DREAM_AT_STATE_KEY,
      LAST_DREAM_STATUS_STATE_KEY,
      LAST_DREAM_SUMMARY_STATE_KEY,
    ]) {
      this.deletePipelineState(key);
    }
    if (bundle.lastIndexedAt) this.setPipelineState(LAST_INDEXED_AT_STATE_KEY, bundle.lastIndexedAt);
    if (bundle.lastDreamAt) this.setPipelineState(LAST_DREAM_AT_STATE_KEY, bundle.lastDreamAt);
    if (bundle.lastDreamStatus) this.setPipelineState(LAST_DREAM_STATUS_STATE_KEY, bundle.lastDreamStatus);
    if (bundle.lastDreamSummary) this.setPipelineState(LAST_DREAM_SUMMARY_STATE_KEY, bundle.lastDreamSummary);
    if (bundle.recentCaseTraces) this.setPipelineState(RECENT_CASE_TRACES_STATE_KEY, bundle.recentCaseTraces);
    if (bundle.recentIndexTraces) this.setPipelineState(RECENT_INDEX_TRACES_STATE_KEY, bundle.recentIndexTraces);
    if (bundle.recentDreamTraces) this.setPipelineState(RECENT_DREAM_TRACES_STATE_KEY, bundle.recentDreamTraces);
  }

  exportMemoryBundle(): MemoryExportBundle {
    return {
      formatVersion: MEMORY_EXPORT_FORMAT_VERSION,
      exportedAt: nowIso(),
      ...(typeof this.getPipelineState<string>(LAST_INDEXED_AT_STATE_KEY) === "string"
        ? { lastIndexedAt: this.getPipelineState<string>(LAST_INDEXED_AT_STATE_KEY)! }
        : {}),
      ...(typeof this.getPipelineState<string>(LAST_DREAM_AT_STATE_KEY) === "string"
        ? { lastDreamAt: this.getPipelineState<string>(LAST_DREAM_AT_STATE_KEY)! }
        : {}),
      ...(sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))
        ? { lastDreamStatus: sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))! }
        : {}),
      ...(typeof this.getPipelineState<string>(LAST_DREAM_SUMMARY_STATE_KEY) === "string"
        ? { lastDreamSummary: this.getPipelineState<string>(LAST_DREAM_SUMMARY_STATE_KEY)! }
        : {}),
      ...(this.listRecentCaseTraces(200).length > 0 ? { recentCaseTraces: this.listRecentCaseTraces(200) } : {}),
      ...(this.listRecentIndexTraces(200).length > 0 ? { recentIndexTraces: this.listRecentIndexTraces(200) } : {}),
      ...(this.listRecentDreamTraces(200).length > 0 ? { recentDreamTraces: this.listRecentDreamTraces(200) } : {}),
      files: [
        ...this.workspaceMemory.exportSnapshotFiles(),
        ...this.globalUserMemory.exportSnapshotFiles().map((record) => ({
          ...record,
          relativePath: toExposedGlobalRelativePath(record.relativePath),
        })),
      ],
    };
  }

  importMemoryBundle(bundle: MemoryImportableBundle): MemoryImportResult {
    const normalized = normalizeMemoryBundle(bundle);
    const staged = this.stageImportBundle(normalized);
    this.swapInStagedMemoryRoot(this.workspaceMemory.getRootDir(), staged.stagedWorkspaceRoot);
    this.swapInStagedMemoryRoot(this.globalUserMemory.getRootDir(), staged.stagedGlobalRoot);
    this.workspaceMemory.repairManifests();
    this.resetImportedRuntimeState(normalized);
    return {
      formatVersion: MEMORY_EXPORT_FORMAT_VERSION,
      imported: staged.counts,
      importedAt: nowIso(),
      ...(normalized.lastIndexedAt ? { lastIndexedAt: normalized.lastIndexedAt } : {}),
      ...(normalized.lastDreamAt ? { lastDreamAt: normalized.lastDreamAt } : {}),
      ...(normalized.lastDreamStatus ? { lastDreamStatus: normalized.lastDreamStatus } : {}),
      ...(normalized.lastDreamSummary ? { lastDreamSummary: normalized.lastDreamSummary } : {}),
      ...(normalized.recentCaseTraces ? { recentCaseTraces: normalized.recentCaseTraces } : {}),
      ...(normalized.recentIndexTraces ? { recentIndexTraces: normalized.recentIndexTraces } : {}),
      ...(normalized.recentDreamTraces ? { recentDreamTraces: normalized.recentDreamTraces } : {}),
    };
  }

  getOverview(): DashboardOverview {
    const pendingSessions = Number(
      (this.db.prepare("SELECT COUNT(DISTINCT session_key) AS count FROM l0_sessions WHERE indexed = 0").get() as DbRow | undefined)?.count ?? 0,
    );
    const lastDreamAt = this.getPipelineState<string>(LAST_DREAM_AT_STATE_KEY);
    const fileOverview = this.workspaceMemory.getOverview(typeof lastDreamAt === "string" ? lastDreamAt : undefined);
    const recentRecallTraceCount = this.listRecentCaseTraces(12).length;
    const recentIndexTraceCount = this.listRecentIndexTraces(30).length;
    const recentDreamTraceCount = this.listRecentDreamTraces(30).length;
    const workspaceHasProjectMemory = fileOverview.projectMemories + fileOverview.feedbackMemories > 0;
    const userProfileCount = this.listGlobalMemoryEntries({
      kinds: ["user"],
      scope: "global",
      limit: 10,
    }).some((entry) => entry.relativePath === toExposedGlobalRelativePath(GLOBAL_USER_PROFILE_RELATIVE_PATH))
      ? 1
      : 0;
    return {
      pendingSessions,
      currentProjectCount: workspaceHasProjectMemory || fileOverview.projectMetaCount > 0 ? 1 : 0,
      projectMetaPresent: fileOverview.projectMetaCount > 0,
      projectMemoryCount: fileOverview.projectMemories,
      feedbackMemoryCount: fileOverview.feedbackMemories,
      userProfileCount,
      recentRecallTraceCount,
      recentIndexTraceCount,
      recentDreamTraceCount,
      ...(typeof this.getPipelineState<string>(LAST_INDEXED_AT_STATE_KEY) === "string"
        ? { lastIndexedAt: this.getPipelineState<string>(LAST_INDEXED_AT_STATE_KEY)! }
        : {}),
      ...(typeof lastDreamAt === "string" ? { lastDreamAt } : {}),
      ...(sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))
        ? { lastDreamStatus: sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))! }
        : {}),
      ...(typeof this.getPipelineState<string>(LAST_DREAM_SUMMARY_STATE_KEY) === "string"
        ? { lastDreamSummary: this.getPipelineState<string>(LAST_DREAM_SUMMARY_STATE_KEY)! }
        : {}),
    };
  }

  getUiSnapshot(limit = 50): MemoryUiSnapshot {
    return {
      overview: this.getOverview(),
      settings: this.getIndexingSettings({
        reasoningMode: "answer_first",
        autoIndexIntervalMinutes: 60,
        autoDreamIntervalMinutes: 360,
      }),
      recentMemoryFiles: this.listMemoryEntries({ limit }),
    };
  }

  listMemoryEntries(options: {
    kinds?: Array<"user" | "feedback" | "project">;
    query?: string;
    limit?: number;
    offset?: number;
    scope?: "global" | "project";
    projectId?: string;
    includeTmp?: boolean;
    includeDeprecated?: boolean;
  } = {}): MemoryManifestEntry[] {
    const includeWorkspace = options.scope !== "global";
    const includeGlobal = options.scope !== "project";
    const workspaceEntries = includeWorkspace
      ? this.workspaceMemory.listMemoryEntries({
        ...options,
        limit: 5000,
        offset: 0,
      })
      : [];
    const globalEntries = includeGlobal
      ? this.listGlobalMemoryEntries({
        ...options,
        limit: 5000,
        offset: 0,
      })
      : [];
    const filtered = sortManifestEntries([...workspaceEntries, ...globalEntries]);
    const offset = Math.max(0, options.offset ?? 0);
    const limit = Math.max(1, options.limit ?? (filtered.length || 1));
    return filtered.slice(offset, offset + limit);
  }

  countMemoryEntries(options: {
    kinds?: Array<"user" | "feedback" | "project">;
    query?: string;
    scope?: "global" | "project";
    projectId?: string;
    includeTmp?: boolean;
    includeDeprecated?: boolean;
  } = {}): number {
    const workspaceEntries = options.scope === "global"
      ? []
      : this.workspaceMemory.listMemoryEntries({
        ...options,
        limit: 5000,
        offset: 0,
      });
    const globalEntries = options.scope === "project"
      ? []
      : this.listGlobalMemoryEntries({
        ...options,
        limit: 5000,
        offset: 0,
      });
    return [...workspaceEntries, ...globalEntries].length;
  }

  getMemoryRecordsByIds(ids: string[], maxLines = 80): MemoryFileRecord[] {
    const uniqueIds = Array.from(new Set(ids.filter((item) => typeof item === "string" && item.trim().length > 0)));
    const workspaceIds = uniqueIds.filter((id) => !isGlobalRelativePath(id));
    const globalIds = uniqueIds
      .filter((id) => isGlobalRelativePath(id))
      .map((id) => toInternalGlobalRelativePath(id));
    const workspaceRecords = this.workspaceMemory.getMemoryRecordsByIds(workspaceIds, maxLines);
    const globalRecords = this.globalUserMemory
      .getMemoryRecordsByIds(globalIds, maxLines)
      .map((record) => this.mapGlobalFileRecord(record));
    const byId = new Map<string, MemoryFileRecord>([
      ...workspaceRecords.map((record) => [record.relativePath, record] as const),
      ...globalRecords.map((record) => [record.relativePath, record] as const),
    ]);
    return ids
      .map((id) => byId.get(id))
      .filter((record): record is MemoryFileRecord => Boolean(record));
  }

  editProjectMeta(input: {
    projectId?: string;
    projectName: string;
    description: string;
    aliases?: string[];
    status: string;
  }) {
    return this.workspaceMemory.editProjectMeta(input);
  }

  ensureProjectMeta(input: {
    projectName?: string;
    description?: string;
    aliases?: string[];
    status?: string;
  } = {}) {
    return this.workspaceMemory.ensureProjectMeta(input);
  }

  getProjectMeta() {
    return this.workspaceMemory.getProjectMeta();
  }

  editMemoryEntry(input: {
    id: string;
    name: string;
    description: string;
    fields?: MemoryEntryEditFields;
  }) {
    const store = isGlobalRelativePath(input.id) ? this.globalUserMemory : this.workspaceMemory;
    const relativePath = isGlobalRelativePath(input.id)
      ? toInternalGlobalRelativePath(input.id)
      : input.id;
    const record = store.editEntry({
      relativePath,
      name: input.name,
      description: input.description,
      ...(input.fields ? { fields: input.fields } : {}),
    });
    return isGlobalRelativePath(input.id) ? this.mapGlobalFileRecord(record) : record;
  }

  deleteMemoryEntries(ids: string[]) {
    const workspaceIds = ids.filter((id) => !isGlobalRelativePath(id));
    const globalIds = ids
      .filter((id) => isGlobalRelativePath(id))
      .map((id) => toInternalGlobalRelativePath(id));
    const workspaceResult = this.workspaceMemory.deleteEntries(workspaceIds);
    const globalResult = this.globalUserMemory.deleteEntries(globalIds);
    this.workspaceMemory.repairManifests();
    return {
      mutatedIds: [
        ...workspaceResult.mutatedIds,
        ...globalResult.mutatedIds.map((id) => toExposedGlobalRelativePath(id)),
      ],
      deletedProjectIds: [...workspaceResult.deletedProjectIds, ...globalResult.deletedProjectIds],
    };
  }

  deprecateMemoryEntries(ids: string[]) {
    const workspaceIds = ids.filter((id) => !isGlobalRelativePath(id));
    const globalIds = ids
      .filter((id) => isGlobalRelativePath(id))
      .map((id) => toInternalGlobalRelativePath(id));
    const workspaceResult = this.workspaceMemory.markEntriesDeprecated(workspaceIds);
    const globalResult = this.globalUserMemory.markEntriesDeprecated(globalIds);
    this.workspaceMemory.repairManifests();
    return {
      mutatedIds: [
        ...workspaceResult.mutatedIds,
        ...globalResult.mutatedIds.map((id) => toExposedGlobalRelativePath(id)),
      ],
      deletedProjectIds: [...workspaceResult.deletedProjectIds, ...globalResult.deletedProjectIds],
    };
  }

  restoreMemoryEntries(ids: string[]) {
    const workspaceIds = ids.filter((id) => !isGlobalRelativePath(id));
    const globalIds = ids
      .filter((id) => isGlobalRelativePath(id))
      .map((id) => toInternalGlobalRelativePath(id));
    const workspaceResult = this.workspaceMemory.restoreEntries(workspaceIds);
    const globalResult = this.globalUserMemory.restoreEntries(globalIds);
    this.workspaceMemory.repairManifests();
    return {
      mutatedIds: [
        ...workspaceResult.mutatedIds,
        ...globalResult.mutatedIds.map((id) => toExposedGlobalRelativePath(id)),
      ],
      deletedProjectIds: [...workspaceResult.deletedProjectIds, ...globalResult.deletedProjectIds],
    };
  }

  archiveTmpEntries(input: {
    ids: string[];
    targetProjectId?: string;
    newProjectName?: string;
  }) {
    return this.workspaceMemory.archiveTmpEntries({
      relativePaths: input.ids,
      ...(input.targetProjectId ? { targetProjectId: input.targetProjectId } : {}),
      ...(input.newProjectName ? { newProjectName: input.newProjectName } : {}),
    });
  }

  getSnapshotVersion(): string {
    const payload = JSON.stringify({
      lastDreamAt: this.getPipelineState<string>(LAST_DREAM_AT_STATE_KEY) ?? "",
      files: this.exportMemoryBundle().files,
    });
    return hashText(payload);
  }

  clearAllMemoryData(): ClearMemoryResult {
    const l0Sessions = Number((this.db.prepare("SELECT COUNT(*) AS count FROM l0_sessions").get() as DbRow | undefined)?.count ?? 0);
    const pipelineState = Number((this.db.prepare("SELECT COUNT(*) AS count FROM pipeline_state").get() as DbRow | undefined)?.count ?? 0);
    const beforeWorkspace = this.workspaceMemory.exportBundleRecords({ includeTmp: true });
    const beforeGlobal = this.globalUserMemory.exportBundleRecords({ includeTmp: true });
    this.db.exec(`
      DELETE FROM l0_sessions;
      DELETE FROM pipeline_state;
    `);
    this.workspaceMemory.clearAllData();
    this.globalUserMemory.clearAllData();
    return {
      cleared: {
        l0Sessions,
        pipelineState,
        memoryFiles: beforeWorkspace.memoryFiles.length + beforeGlobal.memoryFiles.length,
        projectMetas: beforeWorkspace.projectMetas.length,
      },
      clearedAt: nowIso(),
    };
  }
}
