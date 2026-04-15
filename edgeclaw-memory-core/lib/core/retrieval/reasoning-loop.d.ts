import type { IndexingSettings, MemoryMessage, RetrievalResult, RecallMode } from "../types.js";
import { LlmMemoryExtractor } from "../skills/llm-extraction.js";
import { MemoryRepository } from "../storage/sqlite.js";
export interface RetrievalOptions {
    retrievalMode?: "auto" | "explicit";
    recentMessages?: MemoryMessage[];
    workspaceHint?: string;
}
export interface RetrievalRuntimeOptions {
    getSettings?: () => IndexingSettings;
    isBackgroundBusy?: () => boolean;
}
export interface RetrievalRuntimeStats {
    lastRecallMs: number;
    recallTimeouts: number;
    lastRecallMode: RecallMode;
    lastRecallPath: "auto" | "explicit" | "shadow";
    lastRecallInjected: boolean;
    lastRecallCacheHit: boolean;
}
export declare class ReasoningRetriever {
    private readonly repository;
    private readonly extractor;
    private readonly runtime;
    private readonly cache;
    private runtimeStats;
    constructor(repository: MemoryRepository, extractor: LlmMemoryExtractor, runtime?: RetrievalRuntimeOptions);
    getRuntimeStats(): RetrievalRuntimeStats;
    resetTransientState(): void;
    private currentSettings;
    private buildCacheKey;
    private getCachedResult;
    private saveCache;
    private updateRuntimeStats;
    retrieve(query: string, options?: RetrievalOptions): Promise<RetrievalResult>;
}
