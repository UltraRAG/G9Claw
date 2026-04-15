import type { MemoryCandidate, MemoryEntryEditFields, MemoryFileExportRecord, MemoryFileRecord, MemoryManifestEntry, MemoryRecordType, MemoryScope, MemorySnapshotFileRecord, MemoryUserSummary, ProjectIdentityHint, ProjectMetaExportRecord, ProjectMetaRecord, RecallHeaderEntry } from "./types.js";
export declare const TMP_PROJECT_ID = "_tmp";
export interface FileMemoryOverview {
    totalMemoryFiles: number;
    totalUserMemories: number;
    totalFeedbackMemories: number;
    totalProjectMemories: number;
    tmpTotalFiles: number;
    tmpFeedbackMemories: number;
    tmpProjectMemories: number;
    changedFilesSinceLastDream: number;
}
export interface TmpCleanupResult {
    archived: number;
    deleted: number;
    kept: number;
    changedFiles: string[];
}
export declare class FileMemoryStore {
    private readonly rootDir;
    private repairingFormalProjectLayout;
    constructor(rootDir: string);
    getRootDir(): string;
    ensureLayout(): void;
    private globalManifestPath;
    private projectRoot;
    private projectManifestPath;
    private projectMetaPath;
    private scanProjectDirs;
    private listProjectMarkdownFiles;
    private projectSeedFromDir;
    private rewriteProjectRecordId;
    private ensureFormalProjectLayout;
    private readRecordFromPath;
    private readRecallHeaderEntryFromPath;
    private buildManifestEntriesForScope;
    rebuildManifest(scope: MemoryScope, projectId?: string): MemoryManifestEntry[];
    rebuildAllManifests(options?: {
        includeTmp?: boolean;
    }): MemoryManifestEntry[];
    private collectMemoryEntries;
    listMemoryEntries(options?: {
        kinds?: MemoryRecordType[];
        query?: string;
        limit?: number;
        offset?: number;
        scope?: MemoryScope;
        projectId?: string;
        includeTmp?: boolean;
        includeDeprecated?: boolean;
    }): MemoryManifestEntry[];
    countMemoryEntries(options?: {
        kinds?: MemoryRecordType[];
        query?: string;
        scope?: MemoryScope;
        projectId?: string;
        includeTmp?: boolean;
        includeDeprecated?: boolean;
    }): number;
    getMemoryRecordsByIds(ids: string[], maxLines?: number): MemoryFileRecord[];
    getFullMemoryRecordsByIds(ids: string[]): MemoryFileRecord[];
    getMemoryRecord(id: string, maxLines?: number): MemoryFileRecord | undefined;
    getUserSummary(): MemoryUserSummary;
    scanRecallHeaderEntries(options: {
        projectId: string;
        kinds?: MemoryRecordType[];
        limit?: number;
        maxLines?: number;
    }): RecallHeaderEntry[];
    listProjectIds(options?: {
        includeTmp?: boolean;
    }): string[];
    listProjectMetas(options?: {
        includeTmp?: boolean;
    }): ProjectMetaRecord[];
    listProjectIdentityHints(options?: {
        includeTmp?: boolean;
        limit?: number;
    }): ProjectIdentityHint[];
    getProjectMeta(projectId: string): ProjectMetaRecord | undefined;
    hasVisibleProjectMemory(projectId: string): boolean;
    private hasAnyProjectMemoryFiles;
    private cleanupFormalProjectAfterMutation;
    editProjectMeta(input: {
        projectId: string;
        projectName: string;
        description: string;
        aliases?: string[];
        status: string;
    }): ProjectMetaRecord;
    private rewriteRecord;
    private rewriteRecordFrontmatter;
    editEntry(input: {
        relativePath: string;
        name: string;
        description: string;
        fields?: MemoryEntryEditFields;
    }): MemoryFileRecord;
    markEntriesDeprecated(relativePaths: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    restoreEntries(relativePaths: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    deleteEntries(relativePaths: string[]): {
        mutatedIds: string[];
        deletedProjectIds: string[];
    };
    archiveTmpEntries(input: {
        relativePaths: string[];
        targetProjectId?: string;
        newProjectName?: string;
    }): {
        mutatedIds: string[];
        targetProjectId: string;
        createdProjectId?: string;
    };
    exportBundleRecords(options?: {
        includeTmp?: boolean;
    }): {
        projectMetas: ProjectMetaExportRecord[];
        memoryFiles: MemoryFileExportRecord[];
    };
    exportSnapshotFiles(): MemorySnapshotFileRecord[];
    clearAllData(): void;
    private writeImportedProjectMeta;
    private writeImportedMemoryFile;
    replaceFromBundle(bundle: {
        projectMetas: ProjectMetaExportRecord[];
        memoryFiles: MemoryFileExportRecord[];
    }): {
        projectMetas: ProjectMetaRecord[];
        memoryFiles: MemoryFileRecord[];
    };
    upsertProjectMeta(input: {
        projectId: string;
        projectName: string;
        description: string;
        aliases?: string[];
        status?: string;
        dreamUpdatedAt?: string;
    }): ProjectMetaRecord;
    createStableProjectId(seed: string): string;
    listTmpEntries(limit?: number): MemoryManifestEntry[];
    private renderCandidateBody;
    private buildCandidateLocation;
    upsertCandidate(candidate: MemoryCandidate): MemoryFileRecord;
    toCandidate(record: MemoryFileRecord): MemoryCandidate;
    promoteTmpRecord(relativePath: string, projectId: string): MemoryFileRecord | undefined;
    incrementDreamAttempts(relativePath: string): MemoryFileRecord | undefined;
    buildFormalCandidateRelativePath(projectId: string, candidate: MemoryCandidate): string;
    writeCandidateToRelativePath(relativePath: string, candidate: MemoryCandidate): MemoryFileRecord;
    deleteRecords(relativePaths: string[]): string[];
    deleteProject(projectId: string): boolean;
    cleanupTmpEntries(options?: {
        maxDreamAttempts?: number;
        olderThanMs?: number;
        archive?: boolean;
    }): TmpCleanupResult;
    archiveRecord(entry: MemoryManifestEntry): void;
    deleteRecord(entry: MemoryManifestEntry): void;
    getOverview(lastDreamAt?: string): FileMemoryOverview;
    getSnapshotVersion(lastDreamAt?: string): string;
    repairManifests(): {
        changed: number;
        summary: string;
        memoryFileCount: number;
    };
    mergeDuplicateEntries(entries: MemoryManifestEntry[]): {
        merged: number;
        changedFiles: string[];
    };
    getFileUpdatedAt(relativePath: string): string | undefined;
}
