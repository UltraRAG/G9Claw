import { type CaseTraceRecord, type DashboardOverview, type DreamTraceRecord, type IndexTraceRecord, type IndexingSettings, type L0SessionRecord, type MemoryExportBundle, type MemoryEntryEditFields, type MemoryFileRecord, type MemoryImportResult, type MemoryImportableBundle, type MemoryManifestEntry, type MemoryMessage, type MemoryUiSnapshot } from "../types.js";
import { FileMemoryStore } from "../file-memory.js";
export declare class MemoryBundleValidationError extends Error {
    constructor(message: string);
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
export declare class MemoryRepository {
    private readonly db;
    private readonly fileMemory;
    constructor(dbPath: string, options?: {
        memoryDir?: string;
    });
    private init;
    private migratePipelineStateTable;
    close(): void;
    getFileMemoryStore(): FileMemoryStore;
    private readPipelineState;
    getPipelineState<T = unknown>(key: string): T | undefined;
    setPipelineState(key: string, value: unknown): void;
    deletePipelineState(key: string): void;
    insertL0Session(record: L0SessionRecord): void;
    listPendingSessionKeys(limit?: number, preferredSessionKeys?: string[]): string[];
    listUnindexedL0BySession(sessionKey: string): L0SessionRecord[];
    getLatestL0Before(sessionKey: string, timestamp: string, createdAt: string): L0SessionRecord | undefined;
    markL0Indexed(ids: string[]): void;
    getL0ByIds(ids: string[]): L0SessionRecord[];
    listRecentL0(limit?: number, offset?: number): L0SessionRecord[];
    listAllL0(): L0SessionRecord[];
    repairL0Sessions(transform: (record: L0SessionRecord) => MemoryMessage[]): RepairMemoryResult;
    saveCaseTrace(record: CaseTraceRecord, limit?: number): void;
    listRecentCaseTraces(limit?: number): CaseTraceRecord[];
    getCaseTrace(caseId: string): CaseTraceRecord | undefined;
    saveIndexTrace(record: IndexTraceRecord, limit?: number): void;
    listRecentIndexTraces(limit?: number): IndexTraceRecord[];
    getIndexTrace(indexTraceId: string): IndexTraceRecord | undefined;
    saveDreamTrace(record: DreamTraceRecord, limit?: number): void;
    listRecentDreamTraces(limit?: number): DreamTraceRecord[];
    getDreamTrace(dreamTraceId: string): DreamTraceRecord | undefined;
    getIndexingSettings(defaults: IndexingSettings): IndexingSettings;
    saveIndexingSettings(partial: Partial<IndexingSettings>, defaults: IndexingSettings): IndexingSettings;
    private buildTransferCounts;
    private materializeSnapshotBundle;
    private stageImportBundle;
    private swapInStagedMemoryRoot;
    private resetImportedRuntimeState;
    exportMemoryBundle(): MemoryExportBundle;
    importMemoryBundle(bundle: MemoryImportableBundle): MemoryImportResult;
    getOverview(): DashboardOverview;
    getUiSnapshot(limit?: number): MemoryUiSnapshot;
    listMemoryEntries(options?: {
        kinds?: Array<"user" | "feedback" | "project">;
        query?: string;
        limit?: number;
        offset?: number;
        scope?: "global" | "project";
        projectId?: string;
        includeTmp?: boolean;
        includeDeprecated?: boolean;
    }): MemoryManifestEntry[];
    countMemoryEntries(options?: {
        kinds?: Array<"user" | "feedback" | "project">;
        query?: string;
        scope?: "global" | "project";
        projectId?: string;
        includeTmp?: boolean;
        includeDeprecated?: boolean;
    }): number;
    getMemoryRecordsByIds(ids: string[], maxLines?: number): MemoryFileRecord[];
    editProjectMeta(input: {
        projectId?: string;
        projectName: string;
        description: string;
        aliases?: string[];
        status: string;
    }): import("../types.js").ProjectMetaRecord;
    ensureProjectMeta(input?: {
        projectName?: string;
        description?: string;
        aliases?: string[];
        status?: string;
    }): import("../types.js").ProjectMetaRecord;
    getProjectMeta(): import("../types.js").ProjectMetaRecord | undefined;
    editMemoryEntry(input: {
        id: string;
        name: string;
        description: string;
        fields?: MemoryEntryEditFields;
    }): MemoryFileRecord;
    deleteMemoryEntries(ids: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    deprecateMemoryEntries(ids: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    restoreMemoryEntries(ids: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    archiveTmpEntries(input: {
        ids: string[];
        targetProjectId?: string;
        newProjectName?: string;
    }): {
        mutatedIds: string[];
        targetProjectId?: string;
        createdProjectId?: string;
    };
    getSnapshotVersion(): string;
    clearAllMemoryData(): ClearMemoryResult;
}
