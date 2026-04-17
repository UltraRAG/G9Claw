import type {
  DreamTraceMutation,
  DreamTraceOutcome,
  DreamTraceRecord,
  DreamTraceStep,
  MemoryCandidate,
  MemoryFileRecord,
  RetrievalTraceDetail,
  TraceI18nText,
} from "../types.js";
import type { HeartbeatStats } from "../pipeline/heartbeat.js";
import {
  LlmMemoryExtractor,
  type LlmDreamFileProjectMetaInput,
  type LlmDreamFileProjectRewriteOutputFile,
  type LlmDreamFileRecordInput,
} from "../skills/llm-extraction.js";
import { MemoryRepository } from "../storage/sqlite.js";
import { traceI18n } from "../trace-i18n.js";
import { hashText, nowIso } from "../utils/id.js";

type LoggerLike = {
  info?: (...args: unknown[]) => void;
  warn?: (...args: unknown[]) => void;
  error?: (...args: unknown[]) => void;
};

interface DreamReviewRunnerOptions {
  logger?: LoggerLike;
}

export interface DreamRewriteOutcome {
  reviewedFiles: number;
  rewrittenProjects: number;
  deletedProjects: number;
  deletedFiles: number;
  profileUpdated: boolean;
  duplicateTopicCount: number;
  conflictTopicCount: number;
  summary: string;
}

export interface DreamRunResult extends DreamRewriteOutcome {
  prepFlush: HeartbeatStats;
  trigger?: "manual" | "scheduled";
  status?: "success" | "skipped";
  skipReason?: string;
}

function kvDetail(
  key: string,
  label: string,
  entries: Array<{ label: string; value: unknown }>,
  labelI18n?: TraceI18nText,
): RetrievalTraceDetail {
  return {
    key,
    label,
    ...(labelI18n ? { labelI18n } : {}),
    kind: "kv",
    entries: entries.map((entry) => ({
      label: entry.label,
      value: String(entry.value ?? ""),
    })),
  };
}

function listDetail(
  key: string,
  label: string,
  items: string[],
  labelI18n?: TraceI18nText,
): RetrievalTraceDetail {
  return {
    key,
    label,
    ...(labelI18n ? { labelI18n } : {}),
    kind: "list",
    items,
  };
}

function jsonDetail(
  key: string,
  label: string,
  json: unknown,
  labelI18n?: TraceI18nText,
): RetrievalTraceDetail {
  return {
    key,
    label,
    ...(labelI18n ? { labelI18n } : {}),
    kind: "json",
    json,
  };
}

function createDreamTrace(trigger: DreamTraceRecord["trigger"]): DreamTraceRecord {
  const startedAt = nowIso();
  return {
    dreamTraceId: `dream_trace_${hashText(`${trigger}:${startedAt}:${Math.random().toString(36).slice(2, 10)}`)}`,
    trigger,
    startedAt,
    status: "running",
    isNoOp: false,
    displayStatus: "Running",
    snapshotSummary: {
      projectMetaPresent: false,
      projectFileCount: 0,
      feedbackFileCount: 0,
      hasUserProfile: false,
    },
    steps: [],
    mutations: [],
    outcome: {
      rewrittenProjects: 0,
      deletedProjects: 0,
      deletedFiles: 0,
      profileUpdated: false,
      summary: "",
    },
  };
}

function pushStep(
  trace: DreamTraceRecord,
  kind: DreamTraceStep["kind"],
  title: string,
  status: DreamTraceStep["status"],
  inputSummary: string,
  outputSummary: string,
  options: {
    refs?: Record<string, unknown>;
    metrics?: Record<string, unknown>;
    details?: DreamTraceStep["details"];
    promptDebug?: DreamTraceStep["promptDebug"];
    titleI18n?: TraceI18nText;
    inputSummaryI18n?: TraceI18nText;
    outputSummaryI18n?: TraceI18nText;
  } = {},
): void {
  trace.steps.push({
    stepId: `${trace.dreamTraceId}:step:${trace.steps.length + 1}`,
    kind,
    title,
    status,
    inputSummary,
    outputSummary,
    ...(options.refs ? { refs: options.refs } : {}),
    ...(options.metrics ? { metrics: options.metrics } : {}),
    ...(options.details ? { details: options.details } : {}),
    ...(options.promptDebug ? { promptDebug: options.promptDebug } : {}),
    ...(options.titleI18n ? { titleI18n: options.titleI18n } : {}),
    ...(options.inputSummaryI18n ? { inputSummaryI18n: options.inputSummaryI18n } : {}),
    ...(options.outputSummaryI18n ? { outputSummaryI18n: options.outputSummaryI18n } : {}),
  });
}

function mutation(action: DreamTraceMutation["action"], relativePath: string): DreamTraceMutation {
  return {
    mutationId: `mutation_${hashText(`${action}:${relativePath}:${Date.now()}`)}`,
    action,
    relativePath,
  };
}

function toDreamRecordInput(
  store: MemoryRepository["getFileMemoryStore"] extends () => infer T ? T : never,
  record: MemoryFileRecord,
): LlmDreamFileRecordInput {
  const candidate = store.toCandidate(record);
  return {
    entryId: record.relativePath,
    relativePath: record.relativePath,
    type: record.type === "feedback" ? "feedback" : "project",
    scope: "project",
    projectId: record.projectId,
    isTmp: false,
    name: record.name,
    description: record.description,
    updatedAt: record.updatedAt,
    ...(record.capturedAt ? { capturedAt: record.capturedAt } : {}),
    ...(record.sourceSessionKey ? { sourceSessionKey: record.sourceSessionKey } : {}),
    content: record.content,
    ...(candidate.type === "project"
      ? {
          project: {
            stage: candidate.stage ?? "",
            decisions: candidate.decisions ?? [],
            constraints: candidate.constraints ?? [],
            nextSteps: candidate.nextSteps ?? [],
            blockers: candidate.blockers ?? [],
            timeline: candidate.timeline ?? [],
            notes: candidate.notes ?? [],
          },
        }
      : {}),
    ...(candidate.type === "feedback"
      ? {
          feedback: {
            rule: candidate.rule ?? "",
            why: candidate.why ?? "",
            howToApply: candidate.howToApply ?? "",
            notes: candidate.notes ?? [],
          },
        }
      : {}),
  };
}

function toCandidate(file: LlmDreamFileProjectRewriteOutputFile): MemoryCandidate {
  if (file.type === "feedback") {
    return {
      type: "feedback",
      scope: "project",
      name: file.name,
      description: file.description,
      rule: file.rule ?? file.description,
      why: file.why ?? "",
      howToApply: file.howToApply ?? "",
      notes: file.notes ?? [],
    };
  }
  return {
    type: "project",
    scope: "project",
    name: file.name,
    description: file.description,
    ...(file.stage ? { stage: file.stage } : {}),
    decisions: file.decisions ?? [],
    constraints: file.constraints ?? [],
    nextSteps: file.nextSteps ?? [],
    blockers: file.blockers ?? [],
    timeline: file.timeline ?? [],
    notes: file.notes ?? [],
  };
}

function sameUserSummary(left: {
  profile: string;
  preferences: string[];
  constraints: string[];
  relationships: string[];
}, right: {
  profile: string;
  preferences: string[];
  constraints: string[];
  relationships: string[];
}): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

export class DreamRewriteRunner {
  private readonly logger?: LoggerLike;

  constructor(
    private readonly repository: MemoryRepository,
    private readonly extractor: LlmMemoryExtractor,
    options: DreamReviewRunnerOptions = {},
  ) {
    this.logger = options.logger;
  }

  async run(trigger: DreamTraceRecord["trigger"] = "manual"): Promise<DreamRewriteOutcome> {
    const trace = createDreamTrace(trigger);
    const store = this.repository.getFileMemoryStore();
    const workspaceEntries = this.repository.listMemoryEntries({
      kinds: ["project", "feedback"],
      scope: "project",
      includeDeprecated: false,
      limit: 2000,
    });
    const projectMeta = store.getProjectMeta() ?? null;
    const userSummary = this.repository.getUserSummary();
    const userNoteEntries = this.repository.listMemoryEntries({
      kinds: ["user"],
      scope: "global",
      includeDeprecated: false,
      limit: 2000,
    }).filter((entry) => entry.relativePath !== "global/User/user-profile.md");
    const userNoteRecords = this.repository.getMemoryRecordsByIds(
      userNoteEntries.map((entry) => entry.relativePath),
      5000,
    );
    const userNoteCandidates = userNoteRecords.map((record) => this.repository.getGlobalUserStore().toCandidate(record));

    trace.snapshotSummary = {
      projectMetaPresent: Boolean(projectMeta),
      projectFileCount: workspaceEntries.filter((entry) => entry.type === "project").length,
      feedbackFileCount: workspaceEntries.filter((entry) => entry.type === "feedback").length,
      hasUserProfile: userSummary.files.length > 0,
    };

    pushStep(
      trace,
      "dream_start",
      "Dream Start",
      "info",
      `${trigger} dream run started.`,
      "Dream loaded the current project memory snapshot.",
      {
        titleI18n: traceI18n("trace.step.dream_start", "Dream Start"),
      },
    );

    pushStep(
      trace,
      "snapshot_loaded",
      "Snapshot Loaded",
      workspaceEntries.length > 0 || userSummary.files.length > 0 || userNoteRecords.length > 0 || Boolean(projectMeta) ? "success" : "warning",
      `${workspaceEntries.length} current project memory files`,
      workspaceEntries.length > 0 || userSummary.files.length > 0 || userNoteRecords.length > 0 || Boolean(projectMeta)
        ? "Current project memory is ready for Dream rewrite."
        : "No file-based memory exists yet, so Dream had nothing to organize.",
      {
        titleI18n: traceI18n("trace.step.snapshot_loaded", "Snapshot Loaded"),
        details: [
          kvDetail("snapshot-summary", "Snapshot Summary", [
            { label: "projectMetaPresent", value: trace.snapshotSummary.projectMetaPresent ? "yes" : "no" },
            { label: "projectFiles", value: trace.snapshotSummary.projectFileCount },
            { label: "feedbackFiles", value: trace.snapshotSummary.feedbackFileCount },
            { label: "hasUserProfile", value: trace.snapshotSummary.hasUserProfile ? "yes" : "no" },
            { label: "userNotes", value: userNoteRecords.length },
          ], traceI18n("trace.detail.snapshot_summary", "Snapshot Summary")),
          ...(projectMeta
            ? [jsonDetail("project-meta", "Project Meta", projectMeta, traceI18n("trace.detail.project_meta", "Project Meta"))]
            : []),
          listDetail(
            "snapshot-files",
            "Current Project Files",
            workspaceEntries.map((entry) => `${entry.relativePath} | ${entry.updatedAt}`),
            traceI18n("trace.detail.loaded_files", "Loaded Files"),
          ),
          ...(userNoteEntries.length > 0
            ? [listDetail(
                "snapshot-user-notes",
                "User Notes",
                userNoteEntries.map((entry) => `${entry.relativePath} | ${entry.updatedAt}`),
              )]
            : []),
        ],
      },
    );

    if (workspaceEntries.length === 0 && userSummary.files.length === 0 && userNoteRecords.length === 0) {
      const finishedAt = nowIso();
      const summary = "No file-based memory exists yet, so Dream had nothing to organize.";
      trace.finishedAt = finishedAt;
      trace.status = "completed";
      trace.isNoOp = true;
      trace.displayStatus = "No-op";
      trace.outcome = {
        rewrittenProjects: 0,
        deletedProjects: 0,
        deletedFiles: 0,
        profileUpdated: false,
        summary,
      };
      pushStep(
        trace,
        "dream_finished",
        "Dream Finished",
        "success",
        "No memory files",
        summary,
        {
          titleI18n: traceI18n("trace.step.dream_finished", "Dream Finished"),
        },
      );
      this.repository.setPipelineState("lastDreamAt", finishedAt);
      this.repository.setPipelineState("lastDreamStatus", "success");
      this.repository.setPipelineState("lastDreamSummary", summary);
      this.repository.saveDreamTrace(trace);
      return {
        reviewedFiles: 0,
        rewrittenProjects: 0,
        deletedProjects: 0,
        deletedFiles: 0,
        profileUpdated: false,
        duplicateTopicCount: 0,
        conflictTopicCount: 0,
        summary,
      };
    }

    const fullRecords = workspaceEntries.length > 0
      ? this.repository.getMemoryRecordsByIds(workspaceEntries.map((entry) => entry.relativePath), 5000)
      : [];
    const currentMeta = projectMeta ?? store.ensureProjectMeta();
    const rewriteInputMeta: LlmDreamFileProjectMetaInput = {
      projectId: currentMeta.projectId,
      projectName: currentMeta.projectName,
      description: currentMeta.description,
      aliases: currentMeta.aliases,
      status: currentMeta.status,
      updatedAt: currentMeta.updatedAt,
      ...(currentMeta.dreamUpdatedAt ? { dreamUpdatedAt: currentMeta.dreamUpdatedAt } : {}),
    };

    let projectRewriteDebug: DreamTraceStep["promptDebug"];
    const rewrite = fullRecords.length > 0
      ? await this.extractor.rewriteDreamFileProject({
          project: {
            planKey: currentMeta.projectId,
            projectId: currentMeta.projectId,
            projectName: currentMeta.projectName,
            description: currentMeta.description,
            aliases: currentMeta.aliases,
            status: currentMeta.status,
            evidenceEntryIds: fullRecords.map((record) => record.relativePath),
            retainedEntryIds: fullRecords.map((record) => record.relativePath),
          },
          currentMeta: rewriteInputMeta,
          records: fullRecords.map((record) => toDreamRecordInput(store, record)),
          debugTrace: (debug) => {
            projectRewriteDebug = debug;
          },
        })
      : {
          summary: "Dream found no project or feedback files to rewrite.",
          projectMeta: {
            projectName: currentMeta.projectName,
            description: currentMeta.description,
            aliases: currentMeta.aliases,
            status: currentMeta.status,
          },
          files: [],
          deletedEntryIds: [],
        };

    pushStep(
      trace,
      "project_rewrite_generated",
      "Project Rewrite Generated",
      "success",
      `${fullRecords.length} current project files`,
      rewrite.summary,
      {
        titleI18n: traceI18n("trace.step.project_rewrite_generated", "Project Rewrite Generated"),
        details: [
          kvDetail("project-rewrite-summary", "Rewrite Summary", [
            { label: "inputFiles", value: fullRecords.length },
            { label: "outputFiles", value: rewrite.files.length },
            { label: "deletedEntryIds", value: rewrite.deletedEntryIds.length },
          ], traceI18n("trace.detail.selection_summary", "Selection Summary")),
          jsonDetail(
            "project-rewrite-output",
            "Rewrite Output",
            {
              projectMeta: rewrite.projectMeta,
              files: rewrite.files,
              deletedEntryIds: rewrite.deletedEntryIds,
            },
            traceI18n("trace.detail.project_rewrite_output", "Project Rewrite Output"),
          ),
        ],
        ...(projectRewriteDebug ? { promptDebug: projectRewriteDebug } : {}),
      },
    );

    const deletedIds = fullRecords.map((record) => record.relativePath);
    if (deletedIds.length > 0) {
      this.repository.deleteMemoryEntries(deletedIds);
      for (const relativePath of deletedIds) {
        trace.mutations.push(mutation("delete", relativePath));
      }
    }

    const reservedAliasNames = new Set(
      rewrite.files
        .map((file) => file.name.trim().toLowerCase())
        .filter(Boolean),
    );
    const nextProjectAliases = Array.from(new Set(
      [...currentMeta.aliases, ...rewrite.projectMeta.aliases]
        .map((alias) => alias.trim())
        .filter((alias) => alias && !reservedAliasNames.has(alias.toLowerCase())),
    )).slice(0, 24);

    const refreshedMeta = store.upsertProjectMeta({
      projectName: rewrite.projectMeta.projectName,
      description: rewrite.projectMeta.description,
      aliases: nextProjectAliases,
      status: rewrite.projectMeta.status,
      dreamUpdatedAt: nowIso(),
    });
    trace.mutations.push(mutation("write", refreshedMeta.relativePath));

    const writtenRecords: MemoryFileRecord[] = [];
    for (const file of rewrite.files) {
      const record = store.upsertCandidate(toCandidate(file));
      writtenRecords.push(record);
      trace.mutations.push(mutation("write", record.relativePath));
    }

    let profileUpdated = false;
    let rewrittenProfilePath: string | undefined;
    if (userSummary.files.length > 0 || userNoteCandidates.length > 0) {
      let userRewriteDebug: DreamTraceStep["promptDebug"];
      try {
        const rewrittenUser = await this.extractor.rewriteUserProfile({
          existingProfile: userSummary,
          candidates: userNoteCandidates,
          debugTrace: (debug) => {
            userRewriteDebug = debug;
          },
        });
        if (rewrittenUser) {
          const nextSummary = {
            profile: rewrittenUser.profile ?? "",
            preferences: rewrittenUser.preferences ?? [],
            constraints: rewrittenUser.constraints ?? [],
            relationships: rewrittenUser.relationships ?? [],
          };
          const previousSummary = {
            profile: userSummary.profile,
            preferences: userSummary.preferences,
            constraints: userSummary.constraints,
            relationships: userSummary.relationships,
          };
          if (!sameUserSummary(previousSummary, nextSummary)) {
            this.repository.getGlobalUserStore().upsertUserProfile(rewrittenUser);
            this.repository.repairWorkspaceManifest();
            rewrittenProfilePath = "global/User/user-profile.md";
            profileUpdated = true;
            trace.mutations.push({
              mutationId: `mutation_${hashText(`rewrite_user_profile:global/User/user-profile.md:${Date.now()}`)}`,
              action: "rewrite_user_profile",
              relativePath: "global/User/user-profile.md",
            });
          }
        }
      } catch (error) {
        this.logger?.warn?.(`[clawxmemory] current-project dream user-profile rewrite failed: ${String(error)}`);
      }
      pushStep(
        trace,
        "user_profile_rewritten",
        "User Profile Rewritten",
        profileUpdated ? "success" : "skipped",
        `${userSummary.files.length} profile files, ${userNoteCandidates.length} user notes`,
        profileUpdated
          ? `Updated user profile at ${rewrittenProfilePath}.`
          : "Dream kept the current user profile unchanged.",
        {
          titleI18n: traceI18n("trace.step.user_profile_rewritten", "User Profile Rewritten"),
          ...(userRewriteDebug ? { promptDebug: userRewriteDebug } : {}),
        },
      );
    }

    pushStep(
      trace,
      "project_mutations_applied",
      "Project Mutations Applied",
      writtenRecords.length > 0 || deletedIds.length > 0 ? "success" : "skipped",
      `${fullRecords.length} current project files`,
      writtenRecords.length > 0 || deletedIds.length > 0
        ? `Rewrote ${writtenRecords.length} current project files and deleted ${deletedIds.length} previous files.`
        : "Dream did not need to rewrite any current project files.",
      {
        titleI18n: traceI18n("trace.step.project_mutations_applied", "Project Mutations Applied"),
        details: [
          kvDetail("dream-mutation-summary", "Mutation Summary", [
            { label: "deletedFiles", value: deletedIds.length },
            { label: "writtenFiles", value: writtenRecords.length },
            { label: "profileUpdated", value: profileUpdated ? "yes" : "no" },
          ], traceI18n("trace.detail.selection_summary", "Selection Summary")),
          ...(trace.mutations.length > 0
            ? [listDetail(
                "dream-mutations",
                "Dream Mutations",
                trace.mutations.map((item) => `${item.action} | ${item.relativePath ?? ""}`.trim()),
                traceI18n("trace.detail.loaded_files", "Loaded Files"),
              )]
            : []),
        ],
      },
    );

    const repaired = store.repairManifests();
    pushStep(
      trace,
      "manifests_repaired",
      "Manifests Repaired",
      "success",
      "workspace manifest rebuild",
      repaired.summary,
      {
        titleI18n: traceI18n("trace.step.manifests_repaired", "Manifests Repaired"),
        details: [
          kvDetail("manifest-repair", "Manifest Repair", [
            { label: "changed", value: repaired.changed },
            { label: "memoryFileCount", value: repaired.memoryFileCount },
          ], traceI18n("trace.detail.manifest_scan", "Manifest Scan")),
        ],
      },
    );

    const finishedAt = nowIso();
    const summary = rewrite.summary
      || `Dream reorganized the current project memory into ${writtenRecords.length} files.`;
    const rewrittenProjects = fullRecords.length > 0 || writtenRecords.length > 0 || deletedIds.length > 0 ? 1 : 0;
    const outcome: DreamTraceOutcome = {
      rewrittenProjects,
      deletedProjects: 0,
      deletedFiles: deletedIds.length,
      profileUpdated,
      summary,
    };

    trace.finishedAt = finishedAt;
    trace.status = "completed";
    trace.isNoOp = deletedIds.length === 0 && writtenRecords.length === 0 && !profileUpdated;
    trace.displayStatus = trace.isNoOp ? "No-op" : "Completed";
    trace.outcome = outcome;
    pushStep(
      trace,
      "dream_finished",
      "Dream Finished",
      "success",
      `${fullRecords.length} current project files`,
      summary,
      {
        titleI18n: traceI18n("trace.step.dream_finished", "Dream Finished"),
      },
    );

    this.repository.setPipelineState("lastDreamAt", finishedAt);
    this.repository.setPipelineState("lastDreamStatus", "success");
    this.repository.setPipelineState("lastDreamSummary", summary);
    this.repository.saveDreamTrace(trace);
    this.logger?.info?.(`[clawxmemory] current-project dream finished: ${summary}`);

    return {
      reviewedFiles: fullRecords.length,
      rewrittenProjects,
      deletedProjects: 0,
      deletedFiles: deletedIds.length,
      profileUpdated,
      duplicateTopicCount: 0,
      conflictTopicCount: 0,
      summary,
    };
  }
}
