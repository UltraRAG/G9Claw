import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { MEMORY_EXPORT_FORMAT_VERSION, } from "../types.js";
import { FileMemoryStore } from "../file-memory.js";
import { nowIso } from "../utils/id.js";
const INDEXING_SETTINGS_STATE_KEY = "indexingSettings";
const LAST_INDEXED_AT_STATE_KEY = "lastIndexedAt";
const LAST_DREAM_AT_STATE_KEY = "lastDreamAt";
const LAST_DREAM_STATUS_STATE_KEY = "lastDreamStatus";
const LAST_DREAM_SUMMARY_STATE_KEY = "lastDreamSummary";
const RECENT_CASE_TRACES_STATE_KEY = "recentCaseTraces";
const RECENT_INDEX_TRACES_STATE_KEY = "recentIndexTraces";
const RECENT_DREAM_TRACES_STATE_KEY = "recentDreamTraces";
export class MemoryBundleValidationError extends Error {
    constructor(message) {
        super(message);
        this.name = "MemoryBundleValidationError";
    }
}
function isRecord(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
function parseJson(raw, fallback) {
    try {
        return JSON.parse(raw);
    }
    catch {
        return fallback;
    }
}
function normalizeString(value) {
    return typeof value === "string" ? value : "";
}
function normalizeMessages(value) {
    if (!Array.isArray(value))
        return [];
    return value
        .filter((item) => isRecord(item))
        .map((item) => ({
        ...(typeof item.msgId === "string" && item.msgId.trim() ? { msgId: item.msgId } : {}),
        role: typeof item.role === "string" && item.role.trim() ? item.role : "user",
        content: typeof item.content === "string" ? item.content : "",
    }));
}
function normalizeL0Row(row) {
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
function sanitizeTraceArray(value, key, sortKey) {
    if (!Array.isArray(value))
        return [];
    const sorted = value
        .filter((item) => {
        if (!isRecord(item))
            return false;
        const keyed = item;
        return typeof keyed[key] === "string" && typeof keyed[sortKey] === "string";
    })
        .sort((left, right) => {
        const rightValue = right[sortKey];
        const leftValue = left[sortKey];
        return String(rightValue).localeCompare(String(leftValue));
    });
    const seen = new Set();
    const next = [];
    for (const item of sorted) {
        const id = String(item[key]);
        if (!id || seen.has(id))
            continue;
        seen.add(id);
        next.push(item);
    }
    return next;
}
function sanitizeDreamStatus(value) {
    return value === "running" || value === "success" || value === "skipped" || value === "failed"
        ? value
        : undefined;
}
function clampInt(value, fallback, min, max) {
    const numeric = typeof value === "number"
        ? value
        : typeof value === "string" && value.trim()
            ? Number.parseInt(value, 10)
            : Number.NaN;
    if (!Number.isFinite(numeric))
        return fallback;
    return Math.max(min, Math.min(max, Math.floor(numeric)));
}
function sanitizeIndexingSettings(input, defaults) {
    const record = isRecord(input) ? input : {};
    return {
        reasoningMode: record.reasoningMode === "accuracy_first" ? "accuracy_first" : defaults.reasoningMode,
        autoIndexIntervalMinutes: clampInt(record.autoIndexIntervalMinutes, defaults.autoIndexIntervalMinutes, 0, 10_080),
        autoDreamIntervalMinutes: clampInt(record.autoDreamIntervalMinutes, defaults.autoDreamIntervalMinutes, 0, 10_080),
    };
}
function normalizeSnapshotRelativePath(value, index) {
    const raw = normalizeString(value).trim().replace(/\\/g, "/");
    if (!raw) {
        throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
    }
    if (isAbsolute(raw)) {
        throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
    }
    const segments = raw.split("/").filter(Boolean);
    if (segments.length === 0
        || segments.some((segment) => segment === "." || segment === "..")) {
        throw new MemoryBundleValidationError(`Invalid files[${index}].relativePath`);
    }
    return segments.join("/");
}
function normalizeSnapshotFileRecord(value, index) {
    if (!isRecord(value))
        throw new MemoryBundleValidationError(`Invalid files[${index}]`);
    if (typeof value.content !== "string") {
        throw new MemoryBundleValidationError(`Invalid files[${index}].content`);
    }
    return {
        relativePath: normalizeSnapshotRelativePath(value.relativePath, index),
        content: value.content,
    };
}
function hasLegacyMultiProjectPath(relativePath) {
    return relativePath.startsWith("projects/")
        || relativePath.includes("/project.meta.md");
}
function normalizeMemoryBundle(value) {
    if (!isRecord(value))
        throw new MemoryBundleValidationError("Invalid memory bundle");
    const metadata = {
        exportedAt: normalizeString(value.exportedAt).trim() || nowIso(),
        ...(typeof value.lastIndexedAt === "string" && value.lastIndexedAt.trim() ? { lastIndexedAt: value.lastIndexedAt.trim() } : {}),
        ...(typeof value.lastDreamAt === "string" && value.lastDreamAt.trim() ? { lastDreamAt: value.lastDreamAt.trim() } : {}),
        ...(sanitizeDreamStatus(value.lastDreamStatus) ? { lastDreamStatus: sanitizeDreamStatus(value.lastDreamStatus) } : {}),
        ...(typeof value.lastDreamSummary === "string" && value.lastDreamSummary.trim()
            ? { lastDreamSummary: value.lastDreamSummary.trim() }
            : {}),
        ...(sanitizeTraceArray(value.recentCaseTraces, "caseId", "startedAt").length > 0
            ? { recentCaseTraces: sanitizeTraceArray(value.recentCaseTraces, "caseId", "startedAt") }
            : {}),
        ...(sanitizeTraceArray(value.recentIndexTraces, "indexTraceId", "startedAt").length > 0
            ? { recentIndexTraces: sanitizeTraceArray(value.recentIndexTraces, "indexTraceId", "startedAt") }
            : {}),
        ...(sanitizeTraceArray(value.recentDreamTraces, "dreamTraceId", "startedAt").length > 0
            ? { recentDreamTraces: sanitizeTraceArray(value.recentDreamTraces, "dreamTraceId", "startedAt") }
            : {}),
    };
    if (value.formatVersion === MEMORY_EXPORT_FORMAT_VERSION) {
        if (!Array.isArray(value.files)) {
            throw new MemoryBundleValidationError("Invalid memory snapshot bundle files");
        }
        const files = value.files.map((item, index) => normalizeSnapshotFileRecord(item, index));
        const seenPaths = new Set();
        for (const record of files) {
            if (seenPaths.has(record.relativePath)) {
                throw new MemoryBundleValidationError(`Duplicate imported snapshot file path: ${record.relativePath}`);
            }
            seenPaths.add(record.relativePath);
            if (hasLegacyMultiProjectPath(record.relativePath)) {
                throw new MemoryBundleValidationError("Legacy multi-project memory bundles are not supported in current-project memory mode");
            }
        }
        return {
            formatVersion: MEMORY_EXPORT_FORMAT_VERSION,
            ...metadata,
            files,
        };
    }
    throw new MemoryBundleValidationError(`Unsupported memory bundle formatVersion. Expected ${MEMORY_EXPORT_FORMAT_VERSION}.`);
}
function isPathWithinRoot(rootDir, targetPath) {
    const rel = relative(resolve(rootDir), resolve(targetPath));
    return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}
async function loadSqlDatabaseFactory() {
    if (typeof globalThis.Bun !== "undefined") {
        const bunSqliteModuleName = "bun:sqlite";
        const bunSqlite = await import(bunSqliteModuleName);
        return (dbPath) => {
            const db = new bunSqlite.Database(dbPath, { create: true });
            return {
                exec: (sql) => db.exec(sql),
                prepare: (sql) => db.query(sql),
                close: () => db.close(),
            };
        };
    }
    const nodeSqlite = await import("node:sqlite");
    return (dbPath) => {
        const db = new nodeSqlite.DatabaseSync(dbPath);
        return {
            exec: (sql) => db.exec(sql),
            prepare: (sql) => db.prepare(sql),
            close: () => db.close(),
        };
    };
}
const createSqlDatabase = await loadSqlDatabaseFactory();
function createSiblingTempPath(targetDir, label) {
    const parentDir = dirname(targetDir);
    return join(parentDir, `.${basename(targetDir)}.${label}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`);
}
export class MemoryRepository {
    db;
    fileMemory;
    constructor(dbPath, options = {}) {
        mkdirSync(dirname(dbPath), { recursive: true });
        const memoryDir = options.memoryDir ?? join(dirname(dbPath), "memory");
        mkdirSync(memoryDir, { recursive: true });
        this.db = createSqlDatabase(dbPath);
        this.fileMemory = new FileMemoryStore(memoryDir);
        this.init();
    }
    init() {
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
    migratePipelineStateTable() {
        const columns = this.db.prepare("PRAGMA table_info(pipeline_state)").all();
        const columnNames = new Set(columns
            .map((column) => String(column.name ?? "").trim())
            .filter(Boolean));
        if (columnNames.has("state_json") && !columnNames.has("state_value"))
            return;
        if (!columnNames.has("state_json") && !columnNames.has("state_value"))
            return;
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
    close() {
        this.db.close();
    }
    getFileMemoryStore() {
        return this.fileMemory;
    }
    readPipelineState(key, fallback) {
        const row = this.db.prepare("SELECT state_json FROM pipeline_state WHERE state_key = ?").get(key);
        if (!row || typeof row.state_json !== "string")
            return fallback;
        return parseJson(row.state_json, fallback);
    }
    getPipelineState(key) {
        const row = this.db.prepare("SELECT state_json FROM pipeline_state WHERE state_key = ?").get(key);
        if (!row || typeof row.state_json !== "string")
            return undefined;
        return parseJson(row.state_json, undefined);
    }
    setPipelineState(key, value) {
        this.db.prepare(`
      INSERT INTO pipeline_state (state_key, state_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(state_key) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at
    `).run(key, JSON.stringify(value), nowIso());
    }
    deletePipelineState(key) {
        this.db.prepare("DELETE FROM pipeline_state WHERE state_key = ?").run(key);
    }
    insertL0Session(record) {
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
    `).run(record.l0IndexId, record.sessionKey, record.timestamp, JSON.stringify(record.messages), record.source || "openclaw", record.indexed ? 1 : 0, createdAt);
    }
    listPendingSessionKeys(limit = 50, preferredSessionKeys) {
        const normalizedPreferred = Array.isArray(preferredSessionKeys)
            ? preferredSessionKeys.filter((item) => typeof item === "string" && item.trim().length > 0)
            : [];
        if (normalizedPreferred.length > 0) {
            const placeholders = normalizedPreferred.map(() => "?").join(", ");
            const rows = this.db.prepare(`
        SELECT DISTINCT session_key, MIN(timestamp) AS first_timestamp
        FROM l0_sessions
        WHERE indexed = 0 AND session_key IN (${placeholders})
        GROUP BY session_key
        ORDER BY first_timestamp ASC
      `).all(...normalizedPreferred);
            return rows.map((row) => String(row.session_key)).slice(0, Math.max(1, limit));
        }
        const rows = this.db.prepare(`
      SELECT DISTINCT session_key, MIN(timestamp) AS first_timestamp
      FROM l0_sessions
      WHERE indexed = 0
      GROUP BY session_key
      ORDER BY first_timestamp ASC
      LIMIT ?
    `).all(Math.max(1, limit));
        return rows.map((row) => String(row.session_key));
    }
    listUnindexedL0BySession(sessionKey) {
        const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE session_key = ? AND indexed = 0
      ORDER BY timestamp ASC, created_at ASC
    `).all(sessionKey);
        return rows.map((row) => normalizeL0Row(row));
    }
    getLatestL0Before(sessionKey, timestamp, createdAt) {
        const row = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE session_key = ?
        AND (timestamp < ? OR (timestamp = ? AND created_at < ?))
      ORDER BY timestamp DESC, created_at DESC
      LIMIT 1
    `).get(sessionKey, timestamp, timestamp, createdAt);
        return row ? normalizeL0Row(row) : undefined;
    }
    markL0Indexed(ids) {
        const uniqueIds = Array.from(new Set(ids.filter((item) => typeof item === "string" && item.trim().length > 0)));
        if (uniqueIds.length === 0)
            return;
        const placeholders = uniqueIds.map(() => "?").join(", ");
        this.db.prepare(`UPDATE l0_sessions SET indexed = 1 WHERE l0_index_id IN (${placeholders})`).run(...uniqueIds);
    }
    getL0ByIds(ids) {
        const uniqueIds = Array.from(new Set(ids.filter((item) => typeof item === "string" && item.trim().length > 0)));
        if (uniqueIds.length === 0)
            return [];
        const placeholders = uniqueIds.map(() => "?").join(", ");
        const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      WHERE l0_index_id IN (${placeholders})
      ORDER BY timestamp DESC, created_at DESC
    `).all(...uniqueIds);
        return rows.map((row) => normalizeL0Row(row));
    }
    listRecentL0(limit = 20, offset = 0) {
        const rows = this.db.prepare(`
      SELECT * FROM l0_sessions
      ORDER BY timestamp DESC, created_at DESC
      LIMIT ? OFFSET ?
    `).all(Math.max(1, limit), Math.max(0, offset));
        return rows.map((row) => normalizeL0Row(row));
    }
    listAllL0() {
        const rows = this.db.prepare("SELECT * FROM l0_sessions ORDER BY timestamp ASC, created_at ASC").all();
        return rows.map((row) => normalizeL0Row(row));
    }
    repairL0Sessions(transform) {
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
            if (JSON.stringify(nextMessages) === JSON.stringify(row.messages))
                continue;
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
    saveCaseTrace(record, limit = 30) {
        const next = sanitizeTraceArray([record, ...this.readPipelineState(RECENT_CASE_TRACES_STATE_KEY, [])], "caseId", "startedAt").slice(0, Math.max(1, limit));
        this.setPipelineState(RECENT_CASE_TRACES_STATE_KEY, next);
    }
    listRecentCaseTraces(limit = 30) {
        return sanitizeTraceArray(this.readPipelineState(RECENT_CASE_TRACES_STATE_KEY, []), "caseId", "startedAt").slice(0, Math.max(1, limit));
    }
    getCaseTrace(caseId) {
        return this.listRecentCaseTraces(200).find((item) => item.caseId === caseId);
    }
    saveIndexTrace(record, limit = 30) {
        const next = sanitizeTraceArray([record, ...this.readPipelineState(RECENT_INDEX_TRACES_STATE_KEY, [])], "indexTraceId", "startedAt").slice(0, Math.max(1, limit));
        this.setPipelineState(RECENT_INDEX_TRACES_STATE_KEY, next);
    }
    listRecentIndexTraces(limit = 30) {
        return sanitizeTraceArray(this.readPipelineState(RECENT_INDEX_TRACES_STATE_KEY, []), "indexTraceId", "startedAt").slice(0, Math.max(1, limit));
    }
    getIndexTrace(indexTraceId) {
        return this.listRecentIndexTraces(200).find((item) => item.indexTraceId === indexTraceId);
    }
    saveDreamTrace(record, limit = 30) {
        const next = sanitizeTraceArray([record, ...this.readPipelineState(RECENT_DREAM_TRACES_STATE_KEY, [])], "dreamTraceId", "startedAt").slice(0, Math.max(1, limit));
        this.setPipelineState(RECENT_DREAM_TRACES_STATE_KEY, next);
    }
    listRecentDreamTraces(limit = 30) {
        return sanitizeTraceArray(this.readPipelineState(RECENT_DREAM_TRACES_STATE_KEY, []), "dreamTraceId", "startedAt").slice(0, Math.max(1, limit));
    }
    getDreamTrace(dreamTraceId) {
        return this.listRecentDreamTraces(200).find((item) => item.dreamTraceId === dreamTraceId);
    }
    getIndexingSettings(defaults) {
        return sanitizeIndexingSettings(this.getPipelineState(INDEXING_SETTINGS_STATE_KEY), defaults);
    }
    saveIndexingSettings(partial, defaults) {
        const current = this.getIndexingSettings(defaults);
        const next = sanitizeIndexingSettings({ ...current, ...partial }, defaults);
        this.setPipelineState(INDEXING_SETTINGS_STATE_KEY, next);
        return next;
    }
    buildTransferCounts(store) {
        const imported = store.exportBundleRecords({ includeTmp: true });
        return {
            managedFiles: store.exportSnapshotFiles().length,
            memoryFiles: imported.memoryFiles.length,
            project: imported.memoryFiles.filter((item) => item.type === "project").length,
            feedback: imported.memoryFiles.filter((item) => item.type === "feedback").length,
            user: imported.memoryFiles.filter((item) => item.type === "user").length,
            tmp: 0,
            projectMetas: imported.projectMetas.length,
        };
    }
    materializeSnapshotBundle(rootDir, bundle) {
        mkdirSync(rootDir, { recursive: true });
        for (const record of bundle.files) {
            const absolutePath = resolve(rootDir, record.relativePath);
            if (!isPathWithinRoot(rootDir, absolutePath) || absolutePath === resolve(rootDir)) {
                throw new MemoryBundleValidationError(`Invalid imported snapshot file path: ${record.relativePath}`);
            }
            mkdirSync(dirname(absolutePath), { recursive: true });
            writeFileSync(absolutePath, record.content, "utf-8");
        }
        const store = new FileMemoryStore(rootDir);
        store.repairManifests();
        return store;
    }
    stageImportBundle(bundle) {
        const liveRoot = this.fileMemory.getRootDir();
        const stagedRoot = createSiblingTempPath(liveRoot, "import");
        mkdirSync(stagedRoot, { recursive: true });
        try {
            const stagedStore = this.materializeSnapshotBundle(stagedRoot, bundle);
            return {
                stagedRoot,
                counts: this.buildTransferCounts(stagedStore),
            };
        }
        catch (error) {
            rmSync(stagedRoot, { recursive: true, force: true });
            throw error;
        }
    }
    swapInStagedMemoryRoot(stagedRoot) {
        const liveRoot = this.fileMemory.getRootDir();
        const backupRoot = createSiblingTempPath(liveRoot, "backup");
        let movedLiveRoot = false;
        try {
            if (existsSync(liveRoot)) {
                renameSync(liveRoot, backupRoot);
                movedLiveRoot = true;
            }
            renameSync(stagedRoot, liveRoot);
        }
        catch (error) {
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
            }
            catch {
                // Best-effort cleanup; the live memory root has already been swapped in.
            }
        }
    }
    resetImportedRuntimeState(bundle) {
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
        if (bundle.lastIndexedAt)
            this.setPipelineState(LAST_INDEXED_AT_STATE_KEY, bundle.lastIndexedAt);
        if (bundle.lastDreamAt)
            this.setPipelineState(LAST_DREAM_AT_STATE_KEY, bundle.lastDreamAt);
        if (bundle.lastDreamStatus)
            this.setPipelineState(LAST_DREAM_STATUS_STATE_KEY, bundle.lastDreamStatus);
        if (bundle.lastDreamSummary)
            this.setPipelineState(LAST_DREAM_SUMMARY_STATE_KEY, bundle.lastDreamSummary);
        if (bundle.recentCaseTraces)
            this.setPipelineState(RECENT_CASE_TRACES_STATE_KEY, bundle.recentCaseTraces);
        if (bundle.recentIndexTraces)
            this.setPipelineState(RECENT_INDEX_TRACES_STATE_KEY, bundle.recentIndexTraces);
        if (bundle.recentDreamTraces)
            this.setPipelineState(RECENT_DREAM_TRACES_STATE_KEY, bundle.recentDreamTraces);
    }
    exportMemoryBundle() {
        return {
            formatVersion: MEMORY_EXPORT_FORMAT_VERSION,
            exportedAt: nowIso(),
            ...(typeof this.getPipelineState(LAST_INDEXED_AT_STATE_KEY) === "string"
                ? { lastIndexedAt: this.getPipelineState(LAST_INDEXED_AT_STATE_KEY) }
                : {}),
            ...(typeof this.getPipelineState(LAST_DREAM_AT_STATE_KEY) === "string"
                ? { lastDreamAt: this.getPipelineState(LAST_DREAM_AT_STATE_KEY) }
                : {}),
            ...(sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))
                ? { lastDreamStatus: sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY)) }
                : {}),
            ...(typeof this.getPipelineState(LAST_DREAM_SUMMARY_STATE_KEY) === "string"
                ? { lastDreamSummary: this.getPipelineState(LAST_DREAM_SUMMARY_STATE_KEY) }
                : {}),
            ...(this.listRecentCaseTraces(200).length > 0 ? { recentCaseTraces: this.listRecentCaseTraces(200) } : {}),
            ...(this.listRecentIndexTraces(200).length > 0 ? { recentIndexTraces: this.listRecentIndexTraces(200) } : {}),
            ...(this.listRecentDreamTraces(200).length > 0 ? { recentDreamTraces: this.listRecentDreamTraces(200) } : {}),
            files: this.fileMemory.exportSnapshotFiles(),
        };
    }
    importMemoryBundle(bundle) {
        const normalized = normalizeMemoryBundle(bundle);
        const staged = this.stageImportBundle(normalized);
        this.swapInStagedMemoryRoot(staged.stagedRoot);
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
    getOverview() {
        const pendingSessions = Number(this.db.prepare("SELECT COUNT(DISTINCT session_key) AS count FROM l0_sessions WHERE indexed = 0").get()?.count ?? 0);
        const lastDreamAt = this.getPipelineState(LAST_DREAM_AT_STATE_KEY);
        const fileOverview = this.fileMemory.getOverview(typeof lastDreamAt === "string" ? lastDreamAt : undefined);
        const recentRecallTraceCount = this.listRecentCaseTraces(12).length;
        const recentIndexTraceCount = this.listRecentIndexTraces(30).length;
        const recentDreamTraceCount = this.listRecentDreamTraces(30).length;
        const workspaceHasProjectMemory = fileOverview.projectMemories + fileOverview.feedbackMemories > 0;
        const userProfileCount = this.fileMemory.listMemoryEntries({
            kinds: ["user"],
            scope: "global",
            limit: 10,
        }).some((entry) => entry.relativePath === "global/User/user-profile.md")
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
            ...(typeof this.getPipelineState(LAST_INDEXED_AT_STATE_KEY) === "string"
                ? { lastIndexedAt: this.getPipelineState(LAST_INDEXED_AT_STATE_KEY) }
                : {}),
            ...(typeof lastDreamAt === "string" ? { lastDreamAt } : {}),
            ...(sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY))
                ? { lastDreamStatus: sanitizeDreamStatus(this.getPipelineState(LAST_DREAM_STATUS_STATE_KEY)) }
                : {}),
            ...(typeof this.getPipelineState(LAST_DREAM_SUMMARY_STATE_KEY) === "string"
                ? { lastDreamSummary: this.getPipelineState(LAST_DREAM_SUMMARY_STATE_KEY) }
                : {}),
        };
    }
    getUiSnapshot(limit = 50) {
        return {
            overview: this.getOverview(),
            settings: this.getIndexingSettings({
                reasoningMode: "answer_first",
                autoIndexIntervalMinutes: 60,
                autoDreamIntervalMinutes: 360,
            }),
            recentMemoryFiles: this.fileMemory.listMemoryEntries({ limit }),
        };
    }
    listMemoryEntries(options = {}) {
        return this.fileMemory.listMemoryEntries(options);
    }
    countMemoryEntries(options = {}) {
        return this.fileMemory.countMemoryEntries(options);
    }
    getMemoryRecordsByIds(ids, maxLines = 80) {
        return this.fileMemory.getMemoryRecordsByIds(ids, maxLines);
    }
    editProjectMeta(input) {
        return this.fileMemory.editProjectMeta(input);
    }
    ensureProjectMeta(input = {}) {
        return this.fileMemory.ensureProjectMeta(input);
    }
    getProjectMeta() {
        return this.fileMemory.getProjectMeta();
    }
    editMemoryEntry(input) {
        return this.fileMemory.editEntry({
            relativePath: input.id,
            name: input.name,
            description: input.description,
            ...(input.fields ? { fields: input.fields } : {}),
        });
    }
    deleteMemoryEntries(ids) {
        return this.fileMemory.deleteEntries(ids);
    }
    deprecateMemoryEntries(ids) {
        return this.fileMemory.markEntriesDeprecated(ids);
    }
    restoreMemoryEntries(ids) {
        return this.fileMemory.restoreEntries(ids);
    }
    archiveTmpEntries(input) {
        return this.fileMemory.archiveTmpEntries({
            relativePaths: input.ids,
            ...(input.targetProjectId ? { targetProjectId: input.targetProjectId } : {}),
            ...(input.newProjectName ? { newProjectName: input.newProjectName } : {}),
        });
    }
    getSnapshotVersion() {
        return this.fileMemory.getSnapshotVersion(this.getPipelineState(LAST_DREAM_AT_STATE_KEY));
    }
    clearAllMemoryData() {
        const l0Sessions = Number(this.db.prepare("SELECT COUNT(*) AS count FROM l0_sessions").get()?.count ?? 0);
        const pipelineState = Number(this.db.prepare("SELECT COUNT(*) AS count FROM pipeline_state").get()?.count ?? 0);
        const before = this.fileMemory.exportBundleRecords({ includeTmp: true });
        this.db.exec(`
      DELETE FROM l0_sessions;
      DELETE FROM pipeline_state;
    `);
        this.fileMemory.clearAllData();
        return {
            cleared: {
                l0Sessions,
                pipelineState,
                memoryFiles: before.memoryFiles.length,
                projectMetas: before.projectMetas.length,
            },
            clearedAt: nowIso(),
        };
    }
}
