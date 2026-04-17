import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import {
  type ClearMemoryResult,
  type DreamRunResult,
  DreamRewriteRunner,
  type HeartbeatStats,
  HeartbeatIndexer,
  type IndexingSettings,
  LlmMemoryExtractor,
  type MemoryActionRequest,
  type MemoryActionResult,
  type MemoryExportBundle,
  type MemoryImportResult,
  type MemoryImportableBundle,
  type MemoryMessage,
  type MemoryRecordType,
  type MemoryUiSnapshot,
  MemoryRepository,
  type RetrievalResult,
  ReasoningRetriever,
  hashText,
  nowIso,
} from "./core/index.js";
import {
  normalizeMessages,
  type TranscriptMessageInfo,
  inspectTranscriptMessage,
} from "./message-utils.js";

type LoggerLike = {
  info?: (...args: unknown[]) => void;
  warn?: (...args: unknown[]) => void;
  error?: (...args: unknown[]) => void;
};

export type EdgeClawMemoryApiType =
  | "openai-responses"
  | "responses"
  | "openai-completions";

export interface EdgeClawMemoryLlmOptions {
  provider?: string;
  model?: string;
  modelRef?: string;
  apiType?: EdgeClawMemoryApiType;
  baseUrl?: string;
  apiKey?: string;
  headers?: Record<string, string>;
}

export interface EdgeClawMemoryServiceOptions {
  workspaceDir: string;
  rootDir?: string;
  dbPath?: string;
  memoryDir?: string;
  captureStrategy?: "last_turn" | "full_session";
  includeAssistant?: boolean;
  maxMessageChars?: number;
  heartbeatBatchSize?: number;
  defaultIndexingSettings?: Partial<IndexingSettings>;
  source?: string;
  llm?: EdgeClawMemoryLlmOptions;
  runtime?: Record<string, unknown>;
  logger?: LoggerLike;
}

export interface CaptureTurnResult {
  captured: boolean;
  normalizedMessages: MemoryMessage[];
  sessionKey: string;
}

export interface RetrieveContextResult extends RetrievalResult {
  systemContext: string;
}

export interface MemoryListOptions {
  kinds?: MemoryRecordType[];
  query?: string;
  limit?: number;
  offset?: number;
  scope?: "global" | "project";
  includeDeprecated?: boolean;
}

type JsonRecord = Record<string, unknown>;

interface OpenClawResolvedModelConfig {
  provider: string;
  model: string;
  apiType?: EdgeClawMemoryApiType;
  baseUrl?: string;
  apiKey?: string;
  headers?: Record<string, string>;
}

const OPENCLAW_CONFIG_PATH = join(homedir(), ".openclaw", "openclaw.json");
let cachedOpenClawModelConfig: OpenClawResolvedModelConfig | null | undefined;

function normalizeText(value: string | undefined): string {
  return (value ?? "").trim();
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function getRecord(value: unknown, key: string): JsonRecord | undefined {
  if (!isRecord(value)) return undefined;
  const child = value[key];
  return isRecord(child) ? child : undefined;
}

function getString(value: unknown, key: string): string {
  if (!isRecord(value)) return "";
  const child = value[key];
  return typeof child === "string" ? child.trim() : "";
}

function toStringRecord(value: unknown): Record<string, string> | undefined {
  if (!isRecord(value)) return undefined;
  const entries = Object.entries(value).flatMap(([key, entryValue]) => {
    if (typeof entryValue !== "string") return [];
    const normalizedEntryValue = entryValue.trim();
    return normalizedEntryValue ? [[key, normalizedEntryValue] as const] : [];
  });
  if (entries.length === 0) return undefined;
  return Object.fromEntries(entries);
}

function parseModelRef(value: string | undefined): {
  provider?: string;
  model?: string;
} {
  const normalized = normalizeText(value);
  if (!normalized) return {};
  if (!normalized.includes("/")) {
    return { model: normalized };
  }
  const [provider, ...rest] = normalized.split("/");
  const model = rest.join("/").trim();
  return {
    provider: normalizeText(provider),
    model,
  };
}

function withEnvFallback(value: string | undefined, envKey: string): string {
  const explicit = normalizeText(value);
  if (explicit) return explicit;
  return normalizeText(process.env[envKey]);
}

function resolveDefaultRootDir(rootDir: string | undefined): string {
  return resolve(rootDir ? rootDir : join(homedir(), ".edgeclaw", "memory"));
}

function resolveWorkspaceDataDir(workspaceDir: string, rootDir: string): string {
  const seed = resolve(workspaceDir);
  const slug = hashText(seed);
  return join(rootDir, "workspaces", slug);
}

function resolveOpenClawModelConfig(): OpenClawResolvedModelConfig | null {
  if (cachedOpenClawModelConfig !== undefined) {
    return cachedOpenClawModelConfig;
  }

  try {
    if (!existsSync(OPENCLAW_CONFIG_PATH)) {
      cachedOpenClawModelConfig = null;
      return cachedOpenClawModelConfig;
    }

    const parsed = JSON.parse(readFileSync(OPENCLAW_CONFIG_PATH, "utf8")) as unknown;
    const providers = getRecord(getRecord(parsed, "models"), "providers");
    if (!providers) {
      cachedOpenClawModelConfig = null;
      return cachedOpenClawModelConfig;
    }

    const primaryModelRef = getString(
      getRecord(getRecord(getRecord(parsed, "agents"), "defaults"), "model"),
      "primary",
    );
    const parsedPrimary = parseModelRef(primaryModelRef);

    const availableProviders = Object.entries(providers).flatMap(([providerName, providerValue]) =>
      isRecord(providerValue) ? [[providerName, providerValue] as const] : []);
    if (availableProviders.length === 0) {
      cachedOpenClawModelConfig = null;
      return cachedOpenClawModelConfig;
    }

    const providerEntry = (
      parsedPrimary.provider
        ? availableProviders.find(([providerName]) => providerName === parsedPrimary.provider)
        : undefined
    ) ?? availableProviders[0];
    if (!providerEntry) {
      cachedOpenClawModelConfig = null;
      return cachedOpenClawModelConfig;
    }

    const [provider, providerConfig] = providerEntry;
    const providerModels = Array.isArray(providerConfig["models"])
      ? providerConfig["models"].filter(isRecord)
      : [];
    const selectedModel = (
      parsedPrimary.model
        ? providerModels.find(modelEntry =>
            getString(modelEntry, "id") === parsedPrimary.model
            || getString(modelEntry, "name") === parsedPrimary.model)
        : undefined
    ) ?? providerModels[0];

    const model = parsedPrimary.model
      || getString(selectedModel, "id")
      || getString(selectedModel, "name");
    if (!model) {
      cachedOpenClawModelConfig = null;
      return cachedOpenClawModelConfig;
    }

    const headers = {
      ...(toStringRecord(providerConfig["headers"]) ?? {}),
      ...(toStringRecord(selectedModel?.["headers"]) ?? {}),
    };

    cachedOpenClawModelConfig = {
      provider,
      model,
      apiType: (getString(selectedModel, "api") || getString(providerConfig, "api") || undefined) as
        | EdgeClawMemoryApiType
        | undefined,
      baseUrl: getString(selectedModel, "baseUrl") || getString(providerConfig, "baseUrl") || undefined,
      apiKey: getString(providerConfig, "apiKey") || undefined,
      ...(Object.keys(headers).length > 0 ? { headers } : {}),
    };
  } catch {
    cachedOpenClawModelConfig = null;
  }

  return cachedOpenClawModelConfig;
}

function buildLlmConfig(options: EdgeClawMemoryLlmOptions | undefined): Record<string, unknown> {
  const openClawModel = resolveOpenClawModelConfig();
  const parsedModelRef = parseModelRef(
    normalizeText(options?.modelRef) || normalizeText(process.env.EDGECLAW_MEMORY_MODEL),
  );
  const provider = normalizeText(options?.provider)
    || normalizeText(process.env.EDGECLAW_MEMORY_PROVIDER)
    || parsedModelRef.provider
    || openClawModel?.provider
    || "edgeclaw_memory";
  const model = normalizeText(options?.model)
    || parsedModelRef.model
    || openClawModel?.model
    || normalizeText(process.env.OPENAI_MODEL);
  const usingOpenClawSelection = Boolean(
    openClawModel
    && provider === openClawModel.provider
    && model === openClawModel.model,
  );
  const baseUrl = normalizeText(options?.baseUrl)
    || normalizeText(process.env.EDGECLAW_MEMORY_BASE_URL)
    || (usingOpenClawSelection ? normalizeText(openClawModel?.baseUrl) : "")
    || normalizeText(process.env.OPENAI_BASE_URL);
  const apiKey = normalizeText(options?.apiKey)
    || normalizeText(process.env.EDGECLAW_MEMORY_API_KEY)
    || (usingOpenClawSelection ? normalizeText(openClawModel?.apiKey) : "")
    || normalizeText(process.env.OPENAI_API_KEY);
  const apiType = (
    normalizeText(options?.apiType)
    || normalizeText(process.env.EDGECLAW_MEMORY_API_TYPE)
    || (usingOpenClawSelection ? normalizeText(openClawModel?.apiType) : "")
    || "openai-responses"
  ) as EdgeClawMemoryApiType;
  const headers = {
    ...(usingOpenClawSelection ? openClawModel?.headers ?? {} : {}),
    ...(options?.headers ?? {}),
  };

  return {
    agents: {
      defaults: {
        model: {
          primary: model ? `${provider}/${model}` : "",
        },
      },
    },
    models: {
      providers: {
        [provider]: {
          ...(apiKey ? { apiKey } : {}),
          ...(baseUrl ? { baseUrl } : {}),
          api: apiType,
          models: model
            ? [
                {
                  id: model,
                  api: apiType,
                  ...(baseUrl ? { baseUrl } : {}),
                  ...(Object.keys(headers).length > 0 ? { headers } : {}),
                },
              ]
            : [],
          ...(Object.keys(headers).length > 0 ? { headers } : {}),
        },
      },
    },
  };
}

function mergeIndexingSettings(
  partial: Partial<IndexingSettings> | undefined,
): IndexingSettings {
  return {
    reasoningMode: partial?.reasoningMode === "accuracy_first" ? "accuracy_first" : "answer_first",
    autoIndexIntervalMinutes: typeof partial?.autoIndexIntervalMinutes === "number"
      ? Math.max(0, Math.floor(partial.autoIndexIntervalMinutes))
      : 60,
    autoDreamIntervalMinutes: typeof partial?.autoDreamIntervalMinutes === "number"
      ? Math.max(0, Math.floor(partial.autoDreamIntervalMinutes))
      : 360,
  };
}

function resolveConfiguredDataDir(options: EdgeClawMemoryServiceOptions, fallbackDir: string): string {
  if (options.dbPath) {
    return resolve(dirname(resolve(options.dbPath)));
  }
  if (options.memoryDir) {
    return resolve(dirname(resolve(options.memoryDir)));
  }
  return fallbackDir;
}

function parseTimestamp(value: string | undefined): number | null {
  const parsed = Date.parse(value ?? "");
  return Number.isFinite(parsed) ? parsed : null;
}

function hasElapsedMinutes(
  lastRunAt: string | undefined,
  intervalMinutes: number,
  nowMs: number,
): boolean {
  if (intervalMinutes <= 0) return false;
  const lastRunMs = parseTimestamp(lastRunAt);
  if (lastRunMs === null) return true;
  return nowMs - lastRunMs >= intervalMinutes * 60_000;
}

function toMessages(rawMessages: readonly unknown[], options: {
  includeAssistant: boolean;
  maxMessageChars: number;
  captureStrategy: "last_turn" | "full_session";
}): MemoryMessage[] {
  return normalizeMessages([...rawMessages], options);
}

export function buildMemoryRecallSystemContext(evidenceBlock: string): string {
  return [
    "## ClawXMemory Recall",
    "Use the following retrieved ClawXMemory evidence for this turn.",
    evidenceBlock.trim(),
  ].filter(Boolean).join("\n\n");
}

export function buildEdgeClawMemoryPromptSection(options: {
  availableTools?: Iterable<string>;
  citationsMode?: "off" | "on";
} = {}): string | null {
  const availableTools = new Set(options.availableTools ?? []);
  const citationsMode = options.citationsMode ?? "off";
  const hasMemoryOverview = availableTools.has("memory_overview");
  const hasMemoryList = availableTools.has("memory_list");
  const hasMemorySearch = availableTools.has("memory_search");
  const hasMemoryGet = availableTools.has("memory_get");
  const hasMemoryFlush = availableTools.has("memory_flush");
  const hasMemoryDream = availableTools.has("memory_dream");

  if (
    !hasMemoryOverview
    && !hasMemoryList
    && !hasMemorySearch
    && !hasMemoryGet
    && !hasMemoryFlush
    && !hasMemoryDream
  ) {
    return null;
  }

  const lines = [
    "## ClawXMemory",
    hasMemoryOverview
      ? "Use memory_overview for memory status, freshness, indexing backlog, and runtime health questions."
      : undefined,
    hasMemoryList
      ? "Use memory_list to browse file-based user, feedback, and project memory indexes."
      : undefined,
    hasMemorySearch && hasMemoryGet
      ? "For durable preferences, collaboration rules, or project progress across sessions: run memory_search first, then use memory_get only for the exact file ids you need to verify."
      : hasMemorySearch
        ? "For durable preferences, collaboration rules, or project progress across sessions: run memory_search before answering."
        : hasMemoryGet
          ? "Use memory_get only when the user already gave you specific memory file ids to inspect."
          : undefined,
    hasMemoryFlush
      ? "If the user wants recent memory extracted now or asks why a just-finished conversation is not visible yet, run memory_flush."
      : undefined,
    hasMemoryDream
      ? "If the user wants memory cleanup, duplicate merge, or manifest repair, run memory_dream."
      : undefined,
    "Treat injected ClawXMemory recall context and memory file tools as the authoritative long-term memory source for the current turn.",
    "ClawXMemory uses file-based memory manifests and memory files as its durable memory source.",
    "Do not create or maintain long-term memory in workspace files such as memory/*.md, USER.md, or MEMORY.md, and do not write directly into ClawXMemory's managed memory directory. Use ClawXMemory's managed memory flow instead.",
    "Never call write, edit, move, rename, or delete tools on workspace memory files or ClawXMemory-managed memory paths. Those paths are reserved for ClawXMemory runtime ownership.",
    citationsMode === "off"
      ? "Citations are disabled: do not mention file paths or line numbers unless the user explicitly asks."
      : "When verification matters, cite the exact ClawXMemory records you used.",
  ].filter((line): line is string => Boolean(line));

  return `${lines.join("\n")}\n`;
}

export class EdgeClawMemoryService {
  readonly workspaceDir: string;
  readonly dataDir: string;
  readonly dbPath: string;
  readonly memoryDir: string;
  readonly defaultIndexingSettings: IndexingSettings;
  readonly repository: MemoryRepository;
  readonly extractor: LlmMemoryExtractor;
  readonly indexer: HeartbeatIndexer;
  readonly retriever: ReasoningRetriever;
  readonly dreamRewriter: DreamRewriteRunner;

  private readonly logger?: LoggerLike;
  private readonly captureStrategy: "last_turn" | "full_session";
  private readonly includeAssistant: boolean;
  private readonly maxMessageChars: number;
  private readonly source: string;
  private maintenancePromise: Promise<void> | null = null;
  private maintenanceQueued = false;

  private projectMetaSeed() {
    const projectName = basename(this.workspaceDir) || "Current Project";
    return {
      projectName,
      description: `${projectName} workspace memory`,
      aliases: [projectName],
      status: "in_progress" as const,
    };
  }

  constructor(options: EdgeClawMemoryServiceOptions) {
    this.workspaceDir = resolve(options.workspaceDir);
    const rootDir = resolveDefaultRootDir(options.rootDir);
    this.dataDir = resolveConfiguredDataDir(
      options,
      resolveWorkspaceDataDir(this.workspaceDir, rootDir),
    );
    this.dbPath = resolve(options.dbPath ?? join(this.dataDir, "control.sqlite"));
    this.memoryDir = resolve(options.memoryDir ?? join(this.dataDir, "memory"));
    this.defaultIndexingSettings = mergeIndexingSettings(options.defaultIndexingSettings);
    this.logger = options.logger;
    this.captureStrategy = options.captureStrategy ?? "last_turn";
    this.includeAssistant = options.includeAssistant ?? true;
    this.maxMessageChars = options.maxMessageChars ?? 6000;
    this.source = options.source ?? "edgeclaw";

    this.repository = new MemoryRepository(this.dbPath, {
      memoryDir: this.memoryDir,
      globalRootDir: join(rootDir, "global"),
    });
    this.repository.ensureProjectMeta(this.projectMetaSeed());
    this.extractor = new LlmMemoryExtractor(
      buildLlmConfig(options.llm),
      options.runtime,
      this.logger,
    );
    this.indexer = new HeartbeatIndexer(this.repository, this.extractor, {
      settings: this.repository.getIndexingSettings(this.defaultIndexingSettings),
      batchSize: options.heartbeatBatchSize ?? 30,
      source: this.source,
      logger: this.logger,
    });
    this.retriever = new ReasoningRetriever(this.repository, this.extractor, {
      getSettings: () => this.getSettings(),
    });
    this.dreamRewriter = new DreamRewriteRunner(this.repository, this.extractor, {
      logger: this.logger,
    });
  }

  close(): void {
    this.repository.close();
  }

  getSettings(): IndexingSettings {
    return this.repository.getIndexingSettings(this.defaultIndexingSettings);
  }

  saveSettings(partial: Partial<IndexingSettings>): IndexingSettings {
    const settings = this.repository.saveIndexingSettings(partial, this.defaultIndexingSettings);
    this.indexer.setSettings(settings);
    this.retriever.resetTransientState();
    return settings;
  }

  overview() {
    return this.repository.getOverview();
  }

  snapshot(limit = 50): MemoryUiSnapshot {
    return this.repository.getUiSnapshot(limit);
  }

  captureTurn(
    rawMessages: readonly unknown[],
    input: {
      sessionKey: string;
      timestamp?: string;
      source?: string;
    },
  ): CaptureTurnResult {
    const normalizedMessages = toMessages(rawMessages, {
      includeAssistant: this.includeAssistant,
      maxMessageChars: this.maxMessageChars,
      captureStrategy: this.captureStrategy,
    });
    if (normalizedMessages.length === 0) {
      return {
        captured: false,
        normalizedMessages,
        sessionKey: input.sessionKey,
      };
    }

    this.indexer.captureL0Session({
      sessionKey: input.sessionKey,
      timestamp: input.timestamp ?? nowIso(),
      messages: normalizedMessages,
      source: input.source ?? this.source,
    });

    return {
      captured: true,
      normalizedMessages,
      sessionKey: input.sessionKey,
    };
  }

  scheduleMaintenance(reason = "turn_capture"): void {
    if (this.maintenancePromise) {
      this.maintenanceQueued = true;
      return;
    }

    this.maintenancePromise = this.runScheduledMaintenance(reason)
      .catch((error) => {
        this.logger?.warn?.(
          `[edgeclaw-memory] scheduled maintenance failed: ${String(error)}`,
        );
      })
      .finally(() => {
        this.maintenancePromise = null;
        if (this.maintenanceQueued) {
          this.maintenanceQueued = false;
          this.scheduleMaintenance("queued_turn_capture");
        }
      });
  }

  async flush(options: {
    batchSize?: number;
    sessionKeys?: string[];
    reason?: string;
  } = {}): Promise<HeartbeatStats> {
    const stats = await this.indexer.runHeartbeat(options);
    this.retriever.resetTransientState();
    return stats;
  }

  async dream(trigger: "manual" | "scheduled" = "manual"): Promise<DreamRunResult> {
    const prepFlush = await this.flush({
      reason: trigger === "manual" ? "manual_dream_prep" : "scheduled_dream_prep",
    });
    const outcome = await this.dreamRewriter.run(trigger);
    this.repository.getFileMemoryStore().repairManifests();
    this.retriever.resetTransientState();
    return {
      prepFlush,
      ...outcome,
      trigger,
      status: "success",
    };
  }

  async retrieve(
    query: string,
    options: {
      recentMessages?: MemoryMessage[];
      workspaceHint?: string;
      retrievalMode?: "auto" | "explicit";
    } = {},
  ): Promise<RetrievalResult> {
    return this.retriever.retrieve(query, options);
  }

  async retrieveContext(
    query: string,
    options: {
      recentMessages?: MemoryMessage[];
      workspaceHint?: string;
      retrievalMode?: "auto" | "explicit";
    } = {},
  ): Promise<RetrieveContextResult> {
    const result = await this.retrieve(query, options);
    return {
      ...result,
      systemContext: result.context ? buildMemoryRecallSystemContext(result.context) : "",
    };
  }

  private async runScheduledMaintenance(reason: string): Promise<void> {
    const settings = this.getSettings();
    const nowMs = Date.now();
    let overview = this.overview();

    if (
      overview.pendingSessions > 0
      && hasElapsedMinutes(
        overview.lastIndexedAt,
        settings.autoIndexIntervalMinutes,
        nowMs,
      )
    ) {
      await this.flush({
        reason: `scheduled:${reason}`,
      });
      overview = this.overview();
    }

    const changedFilesSinceLastDream = this.repository
      .getFileMemoryStore()
      .getOverview(overview.lastDreamAt)
      .changedFilesSinceLastDream;

    if (
      changedFilesSinceLastDream > 0
      && hasElapsedMinutes(
        overview.lastDreamAt,
        settings.autoDreamIntervalMinutes,
        nowMs,
      )
    ) {
      await this.dream("scheduled");
    }
  }

  async search(query: string, options: {
    recentMessages?: MemoryMessage[];
    workspaceHint?: string;
  } = {}): Promise<RetrievalResult> {
    return this.retrieve(query, {
      ...options,
      retrievalMode: "explicit",
    });
  }

  list(options: MemoryListOptions = {}) {
    return this.repository.listMemoryEntries(options);
  }

  get(ids: string[], maxLines = 80) {
    return this.repository.getMemoryRecordsByIds(ids, maxLines);
  }

  getUserSummary() {
    return this.repository.getUserSummary();
  }

  getProjectMeta() {
    return this.repository.getProjectMeta();
  }

  updateProjectMeta(input: {
    projectName: string;
    description: string;
    aliases?: string[];
    status: string;
  }) {
    return this.repository.editProjectMeta(input);
  }

  getSnapshotVersion() {
    return this.repository.getSnapshotVersion();
  }

  listCaseTraces(limit = 30) {
    return this.repository.listRecentCaseTraces(limit);
  }

  getCaseTrace(caseId: string) {
    return this.repository.getCaseTrace(caseId);
  }

  listIndexTraces(limit = 30) {
    return this.repository.listRecentIndexTraces(limit);
  }

  getIndexTrace(indexTraceId: string) {
    return this.repository.getIndexTrace(indexTraceId);
  }

  listDreamTraces(limit = 30) {
    return this.repository.listRecentDreamTraces(limit);
  }

  getDreamTrace(dreamTraceId: string) {
    return this.repository.getDreamTrace(dreamTraceId);
  }

  exportBundle(): MemoryExportBundle {
    return this.repository.exportMemoryBundle();
  }

  importBundle(bundle: MemoryImportableBundle): MemoryImportResult {
    const result = this.repository.importMemoryBundle(bundle);
    this.indexer.setSettings(this.getSettings());
    this.retriever.resetTransientState();
    return result;
  }

  clear(): ClearMemoryResult {
    const result = this.repository.clearAllMemoryData();
    this.repository.ensureProjectMeta(this.projectMetaSeed());
    this.retriever.resetTransientState();
    return result;
  }

  act(input: MemoryActionRequest): MemoryActionResult {
    const messages: string[] = [];
    let mutatedIds: string[] = [];
    let deletedProjectIds: string[] = [];

    if (input.action === "edit_project_meta") {
      const meta = this.repository.editProjectMeta({
        projectName: input.projectName,
        description: input.description,
        aliases: input.aliases,
        status: input.status,
      });
      mutatedIds = [meta.relativePath];
      messages.push(`Updated current project metadata for ${meta.projectName}.`);
    } else if (input.action === "edit_entry") {
      const record = this.repository.editMemoryEntry({
        id: input.id,
        name: input.name,
        description: input.description,
        ...(input.fields ? { fields: input.fields } : {}),
      });
      mutatedIds = [record.relativePath];
      messages.push(`Updated memory entry ${record.name}.`);
    } else if (input.action === "delete_entries") {
      const result = this.repository.deleteMemoryEntries(input.ids);
      mutatedIds = result.mutatedIds;
      deletedProjectIds = result.deletedProjectIds;
      messages.push(`Deleted ${result.mutatedIds.length} memory file${result.mutatedIds.length === 1 ? "" : "s"}.`);
      if (deletedProjectIds.length > 0) {
        messages.push(`Removed ${deletedProjectIds.length} empty project${deletedProjectIds.length === 1 ? "" : "s"}.`);
      }
    } else if (input.action === "deprecate_entries") {
      const result = this.repository.deprecateMemoryEntries(input.ids);
      mutatedIds = result.mutatedIds;
      deletedProjectIds = result.deletedProjectIds;
      messages.push(`Deprecated ${result.mutatedIds.length} memory file${result.mutatedIds.length === 1 ? "" : "s"}.`);
    } else if (input.action === "restore_entries") {
      const result = this.repository.restoreMemoryEntries(input.ids);
      mutatedIds = result.mutatedIds;
      deletedProjectIds = result.deletedProjectIds;
      messages.push(`Restored ${result.mutatedIds.length} memory file${result.mutatedIds.length === 1 ? "" : "s"}.`);
    }

    this.retriever.resetTransientState();
    return {
      ok: true,
      action: input.action,
      updatedOverview: this.overview(),
      mutatedIds,
      deletedProjectIds,
      messages,
    };
  }
}

export function summarizeTranscriptMessage(raw: unknown): TranscriptMessageInfo {
  return inspectTranscriptMessage(raw);
}
