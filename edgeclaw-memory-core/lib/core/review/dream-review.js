import { traceI18n } from "../trace-i18n.js";
import { hashText, nowIso } from "../utils/id.js";
function kvDetail(key, label, entries, labelI18n) {
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
function listDetail(key, label, items, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "list",
        items,
    };
}
function jsonDetail(key, label, json, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "json",
        json,
    };
}
function createDreamTrace(trigger) {
    const startedAt = nowIso();
    return {
        dreamTraceId: `dream_trace_${hashText(`${trigger}:${startedAt}:${Math.random().toString(36).slice(2, 10)}`)}`,
        trigger,
        startedAt,
        status: "running",
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
function pushStep(trace, kind, title, status, inputSummary, outputSummary, options = {}) {
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
function mutation(action, relativePath) {
    return {
        mutationId: `mutation_${hashText(`${action}:${relativePath}:${Date.now()}`)}`,
        action,
        relativePath,
    };
}
function toDreamRecordInput(store, record) {
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
function toCandidate(file) {
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
function sameUserSummary(left, right) {
    return JSON.stringify(left) === JSON.stringify(right);
}
export class DreamRewriteRunner {
    repository;
    extractor;
    logger;
    constructor(repository, extractor, options = {}) {
        this.repository = repository;
        this.extractor = extractor;
        this.logger = options.logger;
    }
    async run(trigger = "manual") {
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
        trace.snapshotSummary = {
            projectMetaPresent: Boolean(projectMeta),
            projectFileCount: workspaceEntries.filter((entry) => entry.type === "project").length,
            feedbackFileCount: workspaceEntries.filter((entry) => entry.type === "feedback").length,
            hasUserProfile: userSummary.files.length > 0,
        };
        pushStep(trace, "dream_start", "Dream Start", "info", `${trigger} dream run started.`, "Dream loaded the current project memory snapshot.", {
            titleI18n: traceI18n("trace.step.dream_start", "Dream Start"),
        });
        pushStep(trace, "snapshot_loaded", "Snapshot Loaded", workspaceEntries.length > 0 || userSummary.files.length > 0 || Boolean(projectMeta) ? "success" : "warning", `${workspaceEntries.length} current project memory files`, workspaceEntries.length > 0 || userSummary.files.length > 0 || Boolean(projectMeta)
            ? "Current project memory is ready for Dream rewrite."
            : "No file-based memory exists yet, so Dream had nothing to organize.", {
            titleI18n: traceI18n("trace.step.snapshot_loaded", "Snapshot Loaded"),
            details: [
                kvDetail("snapshot-summary", "Snapshot Summary", [
                    { label: "projectMetaPresent", value: trace.snapshotSummary.projectMetaPresent ? "yes" : "no" },
                    { label: "projectFiles", value: trace.snapshotSummary.projectFileCount },
                    { label: "feedbackFiles", value: trace.snapshotSummary.feedbackFileCount },
                    { label: "hasUserProfile", value: trace.snapshotSummary.hasUserProfile ? "yes" : "no" },
                ], traceI18n("trace.detail.snapshot_summary", "Snapshot Summary")),
                ...(projectMeta
                    ? [jsonDetail("project-meta", "Project Meta", projectMeta, traceI18n("trace.detail.project_meta", "Project Meta"))]
                    : []),
                listDetail("snapshot-files", "Current Project Files", workspaceEntries.map((entry) => `${entry.relativePath} | ${entry.updatedAt}`), traceI18n("trace.detail.loaded_files", "Loaded Files")),
            ],
        });
        if (workspaceEntries.length === 0 && userSummary.files.length === 0) {
            const finishedAt = nowIso();
            const summary = "No file-based memory exists yet, so Dream had nothing to organize.";
            trace.finishedAt = finishedAt;
            trace.status = "completed";
            trace.outcome = {
                rewrittenProjects: 0,
                deletedProjects: 0,
                deletedFiles: 0,
                profileUpdated: false,
                summary,
            };
            pushStep(trace, "dream_finished", "Dream Finished", "success", "No memory files", summary, {
                titleI18n: traceI18n("trace.step.dream_finished", "Dream Finished"),
            });
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
        const rewriteInputMeta = {
            projectId: currentMeta.projectId,
            projectName: currentMeta.projectName,
            description: currentMeta.description,
            aliases: currentMeta.aliases,
            status: currentMeta.status,
            updatedAt: currentMeta.updatedAt,
            ...(currentMeta.dreamUpdatedAt ? { dreamUpdatedAt: currentMeta.dreamUpdatedAt } : {}),
        };
        let projectRewriteDebug;
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
        pushStep(trace, "project_rewrite_generated", "Project Rewrite Generated", "success", `${fullRecords.length} current project files`, rewrite.summary, {
            titleI18n: traceI18n("trace.step.project_rewrite_generated", "Project Rewrite Generated"),
            details: [
                kvDetail("project-rewrite-summary", "Rewrite Summary", [
                    { label: "inputFiles", value: fullRecords.length },
                    { label: "outputFiles", value: rewrite.files.length },
                    { label: "deletedEntryIds", value: rewrite.deletedEntryIds.length },
                ], traceI18n("trace.detail.selection_summary", "Selection Summary")),
                jsonDetail("project-rewrite-output", "Rewrite Output", {
                    projectMeta: rewrite.projectMeta,
                    files: rewrite.files,
                    deletedEntryIds: rewrite.deletedEntryIds,
                }, traceI18n("trace.detail.project_rewrite_output", "Project Rewrite Output")),
            ],
            ...(projectRewriteDebug ? { promptDebug: projectRewriteDebug } : {}),
        });
        const deletedIds = fullRecords.map((record) => record.relativePath);
        if (deletedIds.length > 0) {
            this.repository.deleteMemoryEntries(deletedIds);
            for (const relativePath of deletedIds) {
                trace.mutations.push(mutation("delete", relativePath));
            }
        }
        const reservedAliasNames = new Set(rewrite.files
            .map((file) => file.name.trim().toLowerCase())
            .filter(Boolean));
        const nextProjectAliases = Array.from(new Set([...currentMeta.aliases, ...rewrite.projectMeta.aliases]
            .map((alias) => alias.trim())
            .filter((alias) => alias && !reservedAliasNames.has(alias.toLowerCase())))).slice(0, 24);
        const refreshedMeta = store.upsertProjectMeta({
            projectName: rewrite.projectMeta.projectName,
            description: rewrite.projectMeta.description,
            aliases: nextProjectAliases,
            status: rewrite.projectMeta.status,
            dreamUpdatedAt: nowIso(),
        });
        trace.mutations.push(mutation("write", refreshedMeta.relativePath));
        const writtenRecords = [];
        for (const file of rewrite.files) {
            const record = store.upsertCandidate(toCandidate(file));
            writtenRecords.push(record);
            trace.mutations.push(mutation("write", record.relativePath));
        }
        let profileUpdated = false;
        let rewrittenProfilePath;
        if (userSummary.files.length > 0) {
            let userRewriteDebug;
            try {
                const rewrittenUser = await this.extractor.rewriteUserProfile({
                    existingProfile: userSummary,
                    candidates: [{
                            type: "user",
                            scope: "global",
                            name: "user-profile",
                            description: userSummary.profile || userSummary.preferences[0] || "User profile",
                            profile: userSummary.profile,
                            preferences: userSummary.preferences,
                            constraints: userSummary.constraints,
                            relationships: userSummary.relationships,
                        }],
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
                        this.repository.getGlobalUserStore().upsertCandidate(rewrittenUser);
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
            }
            catch (error) {
                this.logger?.warn?.(`[clawxmemory] current-project dream user-profile rewrite failed: ${String(error)}`);
            }
            pushStep(trace, "user_profile_rewritten", "User Profile Rewritten", profileUpdated ? "success" : "skipped", `${userSummary.files.length} existing user profile file`, profileUpdated
                ? `Updated user profile at ${rewrittenProfilePath}.`
                : "Dream kept the current user profile unchanged.", {
                titleI18n: traceI18n("trace.step.user_profile_rewritten", "User Profile Rewritten"),
                ...(userRewriteDebug ? { promptDebug: userRewriteDebug } : {}),
            });
        }
        pushStep(trace, "project_mutations_applied", "Project Mutations Applied", writtenRecords.length > 0 || deletedIds.length > 0 ? "success" : "skipped", `${fullRecords.length} current project files`, writtenRecords.length > 0 || deletedIds.length > 0
            ? `Rewrote ${writtenRecords.length} current project files and deleted ${deletedIds.length} previous files.`
            : "Dream did not need to rewrite any current project files.", {
            titleI18n: traceI18n("trace.step.project_mutations_applied", "Project Mutations Applied"),
            details: [
                kvDetail("dream-mutation-summary", "Mutation Summary", [
                    { label: "deletedFiles", value: deletedIds.length },
                    { label: "writtenFiles", value: writtenRecords.length },
                    { label: "profileUpdated", value: profileUpdated ? "yes" : "no" },
                ], traceI18n("trace.detail.selection_summary", "Selection Summary")),
                ...(trace.mutations.length > 0
                    ? [listDetail("dream-mutations", "Dream Mutations", trace.mutations.map((item) => `${item.action} | ${item.relativePath ?? ""}`.trim()), traceI18n("trace.detail.loaded_files", "Loaded Files"))]
                    : []),
            ],
        });
        const repaired = store.repairManifests();
        pushStep(trace, "manifests_repaired", "Manifests Repaired", "success", "workspace manifest rebuild", repaired.summary, {
            titleI18n: traceI18n("trace.step.manifests_repaired", "Manifests Repaired"),
            details: [
                kvDetail("manifest-repair", "Manifest Repair", [
                    { label: "changed", value: repaired.changed },
                    { label: "memoryFileCount", value: repaired.memoryFileCount },
                ], traceI18n("trace.detail.manifest_scan", "Manifest Scan")),
            ],
        });
        const finishedAt = nowIso();
        const summary = rewrite.summary
            || `Dream reorganized the current project memory into ${writtenRecords.length} files.`;
        const outcome = {
            rewrittenProjects: 1,
            deletedProjects: 0,
            deletedFiles: deletedIds.length,
            profileUpdated,
            summary,
        };
        trace.finishedAt = finishedAt;
        trace.status = "completed";
        trace.outcome = outcome;
        pushStep(trace, "dream_finished", "Dream Finished", "success", `${fullRecords.length} current project files`, summary, {
            titleI18n: traceI18n("trace.step.dream_finished", "Dream Finished"),
        });
        this.repository.setPipelineState("lastDreamAt", finishedAt);
        this.repository.setPipelineState("lastDreamStatus", "success");
        this.repository.setPipelineState("lastDreamSummary", summary);
        this.repository.saveDreamTrace(trace);
        this.logger?.info?.(`[clawxmemory] current-project dream finished: ${summary}`);
        return {
            reviewedFiles: fullRecords.length,
            rewrittenProjects: 1,
            deletedProjects: 0,
            deletedFiles: deletedIds.length,
            profileUpdated,
            duplicateTopicCount: 0,
            conflictTopicCount: 0,
            summary,
        };
    }
}
