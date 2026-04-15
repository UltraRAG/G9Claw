import { traceI18n } from "../trace-i18n.js";
import { hashText, nowIso } from "../utils/id.js";
import { decodeEscapedUnicodeText, decodeEscapedUnicodeValue, truncate } from "../utils/text.js";
const RECALL_CACHE_TTL_MS = 30_000;
const DEFAULT_RECALL_TOP_K = 5;
const MANIFEST_LIMIT = 200;
const RECALL_FILE_MAX_CHARS = 12_000;
const RECALL_TOTAL_MAX_CHARS = 30_000;
function normalizeQueryKey(query) {
    return query.toLowerCase().replace(/\s+/g, " ").trim();
}
function buildTraceId(prefix, seed) {
    return `${prefix}_${hashText(`${seed}:${Date.now()}:${Math.random().toString(36).slice(2, 10)}`)}`;
}
function previewText(value, max = 220) {
    return truncate(decodeEscapedUnicodeText(value).trim(), max);
}
function listDetail(key, label, items, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "list",
        items: items.map((item) => decodeEscapedUnicodeText(item, true)),
    };
}
function kvDetail(key, label, entries, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "kv",
        entries: entries.map((entry) => ({
            label: entry.label,
            value: decodeEscapedUnicodeText(String(entry.value ?? ""), true),
        })),
    };
}
function jsonDetail(key, label, json, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "json",
        json: decodeEscapedUnicodeValue(json, true),
    };
}
function hasUserSummary(userSummary) {
    return Boolean(userSummary.profile
        || userSummary.preferences.length
        || userSummary.constraints.length
        || userSummary.relationships.length);
}
function renderUserSummaryBlock(userSummary) {
    if (!hasUserSummary(userSummary))
        return [];
    const updatedAt = userSummary.files[0]?.updatedAt ?? "";
    const lines = [
        `### [user] global/User/user-profile.md${updatedAt ? ` (${updatedAt})` : ""}`,
        "## Profile",
        userSummary.profile || "No stable user profile yet.",
        "",
    ];
    if (userSummary.preferences.length > 0) {
        lines.push("## Preferences", ...userSummary.preferences.map((item) => `- ${item}`), "");
    }
    if (userSummary.constraints.length > 0) {
        lines.push("## Constraints", ...userSummary.constraints.map((item) => `- ${item}`), "");
    }
    if (userSummary.relationships.length > 0) {
        lines.push("## Relationships", ...userSummary.relationships.map((item) => `- ${item}`), "");
    }
    return lines;
}
function renderProjectMetaBlock(projectMeta) {
    if (!projectMeta)
        return [];
    const lines = [
        `### [project_meta] ${projectMeta.relativePath} (${projectMeta.updatedAt})`,
        `- project_id: ${projectMeta.projectId}`,
        `- project_name: ${projectMeta.projectName}`,
        `- description: ${projectMeta.description}`,
        `- status: ${projectMeta.status}`,
        `- aliases: ${projectMeta.aliases.join(", ") || "none"}`,
    ];
    if (projectMeta.dreamUpdatedAt) {
        lines.push(`- dream_updated_at: ${projectMeta.dreamUpdatedAt}`);
    }
    lines.push("");
    return lines;
}
function renderContext(route, userSummary, projectMeta, records, disambiguationRequired = false) {
    if (!hasUserSummary(userSummary) && !projectMeta && records.length === 0 && !disambiguationRequired)
        return "";
    const lines = [
        "## ClawXMemory Recall",
        `route=${route}`,
        "",
        ...renderUserSummaryBlock(userSummary),
        ...renderProjectMetaBlock(projectMeta),
    ];
    if (disambiguationRequired) {
        lines.push("## Project Clarification Required", "- No formal project was selected from long-term memory for this query.", "- Do not invent or list project names that are not in memory.", "- Ask the user to clarify which project they mean before answering project-specific details.", "");
    }
    for (const record of records) {
        lines.push(`### [${record.type}] ${record.relativePath} (${record.updatedAt})`);
        lines.push(record.content.trim());
        lines.push("");
    }
    lines.push("Treat these file memories as the authoritative long-term memory for this turn when relevant.");
    return lines.join("\n").trim();
}
function buildEmptyResult(query, trace, elapsedMs, cacheHit = false) {
    return {
        query,
        intent: "none",
        context: "",
        trace,
        debug: {
            mode: "none",
            elapsedMs,
            cacheHit,
            path: "explicit",
            route: "none",
            manifestCount: 0,
            selectedFileIds: [],
        },
    };
}
function routeNeedsProjectMemory(route) {
    return route === "project_memory";
}
function kindsForRoute(route) {
    if (route === "project_memory")
        return ["feedback", "project"];
    return [];
}
function resolveWorkspaceToken(workspaceHint) {
    const normalized = workspaceHint?.replace(/\\/g, "/").trim() ?? "";
    if (!normalized)
        return "";
    const parts = normalized.split("/").filter(Boolean);
    return parts[parts.length - 1]?.toLowerCase() ?? "";
}
function isProjectAliasCandidate(value) {
    const normalized = value.toLowerCase().trim();
    if (!normalized)
        return false;
    if (normalized.length > 80)
        return false;
    if (/[。！？!?]/.test(normalized))
        return false;
    return true;
}
function projectIdentityTerms(project) {
    return Array.from(new Set([project.projectName, ...project.aliases]
        .map((item) => item.toLowerCase().trim())
        .filter(isProjectAliasCandidate)));
}
function rankProjects(projects, text, workspaceToken) {
    const normalized = text.toLowerCase().trim();
    if (!normalized)
        return [];
    return projects
        .map((project) => ({
        projectId: project.projectId,
        projectName: project.projectName,
        description: project.description,
        aliases: project.aliases,
        status: project.status,
        score: scoreProjectMeta(project, normalized, workspaceToken),
        exact: hasExactProjectMention(project, normalized) ? 1 : 0,
        updatedAt: project.updatedAt,
        source: "query",
        matchedText: normalized,
    }))
        .sort((left, right) => right.exact - left.exact
        || right.score - left.score
        || right.updatedAt.localeCompare(left.updatedAt));
}
function scoreProjectMeta(project, text, workspaceToken) {
    const identities = projectIdentityTerms(project);
    const description = project.description.toLowerCase().trim();
    let score = 0;
    for (const candidate of identities) {
        if (text.includes(candidate))
            score += 10;
        if (candidate.includes(text) && text.length >= 4)
            score += 3;
        const candidateTokens = candidate.split(/[\s/_-]+/).filter((token) => token.length >= 3);
        for (const token of candidateTokens) {
            if (text.includes(token))
                score += 2;
        }
    }
    if (description) {
        const descriptionTokens = description.split(/[\s/_-]+/).filter((token) => token.length >= 4);
        for (const token of descriptionTokens) {
            if (text.includes(token))
                score += 1;
        }
    }
    if (workspaceToken) {
        const workspaceHit = identities.some((candidate) => candidate.includes(workspaceToken) || workspaceToken.includes(candidate));
        if (workspaceHit)
            score += 2;
    }
    return score;
}
function hasExactProjectMention(project, text) {
    const candidates = projectIdentityTerms(project);
    return candidates.some((candidate) => text.includes(candidate));
}
function buildProjectShortlist(projects, query, recentMessages, workspaceHint) {
    const queryText = query.toLowerCase().trim();
    const workspaceToken = resolveWorkspaceToken(workspaceHint);
    const recentUserTexts = [...(recentMessages ?? [])]
        .filter((message) => message.role === "user")
        .map((message) => message.content.toLowerCase().trim())
        .filter(Boolean)
        .reverse();
    if (!queryText || projects.length === 0) {
        return { workspaceToken, recentUserTexts, candidates: [] };
    }
    const shortlistById = new Map();
    const mergeCandidate = (candidate) => {
        if (candidate.score <= 0)
            return;
        const existing = shortlistById.get(candidate.projectId);
        if (!existing) {
            shortlistById.set(candidate.projectId, candidate);
            return;
        }
        if (candidate.exact > existing.exact
            || candidate.score > existing.score
            || (candidate.score === existing.score && candidate.updatedAt > existing.updatedAt)) {
            shortlistById.set(candidate.projectId, candidate);
        }
    };
    for (const candidate of rankProjects(projects, queryText, workspaceToken)) {
        mergeCandidate(candidate);
    }
    for (const text of recentUserTexts) {
        for (const candidate of rankProjects(projects, text, workspaceToken).map((item) => ({
            ...item,
            source: "recent",
            matchedText: text,
        }))) {
            mergeCandidate(candidate);
        }
    }
    return {
        workspaceToken,
        recentUserTexts,
        candidates: [...shortlistById.values()]
            .sort((left, right) => right.exact - left.exact
            || right.score - left.score
            || right.updatedAt.localeCompare(left.updatedAt)
            || left.projectName.localeCompare(right.projectName))
            .slice(0, 5),
    };
}
function buildProjectManifestSelection(store, route, projectId, limit = MANIFEST_LIMIT) {
    const kinds = kindsForRoute(route);
    const boundedLimit = Math.max(1, Math.min(MANIFEST_LIMIT, limit));
    if (!routeNeedsProjectMemory(route)) {
        return { allCount: 0, entries: [], kinds, limit: boundedLimit };
    }
    const allEntries = store.scanRecallHeaderEntries({
        projectId,
        kinds,
        limit: boundedLimit,
    });
    const sorted = [...allEntries].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)
        || left.relativePath.localeCompare(right.relativePath));
    return {
        allCount: allEntries.length,
        entries: sorted.slice(0, boundedLimit),
        kinds,
        limit: boundedLimit,
    };
}
function toShortlistProjectMeta(project) {
    return {
        projectId: project.identityKey,
        projectName: project.projectName,
        description: project.description,
        aliases: [...project.aliases],
        status: project.scope,
        createdAt: project.updatedAt,
        updatedAt: project.updatedAt,
        relativePath: "",
        absolutePath: "",
    };
}
function buildTmpProjectManifestSelection(store, route, project, limit = MANIFEST_LIMIT) {
    const kinds = kindsForRoute(route);
    const boundedLimit = Math.max(1, Math.min(MANIFEST_LIMIT, limit));
    if (!routeNeedsProjectMemory(route)) {
        return { allCount: 0, entries: [], kinds, limit: boundedLimit };
    }
    const identityTerms = new Set([project.projectName, ...project.aliases]
        .map((value) => value.toLowerCase().trim())
        .filter(Boolean));
    const allEntries = store.listTmpEntries(500)
        .filter((entry) => kinds.includes(entry.type))
        .filter((entry) => identityTerms.has(entry.name.toLowerCase().trim()))
        .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)
        || left.relativePath.localeCompare(right.relativePath));
    return {
        allCount: allEntries.length,
        entries: allEntries.slice(0, boundedLimit),
        kinds,
        limit: boundedLimit,
    };
}
function applyRecallContentBudgets(records) {
    let remainingTotal = RECALL_TOTAL_MAX_CHARS;
    const loaded = [];
    for (const record of records) {
        if (remainingTotal <= 0)
            break;
        const originalChars = record.content.length;
        const allowedChars = Math.max(0, Math.min(RECALL_FILE_MAX_CHARS, remainingTotal));
        if (allowedChars <= 0)
            break;
        const truncated = originalChars > allowedChars;
        const content = truncated
            ? `${record.content.slice(0, allowedChars).trimEnd()}\n\n...[truncated for recall budget]`
            : record.content;
        loaded.push({
            ...record,
            content,
            truncated,
            originalChars,
            loadedChars: content.length,
        });
        remainingTotal -= content.length;
    }
    return loaded;
}
export class ReasoningRetriever {
    repository;
    extractor;
    runtime;
    cache = new Map();
    runtimeStats = {
        lastRecallMs: 0,
        recallTimeouts: 0,
        lastRecallMode: "none",
        lastRecallPath: "explicit",
        lastRecallInjected: false,
        lastRecallCacheHit: false,
    };
    constructor(repository, extractor, runtime = {}) {
        this.repository = repository;
        this.extractor = extractor;
        this.runtime = runtime;
    }
    getRuntimeStats() {
        return { ...this.runtimeStats };
    }
    resetTransientState() {
        this.cache.clear();
        this.runtimeStats = {
            lastRecallMs: 0,
            recallTimeouts: 0,
            lastRecallMode: "none",
            lastRecallPath: "explicit",
            lastRecallInjected: false,
            lastRecallCacheHit: false,
        };
    }
    currentSettings() {
        return this.runtime.getSettings?.() ?? {
            reasoningMode: "answer_first",
            autoIndexIntervalMinutes: 60,
            autoDreamIntervalMinutes: 360,
        };
    }
    buildCacheKey(query, settings, retrievalMode, workspaceHint) {
        return JSON.stringify({
            query: normalizeQueryKey(query),
            snapshot: this.repository.getSnapshotVersion(),
            retrievalMode,
            workspaceHint: normalizeQueryKey(workspaceHint),
        });
    }
    getCachedResult(cacheKey) {
        const cached = this.cache.get(cacheKey);
        if (!cached)
            return null;
        if (cached.expiresAt <= Date.now()) {
            this.cache.delete(cacheKey);
            return null;
        }
        return cached.result;
    }
    saveCache(cacheKey, result) {
        this.cache.set(cacheKey, {
            expiresAt: Date.now() + RECALL_CACHE_TTL_MS,
            result,
        });
    }
    updateRuntimeStats(result, startedAt, cacheHit, mode, retrievalMode) {
        const elapsedMs = Date.now() - startedAt;
        this.runtimeStats = {
            lastRecallMs: elapsedMs,
            recallTimeouts: this.runtimeStats.recallTimeouts,
            lastRecallMode: mode,
            lastRecallPath: retrievalMode,
            lastRecallInjected: Boolean(result.context.trim()),
            lastRecallCacheHit: cacheHit,
        };
    }
    async retrieve(query, options = {}) {
        const startedAt = Date.now();
        const normalizedQuery = decodeEscapedUnicodeText(query.trim(), true);
        const recentUserMessages = [...(options.recentMessages ?? [])]
            .filter((message) => message.role === "user")
            .slice(-4);
        const settings = this.currentSettings();
        const retrievalMode = options.retrievalMode ?? "explicit";
        const traceId = buildTraceId("trace", normalizedQuery);
        const trace = {
            traceId,
            query: normalizedQuery,
            mode: retrievalMode,
            startedAt: nowIso(),
            finishedAt: nowIso(),
            steps: [{
                    stepId: `${traceId}:step:1`,
                    kind: "recall_start",
                    title: "Recall Started",
                    titleI18n: traceI18n("trace.step.recall_start", "Recall Started"),
                    status: "info",
                    inputSummary: normalizedQuery,
                    outputSummary: `mode=${retrievalMode}`,
                    details: [
                        kvDetail("recall-start-inputs", "Recall Inputs", [
                            { label: "query", value: normalizedQuery },
                            { label: "mode", value: retrievalMode },
                            { label: "recentUserMessages", value: recentUserMessages.length },
                            { label: "workspaceHint", value: options.workspaceHint ?? "none" },
                        ], traceI18n("trace.detail.recall_inputs", "Recall Inputs")),
                        ...(recentUserMessages.length
                            ? [listDetail("recent-user-messages", "Recent User Messages", recentUserMessages.map((message) => previewText(message.content, 180)), traceI18n("trace.detail.recent_user_messages", "Recent User Messages"))]
                            : []),
                    ],
                }],
        };
        if (!normalizedQuery) {
            const empty = buildEmptyResult(normalizedQuery, trace, 0);
            this.updateRuntimeStats(empty, startedAt, false, "none", retrievalMode);
            return empty;
        }
        const cacheKey = this.buildCacheKey(normalizedQuery, settings, retrievalMode, options.workspaceHint ?? "");
        const cached = this.getCachedResult(cacheKey);
        if (cached) {
            const result = {
                ...cached,
                debug: {
                    mode: cached.debug?.mode ?? (cached.context.trim() ? "llm" : "none"),
                    cacheHit: true,
                    elapsedMs: Date.now() - startedAt,
                    ...(cached.debug?.path ? { path: cached.debug.path } : {}),
                    ...(cached.debug?.route ? { route: cached.debug.route } : {}),
                    ...(typeof cached.debug?.manifestCount === "number" ? { manifestCount: cached.debug.manifestCount } : {}),
                    ...(cached.debug?.selectedFileIds ? { selectedFileIds: cached.debug.selectedFileIds } : {}),
                    ...(cached.debug?.resolvedProjectId ? { resolvedProjectId: cached.debug.resolvedProjectId } : {}),
                },
            };
            this.updateRuntimeStats(result, startedAt, true, cached.context.trim() ? "llm" : "none", retrievalMode);
            return result;
        }
        let routePromptDebug;
        let route = await this.extractor.decideFileMemoryRoute({
            query: normalizedQuery,
            ...(recentUserMessages.length ? { recentMessages: recentUserMessages } : {}),
            debugTrace: (debug) => {
                routePromptDebug = debug;
            },
        });
        const store = this.repository.getFileMemoryStore();
        const projectMetas = store.listProjectMetas().filter((meta) => store.hasVisibleProjectMemory(meta.projectId));
        const tmpProjectHints = store.listProjectIdentityHints({ includeTmp: true, limit: 30 })
            .filter((project) => project.scope === "tmp");
        const exactProjectMentions = projectMetas.filter((project) => hasExactProjectMention(project, normalizedQuery.toLowerCase().trim()));
        const gateOverrideReason = route === "none" && exactProjectMentions.length === 1
            ? "exact_formal_project_mention"
            : "";
        if (gateOverrideReason) {
            route = "project_memory";
        }
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "memory_gate",
            title: "Memory Gate",
            titleI18n: traceI18n("trace.step.memory_gate", "Memory Gate"),
            status: route === "none" ? "skipped" : "success",
            inputSummary: normalizedQuery,
            outputSummary: `route=${route}`,
            details: [
                kvDetail("gate-route", "Route", [
                    { label: "route", value: route },
                    { label: "override", value: gateOverrideReason || "none" },
                    { label: "recentUserMessages", value: recentUserMessages.length },
                    { label: "workspaceHint", value: options.workspaceHint ?? "none" },
                ], traceI18n("trace.detail.route", "Route")),
            ],
            ...(routePromptDebug ? { promptDebug: routePromptDebug } : {}),
        });
        if (route === "none") {
            trace.steps.push({
                stepId: `${traceId}:step:${trace.steps.length + 1}`,
                kind: "recall_skipped",
                title: "Recall Skipped",
                titleI18n: traceI18n("trace.step.recall_skipped", "Recall Skipped"),
                status: "skipped",
                inputSummary: "route=none",
                outputSummary: "This query does not need long-term memory.",
                outputSummaryI18n: traceI18n("trace.text.recall_skipped.query_does_not_need_memory", "This query does not need long-term memory."),
            });
            trace.steps.push({
                stepId: `${traceId}:step:${trace.steps.length + 1}`,
                kind: "context_rendered",
                title: "Context Rendered",
                titleI18n: traceI18n("trace.step.context_rendered", "Context Rendered"),
                status: "skipped",
                inputSummary: "0 records",
                outputSummary: "No memory context injected.",
                outputSummaryI18n: traceI18n("trace.text.context_rendered.no_memory_context", "No memory context injected."),
            });
            trace.finishedAt = nowIso();
            const result = buildEmptyResult(normalizedQuery, trace, Date.now() - startedAt);
            this.updateRuntimeStats(result, startedAt, false, "none", retrievalMode);
            this.saveCache(cacheKey, result);
            return result;
        }
        const userSummary = store.getUserSummary();
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "user_base_loaded",
            title: "User Base Loaded",
            titleI18n: traceI18n("trace.step.user_base_loaded", "User Base Loaded"),
            status: hasUserSummary(userSummary) ? "success" : "warning",
            inputSummary: "global user profile",
            inputSummaryI18n: traceI18n("trace.text.user_base_loaded.input.global_user_profile", "global user profile"),
            outputSummary: hasUserSummary(userSummary) ? "Attached compact global user profile." : "No compact global user profile is available yet.",
            outputSummaryI18n: hasUserSummary(userSummary)
                ? traceI18n("trace.text.user_base_loaded.output.attached", "Attached compact global user profile.")
                : traceI18n("trace.text.user_base_loaded.output.missing", "No compact global user profile is available yet."),
            details: [
                kvDetail("user-summary", "User Profile", [
                    { label: "profile", value: userSummary.profile ? "present" : "missing" },
                    { label: "preferences", value: userSummary.preferences.length },
                    { label: "constraints", value: userSummary.constraints.length },
                    { label: "relationships", value: userSummary.relationships.length },
                ], traceI18n("trace.detail.user_profile", "User Profile")),
                ...(userSummary.files.length > 0
                    ? [listDetail("user-summary-files", "Source Files", userSummary.files.map((file) => `${file.relativePath} | ${file.updatedAt}`), traceI18n("trace.detail.source_files", "Source Files"))]
                    : []),
            ],
        });
        let resolvedProjectId = "";
        let resolvedProjectMeta;
        let resolvedTmpProject;
        let projectSelectionPromptDebug;
        let projectSelectionReason = "";
        let shortlistResult = {
            workspaceToken: resolveWorkspaceToken(options.workspaceHint),
            recentUserTexts: recentUserMessages.map((message) => message.content.toLowerCase().trim()).filter(Boolean),
            candidates: [],
        };
        let tmpShortlistResult = {
            workspaceToken: resolveWorkspaceToken(options.workspaceHint),
            recentUserTexts: recentUserMessages.map((message) => message.content.toLowerCase().trim()).filter(Boolean),
            candidates: [],
        };
        if (routeNeedsProjectMemory(route)) {
            shortlistResult = buildProjectShortlist(projectMetas, normalizedQuery, recentUserMessages, options.workspaceHint);
            trace.steps.push({
                stepId: `${traceId}:step:${trace.steps.length + 1}`,
                kind: "project_shortlist_built",
                title: "Project Shortlist Built",
                titleI18n: traceI18n("trace.step.project_shortlist_built", "Project Shortlist Built"),
                status: shortlistResult.candidates.length > 0 ? "success" : "warning",
                inputSummary: `${projectMetas.length} formal projects`,
                inputSummaryI18n: traceI18n("trace.text.project_shortlist_built.input", "{0} formal projects", projectMetas.length),
                outputSummary: `${shortlistResult.candidates.length} shortlist candidates ready.`,
                outputSummaryI18n: traceI18n("trace.text.project_shortlist_built.output", "{0} shortlist candidates ready.", shortlistResult.candidates.length),
                details: [
                    kvDetail("project-shortlist-summary", "Project Shortlist", [
                        { label: "formalProjects", value: projectMetas.length },
                        { label: "shortlistCount", value: shortlistResult.candidates.length },
                        { label: "workspaceToken", value: shortlistResult.workspaceToken || "none" },
                        { label: "recentUserTexts", value: shortlistResult.recentUserTexts.length },
                    ], traceI18n("trace.detail.project_shortlist", "Project Shortlist")),
                    ...(shortlistResult.recentUserTexts.length > 0
                        ? [listDetail("project-shortlist-recent", "Recent User Texts", shortlistResult.recentUserTexts, traceI18n("trace.detail.recent_user_texts", "Recent User Texts"))]
                        : []),
                    jsonDetail("project-shortlist-candidates", "Shortlist Candidates", shortlistResult.candidates, traceI18n("trace.detail.shortlist_candidates", "Shortlist Candidates")),
                ],
            });
            if (shortlistResult.candidates.length > 0) {
                const exactShortlistMatches = shortlistResult.candidates.filter((candidate) => candidate.exact > 0);
                if (exactShortlistMatches.length === 1) {
                    resolvedProjectId = exactShortlistMatches[0].projectId;
                    projectSelectionReason = "exact_project_mention";
                }
                else {
                    const selection = await this.extractor.selectRecallProject({
                        query: normalizedQuery,
                        recentUserMessages,
                        shortlist: shortlistResult.candidates,
                        debugTrace: (debug) => {
                            projectSelectionPromptDebug = debug;
                        },
                    });
                    resolvedProjectId = selection.projectId ?? "";
                    projectSelectionReason = selection.reason ?? "";
                }
                resolvedProjectMeta = resolvedProjectId
                    ? projectMetas.find((project) => project.projectId === resolvedProjectId)
                    : undefined;
            }
            if (!resolvedProjectMeta && tmpProjectHints.length > 0) {
                tmpShortlistResult = buildProjectShortlist(tmpProjectHints.map((project) => toShortlistProjectMeta(project)), normalizedQuery, recentUserMessages, options.workspaceHint);
                if (tmpShortlistResult.candidates.length > 0) {
                    const exactTmpMatches = tmpShortlistResult.candidates.filter((candidate) => candidate.exact > 0);
                    if (exactTmpMatches.length === 1) {
                        resolvedProjectId = exactTmpMatches[0].projectId;
                        projectSelectionReason = projectSelectionReason || "exact_tmp_project_mention";
                    }
                    else if (tmpShortlistResult.candidates.length === 1) {
                        resolvedProjectId = tmpShortlistResult.candidates[0].projectId;
                        projectSelectionReason = projectSelectionReason || "unique_tmp_project_identity";
                    }
                    else {
                        const selection = await this.extractor.selectRecallProject({
                            query: normalizedQuery,
                            recentUserMessages,
                            shortlist: tmpShortlistResult.candidates,
                        });
                        resolvedProjectId = selection.projectId ?? resolvedProjectId;
                        projectSelectionReason = selection.reason ?? projectSelectionReason;
                    }
                }
                resolvedTmpProject = resolvedProjectId
                    ? tmpProjectHints.find((project) => project.identityKey === resolvedProjectId)
                    : undefined;
            }
        }
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "project_selected",
            title: "Project Selected",
            titleI18n: traceI18n("trace.step.project_selected", "Project Selected"),
            status: !routeNeedsProjectMemory(route)
                ? "skipped"
                : resolvedProjectId
                    ? "success"
                    : shortlistResult.candidates.length > 0 || tmpShortlistResult.candidates.length > 0
                        ? "warning"
                        : "skipped",
            inputSummary: routeNeedsProjectMemory(route)
                ? `${shortlistResult.candidates.length + tmpShortlistResult.candidates.length} shortlist candidates`
                : `route=${route}`,
            ...(routeNeedsProjectMemory(route)
                ? { inputSummaryI18n: traceI18n("trace.text.project_selected.input", "{0} shortlist candidates", shortlistResult.candidates.length + tmpShortlistResult.candidates.length) }
                : {}),
            outputSummary: resolvedProjectId
                ? `project_id=${resolvedProjectId}`
                : routeNeedsProjectMemory(route)
                    ? "No project identity was selected for this query."
                    : "This recall route does not require project selection.",
            ...(!resolvedProjectId && routeNeedsProjectMemory(route)
                ? { outputSummaryI18n: traceI18n("trace.text.project_selected.output.none_selected", "No formal project was selected for this query.") }
                : {}),
            ...(!resolvedProjectId && !routeNeedsProjectMemory(route)
                ? { outputSummaryI18n: traceI18n("trace.text.project_selected.output.not_required", "This recall route does not require project selection.") }
                : {}),
            details: [
                kvDetail("project-selection-summary", "Project Selection", [
                    { label: "project_id", value: resolvedProjectId || "none" },
                    { label: "selectionReason", value: projectSelectionReason || "none" },
                    { label: "shortlistCount", value: shortlistResult.candidates.length + tmpShortlistResult.candidates.length },
                ], traceI18n("trace.detail.project_selection", "Project Selection")),
                ...(shortlistResult.candidates.length > 0
                    ? [jsonDetail("project-selection-shortlist", "Shortlist Candidates", shortlistResult.candidates, traceI18n("trace.detail.shortlist_candidates", "Shortlist Candidates"))]
                    : []),
                ...(tmpShortlistResult.candidates.length > 0
                    ? [jsonDetail("project-selection-tmp-shortlist", "Tmp Shortlist Candidates", tmpShortlistResult.candidates, traceI18n("trace.detail.shortlist_candidates", "Shortlist Candidates"))]
                    : []),
            ],
            ...(projectSelectionPromptDebug ? { promptDebug: projectSelectionPromptDebug } : {}),
        });
        if (resolvedTmpProject) {
            trace.steps.push({
                stepId: `${traceId}:step:${trace.steps.length + 1}`,
                kind: "fallback_applied",
                title: "Fallback Applied",
                titleI18n: traceI18n("trace.step.fallback_applied", "Fallback Applied"),
                status: "success",
                inputSummary: "formal project recall unresolved",
                outputSummary: `Using tmp project identity ${resolvedTmpProject.projectName} for recall.`,
                details: [
                    kvDetail("tmp-project-fallback", "Tmp Project Fallback", [
                        { label: "identityKey", value: resolvedTmpProject.identityKey },
                        { label: "projectName", value: resolvedTmpProject.projectName },
                        { label: "aliases", value: resolvedTmpProject.aliases.join(", ") || "none" },
                    ], traceI18n("trace.detail.project_selection", "Project Selection")),
                ],
            });
        }
        const manifestSelection = resolvedProjectMeta
            ? buildProjectManifestSelection(store, route, resolvedProjectMeta.projectId, MANIFEST_LIMIT)
            : resolvedTmpProject
                ? buildTmpProjectManifestSelection(store, route, resolvedTmpProject, MANIFEST_LIMIT)
                : {
                    allCount: 0,
                    entries: [],
                    kinds: kindsForRoute(route),
                    limit: MANIFEST_LIMIT,
                };
        const manifest = manifestSelection.entries;
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "manifest_scanned",
            title: "Manifest Scanned",
            titleI18n: traceI18n("trace.step.manifest_scanned", "Manifest Scanned"),
            status: manifest.length > 0 ? "success" : routeNeedsProjectMemory(route) ? "warning" : "skipped",
            inputSummary: resolvedProjectId ? `project_id=${resolvedProjectId}` : `route=${route}`,
            outputSummary: resolvedProjectId
                ? `${manifest.length} recall header entries ready${manifestSelection.allCount > manifest.length ? ` (top ${manifest.length} of ${manifestSelection.allCount})` : ""}.`
                : routeNeedsProjectMemory(route)
                    ? "Project recall skipped because no project identity was selected."
                    : "This recall route does not require a project manifest.",
            ...(resolvedProjectId
                ? {
                    outputSummaryI18n: manifestSelection.allCount > manifest.length
                        ? traceI18n("trace.text.manifest_scanned.output.with_limit", "{0} recall header entries ready (top {1} of {2}).", manifest.length, manifest.length, manifestSelection.allCount)
                        : traceI18n("trace.text.manifest_scanned.output.ready", "{0} recall header entries ready.", manifest.length),
                }
                : {}),
            ...(!resolvedProjectId && routeNeedsProjectMemory(route)
                ? { outputSummaryI18n: traceI18n("trace.text.manifest_scanned.output.no_project_selected", "Project recall skipped because no formal project was selected.") }
                : {}),
            ...(!resolvedProjectId && !routeNeedsProjectMemory(route)
                ? { outputSummaryI18n: traceI18n("trace.text.manifest_scanned.output.not_required", "This recall route does not require a project manifest.") }
                : {}),
            details: [
                kvDetail("manifest-scan-summary", "Manifest Scan", [
                    { label: "count", value: manifest.length },
                    { label: "availableBeforeLimit", value: manifestSelection.allCount },
                    { label: "route", value: route },
                    { label: "project_id", value: resolvedProjectId || "none" },
                    { label: "kinds", value: manifestSelection.kinds.join(", ") || "none" },
                    { label: "limit", value: manifestSelection.limit },
                    { label: "sort", value: "updatedAt desc" },
                ], traceI18n("trace.detail.manifest_scan", "Manifest Scan")),
                listDetail("manifest-scan-preview", "Sorted Candidates", manifest.map((entry) => `${entry.updatedAt} | ${entry.type} | ${entry.relativePath} | ${entry.description}`), traceI18n("trace.detail.sorted_candidates", "Sorted Candidates")),
            ],
        });
        let manifestSelectionPromptDebug;
        const rawSelectedIds = manifest.length > 0
            ? await this.extractor.selectFileManifestEntries({
                query: normalizedQuery,
                route,
                recentUserMessages,
                ...((resolvedProjectMeta || resolvedTmpProject)
                    ? { projectMeta: resolvedProjectMeta ?? toShortlistProjectMeta(resolvedTmpProject) }
                    : {}),
                manifest,
                limit: DEFAULT_RECALL_TOP_K,
                debugTrace: (debug) => {
                    manifestSelectionPromptDebug = debug;
                },
            })
            : [];
        const selectedIds = Array.from(new Set(rawSelectedIds))
            .slice(0, DEFAULT_RECALL_TOP_K);
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "manifest_selected",
            title: "Manifest Selected",
            titleI18n: traceI18n("trace.step.manifest_selected", "Manifest Selected"),
            status: selectedIds.length > 0 ? "success" : manifest.length > 0 ? "warning" : "skipped",
            inputSummary: `${manifest.length} entries`,
            inputSummaryI18n: traceI18n("trace.text.manifest_selected.input", "{0} entries", manifest.length),
            outputSummary: `${selectedIds.length} file ids selected.`,
            outputSummaryI18n: traceI18n("trace.text.manifest_selected.output", "{0} file ids selected.", selectedIds.length),
            details: [
                listDetail("manifest-selection-input", "Manifest Candidate IDs", manifest.map((entry) => entry.relativePath), traceI18n("trace.detail.manifest_candidate_ids", "Manifest Candidate IDs")),
                listDetail("selected-files", "Selected File IDs", selectedIds, traceI18n("trace.detail.selected_file_ids", "Selected File IDs")),
                kvDetail("manifest-selection-summary", "Selection Summary", [
                    { label: "inputCount", value: manifest.length },
                    { label: "selectedCount", value: selectedIds.length },
                ], traceI18n("trace.detail.selection_summary", "Selection Summary")),
            ],
            ...(manifestSelectionPromptDebug ? { promptDebug: manifestSelectionPromptDebug } : {}),
        });
        const fullRecords = store.getFullMemoryRecordsByIds(selectedIds);
        const loadedRecords = applyRecallContentBudgets(fullRecords.map((record) => ({
            relativePath: record.relativePath,
            type: record.type,
            updatedAt: record.updatedAt,
            content: record.content,
        })));
        const missingIds = selectedIds.filter((id) => !fullRecords.some((record) => record.relativePath === id));
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "files_loaded",
            title: "Files Loaded",
            titleI18n: traceI18n("trace.step.files_loaded", "Files Loaded"),
            status: loadedRecords.length > 0 ? "success" : selectedIds.length > 0 ? "warning" : "skipped",
            inputSummary: `${selectedIds.length} requested`,
            inputSummaryI18n: traceI18n("trace.text.files_loaded.input", "{0} requested", selectedIds.length),
            outputSummary: `${loadedRecords.length} files loaded.`,
            outputSummaryI18n: traceI18n("trace.text.files_loaded.output", "{0} files loaded.", loadedRecords.length),
            details: [
                listDetail("requested-files", "Requested IDs", selectedIds, traceI18n("trace.detail.requested_ids", "Requested IDs")),
                listDetail("loaded-files", "Loaded Files", loadedRecords.map((record) => `${record.relativePath} | ${record.truncated ? "truncated" : "full"} | ${previewText(record.content, 180)}`), traceI18n("trace.detail.loaded_files", "Loaded Files")),
                ...(loadedRecords.some((record) => record.truncated)
                    ? [jsonDetail("truncated-files", "Truncated Files", loadedRecords
                            .filter((record) => record.truncated)
                            .map((record) => ({
                            relativePath: record.relativePath,
                            originalChars: record.originalChars,
                            loadedChars: record.loadedChars,
                        })), traceI18n("trace.detail.truncated_files", "Truncated Files"))]
                    : []),
                ...(missingIds.length > 0
                    ? [listDetail("missing-files", "Missing IDs", missingIds, traceI18n("trace.detail.missing_ids", "Missing IDs"))]
                    : []),
            ],
        });
        const disambiguationRequired = route === "project_memory" && !resolvedProjectMeta && !resolvedTmpProject;
        const context = renderContext(route, userSummary, resolvedProjectMeta, loadedRecords, disambiguationRequired);
        trace.steps.push({
            stepId: `${traceId}:step:${trace.steps.length + 1}`,
            kind: "context_rendered",
            title: "Context Rendered",
            titleI18n: traceI18n("trace.step.context_rendered", "Context Rendered"),
            status: context.trim() ? "success" : "warning",
            inputSummary: `${loadedRecords.length} files + ${hasUserSummary(userSummary) ? "user base" : "no user base"}`,
            inputSummaryI18n: hasUserSummary(userSummary)
                ? traceI18n("trace.text.context_rendered.input.with_user_base", "{0} files + user base", loadedRecords.length)
                : traceI18n("trace.text.context_rendered.input.no_user_base", "{0} files + no user base", loadedRecords.length),
            outputSummary: context.trim() ? "Memory context prepared." : "No memory context injected.",
            outputSummaryI18n: context.trim()
                ? traceI18n("trace.text.context_rendered.output.prepared", "Memory context prepared.")
                : traceI18n("trace.text.context_rendered.no_memory_context", "No memory context injected."),
            details: [
                kvDetail("context-rendered-summary", "Context Summary", [
                    { label: "route", value: route },
                    { label: "userBaseInjected", value: hasUserSummary(userSummary) ? "yes" : "no" },
                    { label: "projectMetaInjected", value: resolvedProjectMeta ? "yes" : "no" },
                    { label: "disambiguationRequired", value: disambiguationRequired ? "yes" : "no" },
                    { label: "fileCount", value: loadedRecords.length },
                    { label: "characters", value: context.length },
                    { label: "lines", value: context ? context.split("\n").length : 0 },
                ], traceI18n("trace.detail.context_summary", "Context Summary")),
                listDetail("context-rendered-blocks", "Injected Blocks", [
                    ...(hasUserSummary(userSummary) ? ["global/User/user-profile.md"] : []),
                    ...(resolvedProjectMeta ? [resolvedProjectMeta.relativePath] : []),
                    ...loadedRecords.map((record) => record.relativePath),
                ], traceI18n("trace.detail.injected_blocks", "Injected Blocks")),
            ],
        });
        trace.finishedAt = nowIso();
        const result = {
            query: normalizedQuery,
            intent: route,
            context,
            trace,
            debug: {
                mode: context.trim() ? "llm" : "none",
                elapsedMs: Date.now() - startedAt,
                cacheHit: false,
                path: retrievalMode,
                route,
                manifestCount: manifest.length,
                selectedFileIds: selectedIds,
                ...(resolvedProjectId ? { resolvedProjectId } : {}),
            },
        };
        this.updateRuntimeStats(result, startedAt, false, context.trim() ? "llm" : "none", retrievalMode);
        this.saveCache(cacheKey, result);
        return result;
    }
}
