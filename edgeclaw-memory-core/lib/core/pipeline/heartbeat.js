import { traceI18n } from "../trace-i18n.js";
import { buildL0IndexId, hashText, nowIso } from "../utils/id.js";
import { decodeEscapedUnicodeText, decodeEscapedUnicodeValue } from "../utils/text.js";
const LAST_INDEXED_AT_STATE_KEY = "lastIndexedAt";
function sameMessage(left, right) {
    if (!left || !right)
        return false;
    return left.role === right.role && left.content === right.content;
}
function hasNewContent(previous, incoming) {
    if (incoming.length === 0)
        return false;
    if (previous.length === 0)
        return true;
    if (incoming.length > previous.length)
        return true;
    for (let index = 0; index < incoming.length; index += 1) {
        if (!sameMessage(previous[index], incoming[index]))
            return true;
    }
    return false;
}
function emptyStats() {
    return {
        capturedSessions: 0,
        writtenFiles: 0,
        writtenUserFiles: 0,
        writtenProjectFiles: 0,
        writtenFeedbackFiles: 0,
        userProfilesUpdated: 0,
        failedSessions: 0,
    };
}
function flattenBatchMessages(sessions, seedMessages = []) {
    let previousMessages = seedMessages;
    for (const session of sessions) {
        previousMessages = mergeSessionMessages(previousMessages, session.messages).mergedMessages;
    }
    return previousMessages;
}
function commonPrefixLength(previous, incoming) {
    const limit = Math.min(previous.length, incoming.length);
    let index = 0;
    while (index < limit && sameMessage(previous[index], incoming[index])) {
        index += 1;
    }
    return index;
}
function mergeSessionMessages(previousMessages, incomingMessages) {
    if (previousMessages.length === 0) {
        return {
            mergedMessages: incomingMessages,
            newMessages: incomingMessages,
        };
    }
    const prefixLength = commonPrefixLength(previousMessages, incomingMessages);
    if (prefixLength > 0) {
        return {
            mergedMessages: incomingMessages,
            newMessages: incomingMessages.slice(prefixLength),
        };
    }
    return {
        mergedMessages: [...previousMessages, ...incomingMessages],
        newMessages: incomingMessages,
    };
}
function deriveFocusTurns(previousMessages, sessions) {
    const focusTurns = new Map();
    let cursorMessages = previousMessages;
    for (const session of sessions) {
        const merged = mergeSessionMessages(cursorMessages, session.messages);
        focusTurns.set(session.l0IndexId, merged.newMessages.filter((message) => message.role === "user"));
        cursorMessages = merged.mergedMessages;
    }
    return focusTurns;
}
function buildIndexTraceId(sessionKey, startedAt, l0Ids) {
    return `index_trace_${hashText(`${sessionKey}:${startedAt}:${l0Ids.join(",")}`)}`;
}
function normalizeTrigger(reason) {
    const normalized = (reason ?? "").trim().toLowerCase();
    if (normalized.includes("scheduled"))
        return "scheduled";
    return "manual_sync";
}
function previewText(text, maxChars = 220) {
    const normalized = decodeEscapedUnicodeText(text, true).replace(/\s+/g, " ").trim();
    if (normalized.length <= maxChars)
        return normalized;
    return `${normalized.slice(0, maxChars)}...`;
}
function inferStorageKind(record) {
    if (record.type === "user") {
        return /\/?UserNotes\//.test(record.relativePath) ? "global_user_note" : "global_user";
    }
    return record.type === "feedback" ? "feedback" : "project";
}
function exposeStoredRelativePath(record) {
    return record.scope === "global" ? `global/${record.relativePath}` : record.relativePath;
}
function textDetail(key, label, text, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "text",
        text: decodeEscapedUnicodeText(text, true),
    };
}
function noteDetail(key, label, text, labelI18n) {
    return {
        key,
        label,
        ...(labelI18n ? { labelI18n } : {}),
        kind: "note",
        text: decodeEscapedUnicodeText(text, true),
    };
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
function createStep(trace, kind, title, status, inputSummary, outputSummary, options = {}) {
    trace.steps.push({
        stepId: `${trace.indexTraceId}:step:${trace.steps.length + 1}`,
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
function createBatchTrace(sessionKey, sessions, trigger, focusUserTurnCount) {
    const startedAt = nowIso();
    const timestamps = sessions.map((session) => session.timestamp).filter(Boolean).sort();
    return {
        indexTraceId: buildIndexTraceId(sessionKey, startedAt, sessions.map((session) => session.l0IndexId)),
        sessionKey,
        trigger,
        startedAt,
        status: "running",
        isNoOp: false,
        displayStatus: "Running",
        batchSummary: {
            l0Ids: sessions.map((session) => session.l0IndexId),
            segmentCount: sessions.length,
            focusUserTurnCount,
            fromTimestamp: timestamps[0] ?? "",
            toTimestamp: timestamps[timestamps.length - 1] ?? "",
        },
        steps: [],
        storedResults: [],
    };
}
export class HeartbeatIndexer {
    repository;
    extractor;
    batchSize;
    source;
    logger;
    settings;
    constructor(repository, extractor, options) {
        this.repository = repository;
        this.extractor = extractor;
        this.batchSize = options.batchSize ?? 30;
        this.source = options.source ?? "openclaw";
        this.settings = options.settings;
        this.logger = options.logger;
    }
    getSettings() {
        return { ...this.settings };
    }
    setSettings(settings) {
        this.settings = { ...settings };
    }
    captureL0Session(input) {
        const timestamp = input.timestamp ?? nowIso();
        const recent = this.repository.listRecentL0(1)[0];
        if (recent?.sessionKey === input.sessionKey && !hasNewContent(recent.messages, input.messages)) {
            this.logger?.info?.(`[clawxmemory] skip duplicate l0 capture for session=${input.sessionKey}`);
            return undefined;
        }
        const payload = JSON.stringify(input.messages);
        const l0IndexId = buildL0IndexId(input.sessionKey, timestamp, payload);
        const record = {
            l0IndexId,
            sessionKey: input.sessionKey,
            timestamp,
            messages: input.messages,
            source: input.source ?? this.source,
            indexed: false,
            createdAt: nowIso(),
        };
        this.repository.insertL0Session(record);
        return record;
    }
    async runHeartbeat(options = {}) {
        const stats = emptyStats();
        const sessionKeys = this.repository.listPendingSessionKeys(Math.max(1, options.batchSize ?? this.batchSize), options.sessionKeys);
        if (sessionKeys.length === 0)
            return stats;
        const store = this.repository.getFileMemoryStore();
        for (const sessionKey of sessionKeys) {
            const sessions = this.repository.listUnindexedL0BySession(sessionKey);
            if (sessions.length === 0)
                continue;
            const previousIndexedSession = this.repository.getLatestL0Before(sessionKey, sessions[0]?.timestamp ?? "", sessions[0]?.createdAt ?? "");
            const previousMessages = previousIndexedSession?.messages ?? [];
            const focusTurnsBySession = deriveFocusTurns(previousMessages, sessions);
            const batchContextMessages = flattenBatchMessages(sessions, previousMessages);
            const focusUserTurnCount = Array.from(focusTurnsBySession.values()).reduce((count, turns) => count + turns.length, 0);
            const trace = createBatchTrace(sessionKey, sessions, normalizeTrigger(options.reason), focusUserTurnCount);
            createStep(trace, "index_start", "Index Started", "info", `trigger=${trace.trigger}`, `Preparing batch indexing for ${sessionKey}.`, {
                titleI18n: traceI18n("trace.step.index_start", "Index Started"),
                outputSummaryI18n: traceI18n("trace.text.index_start.output.preparing_batch", "Preparing batch indexing for {0}.", sessionKey),
            });
            createStep(trace, "batch_loaded", "Batch Loaded", "info", `${trace.batchSummary.segmentCount} segments from ${trace.batchSummary.fromTimestamp || "n/a"} to ${trace.batchSummary.toTimestamp || "n/a"}`, `${batchContextMessages.length} messages loaded into batch context.`, {
                titleI18n: traceI18n("trace.step.batch_loaded", "Batch Loaded"),
                inputSummaryI18n: traceI18n("trace.text.batch_loaded.input", "{0} segments from {1} to {2}", trace.batchSummary.segmentCount, trace.batchSummary.fromTimestamp || "n/a", trace.batchSummary.toTimestamp || "n/a"),
                outputSummaryI18n: traceI18n("trace.text.batch_loaded.output", "{0} messages loaded into batch context.", batchContextMessages.length),
                metrics: {
                    segmentCount: trace.batchSummary.segmentCount,
                    focusUserTurnCount: trace.batchSummary.focusUserTurnCount,
                },
                details: [
                    kvDetail("batch-summary", "Batch Summary", [
                        { label: "sessionKey", value: sessionKey },
                        { label: "from", value: trace.batchSummary.fromTimestamp || "" },
                        { label: "to", value: trace.batchSummary.toTimestamp || "" },
                        { label: "l0Ids", value: trace.batchSummary.l0Ids.join(", ") || "none" },
                    ], traceI18n("trace.detail.batch_summary", "Batch Summary")),
                    jsonDetail("batch-context", "Batch Context", batchContextMessages.map((message, index) => ({
                        index,
                        role: message.role,
                        content: message.content,
                    })), traceI18n("trace.detail.batch_context", "Batch Context")),
                ],
            });
            createStep(trace, "focus_turns_selected", "Focus Turns Selected", trace.batchSummary.focusUserTurnCount > 0 ? "success" : "warning", `${trace.batchSummary.focusUserTurnCount} user turns in this batch.`, trace.batchSummary.focusUserTurnCount > 0
                ? "User turns will be classified one by one."
                : "No user turns found; this batch will be marked indexed without storing memory.", {
                titleI18n: traceI18n("trace.step.focus_turns_selected", "Focus Turns Selected"),
                inputSummaryI18n: traceI18n("trace.text.focus_turns_selected.input", "{0} user turns in this batch.", trace.batchSummary.focusUserTurnCount),
                outputSummaryI18n: trace.batchSummary.focusUserTurnCount > 0
                    ? traceI18n("trace.text.focus_turns_selected.output.classifying", "User turns will be classified one by one.")
                    : traceI18n("trace.text.focus_turns_selected.output.no_user_turns", "No user turns found; this batch will be marked indexed without storing memory."),
                details: [
                    kvDetail("focus-turn-selection-summary", "Focus Selection Summary", [
                        { label: "userTurns", value: String(trace.batchSummary.focusUserTurnCount) },
                        { label: "assistantMessagesInContext", value: String(batchContextMessages.filter((message) => message.role === "assistant").length) },
                        { label: "assistantUsedAsContextOnly", value: "yes" },
                    ], traceI18n("trace.detail.focus_selection_summary", "Focus Selection Summary")),
                    ...sessions
                        .flatMap((session) => focusTurnsBySession.get(session.l0IndexId) ?? [])
                        .map((message, index) => textDetail(`focus-turn-${index + 1}`, `Focus Turn ${index + 1}`, message.content, traceI18n("trace.detail.focus_turn", "Focus Turn {0}", index + 1))),
                ],
            });
            this.repository.saveIndexTrace(trace);
            const processedIds = [];
            let sessionHadError = false;
            for (const session of sessions) {
                try {
                    const focusUserTurns = focusTurnsBySession.get(session.l0IndexId) ?? [];
                    if (focusUserTurns.length === 0) {
                        processedIds.push(session.l0IndexId);
                        stats.capturedSessions += 1;
                        continue;
                    }
                    for (const focusTurn of focusUserTurns) {
                        const currentProjectMeta = this.repository.getProjectMeta() ?? store.getProjectMeta() ?? null;
                        let classificationPromptDebug;
                        const classification = await this.extractor.classifyMemoryTurn({
                            timestamp: session.timestamp,
                            sessionKey: session.sessionKey,
                            focusUserTurn: focusTurn,
                            batchContextMessages,
                            currentProjectMeta,
                            debugTrace: (debug) => {
                                classificationPromptDebug = debug;
                            },
                        });
                        const labels = classification.shouldStore ? classification.labels : [];
                        createStep(trace, "classification", "Classification", labels.length > 0 ? "success" : "skipped", previewText(focusTurn.content, 220), labels.length > 0
                            ? `classified=${labels.map((label) => label.type).join(", ")}`
                            : "classified=none", {
                            refs: {
                                classification: labels.length > 0 ? labels.map((label) => label.type) : ["none"],
                            },
                            details: [
                                textDetail(`focus-turn-text-${session.l0IndexId}`, "Focus User Turn", focusTurn.content, traceI18n("trace.detail.focus_user_turn", "Focus User Turn")),
                                kvDetail(`classification-result-${session.l0IndexId}`, "Classification Result", [
                                    { label: "sessionKey", value: session.sessionKey },
                                    { label: "timestamp", value: session.timestamp },
                                    { label: "result", value: labels.length > 0 ? labels.map((label) => label.type).join(", ") : "none" },
                                ], traceI18n("trace.detail.classification_result", "Classification Result")),
                                jsonDetail(`classification-labels-${session.l0IndexId}`, "Classification Labels", labels, traceI18n("trace.detail.classifier_candidates", "Classifier Candidates")),
                            ],
                            ...(classificationPromptDebug ? { promptDebug: classificationPromptDebug } : {}),
                        });
                        const createdCandidates = [];
                        for (const label of labels) {
                            let createPromptDebug;
                            const candidate = label.type === "user"
                                ? await this.extractor.createUserMemoryNote({
                                    timestamp: session.timestamp,
                                    sessionKey: session.sessionKey,
                                    focusUserTurn: focusTurn,
                                    batchContextMessages,
                                    currentProjectMeta,
                                    classification: label,
                                    debugTrace: (debug) => {
                                        createPromptDebug = debug;
                                    },
                                })
                                : label.type === "project"
                                    ? await this.extractor.createProjectMemoryNote({
                                        timestamp: session.timestamp,
                                        sessionKey: session.sessionKey,
                                        focusUserTurn: focusTurn,
                                        batchContextMessages,
                                        currentProjectMeta,
                                        classification: label,
                                        debugTrace: (debug) => {
                                            createPromptDebug = debug;
                                        },
                                    })
                                    : await this.extractor.createFeedbackMemoryNote({
                                        timestamp: session.timestamp,
                                        sessionKey: session.sessionKey,
                                        focusUserTurn: focusTurn,
                                        batchContextMessages,
                                        currentProjectMeta,
                                        classification: label,
                                        debugTrace: (debug) => {
                                            createPromptDebug = debug;
                                        },
                                    });
                            createdCandidates.push({ label, candidate });
                            createStep(trace, label.type === "user" ? "user_create" : label.type === "project" ? "project_create" : "feedback_create", `${label.type} Create`, candidate ? "success" : "skipped", `${label.type} | ${label.reason || "no explicit reason"}`, candidate ? `created=${candidate.name}` : `skipped=${label.type}`, {
                                refs: {
                                    candidateType: label.type,
                                },
                                details: [
                                    jsonDetail(`create-${label.type}-${session.l0IndexId}`, `${label.type} Create Result`, {
                                        classification: label,
                                        candidate: candidate
                                            ? {
                                                type: candidate.type,
                                                name: candidate.name,
                                                description: candidate.description,
                                                body: candidate.body ?? "",
                                            }
                                            : null,
                                    }),
                                ],
                                ...(createPromptDebug ? { promptDebug: createPromptDebug } : {}),
                            });
                        }
                        const persistedRecords = [];
                        let wroteGlobalUserNote = false;
                        for (const { candidate } of createdCandidates) {
                            if (!candidate)
                                continue;
                            const targetStore = candidate.type === "user"
                                ? this.repository.getGlobalUserStore()
                                : store;
                            const record = targetStore.upsertCandidate(candidate);
                            if (candidate.type === "user")
                                wroteGlobalUserNote = true;
                            persistedRecords.push(record);
                            trace.storedResults.push({
                                candidateType: candidate.type,
                                candidateName: candidate.name,
                                scope: candidate.scope,
                                ...(record.projectId ? { projectId: record.projectId } : {}),
                                relativePath: exposeStoredRelativePath(record),
                                storageKind: inferStorageKind(record),
                            });
                            stats.writtenFiles += 1;
                            if (candidate.type === "user")
                                stats.writtenUserFiles += 1;
                            if (candidate.type === "project")
                                stats.writtenProjectFiles += 1;
                            if (candidate.type === "feedback")
                                stats.writtenFeedbackFiles += 1;
                        }
                        if (wroteGlobalUserNote) {
                            this.repository.repairWorkspaceManifest();
                        }
                        createStep(trace, "persist", "Persist", persistedRecords.length > 0 ? "success" : "skipped", `${createdCandidates.filter((entry) => entry.candidate).length} candidates ready to persist.`, persistedRecords.length > 0
                            ? `${persistedRecords.length} memory files written.`
                            : "No memory files were written for this turn.", {
                            details: [jsonDetail(`persisted-files-${session.l0IndexId}`, "Persisted Files", persistedRecords.map((record) => ({
                                    type: record.type,
                                    name: record.name,
                                    projectId: record.projectId ?? null,
                                    relativePath: exposeStoredRelativePath(record),
                                    storageKind: inferStorageKind(record),
                                })), traceI18n("trace.detail.persisted_files", "Persisted Files"))],
                        });
                    }
                    processedIds.push(session.l0IndexId);
                    stats.capturedSessions += 1;
                    this.repository.setPipelineState(LAST_INDEXED_AT_STATE_KEY, session.timestamp);
                    this.repository.setPipelineState(`lastIndexedCursor:${session.sessionKey}`, session.timestamp);
                }
                catch (error) {
                    stats.failedSessions += 1;
                    sessionHadError = true;
                    createStep(trace, "index_finished", "Index Error", "error", session.l0IndexId, error instanceof Error ? error.message : String(error), {
                        titleI18n: traceI18n("trace.text.index_error.title", "Index Error"),
                        details: [noteDetail(`index-error-${session.l0IndexId}`, "Index Error", error instanceof Error ? error.message : String(error), traceI18n("trace.detail.index_error", "Index Error"))],
                    });
                    this.logger?.warn?.(`[clawxmemory] heartbeat file-memory extraction failed for ${session.l0IndexId}: ${String(error)}`);
                }
            }
            if (processedIds.length > 0) {
                this.repository.markL0Indexed(processedIds);
            }
            trace.finishedAt = nowIso();
            trace.status = sessionHadError ? "error" : "completed";
            trace.isNoOp = trace.storedResults.length === 0;
            trace.displayStatus = sessionHadError
                ? "Error"
                : trace.isNoOp
                    ? "No-op"
                    : "Completed";
            createStep(trace, "index_finished", "Index Finished", sessionHadError ? "warning" : "success", `segments=${trace.batchSummary.segmentCount}`, `stored=${trace.storedResults.length}, failed=${sessionHadError ? 1 : 0}`, {
                titleI18n: traceI18n("trace.step.index_finished", "Index Finished"),
                metrics: {
                    storedResults: trace.storedResults.length,
                    failed: sessionHadError ? 1 : 0,
                },
                details: [jsonDetail("stored-results", "Stored Results", trace.storedResults, traceI18n("trace.detail.stored_results", "Stored Results"))],
            });
            this.repository.saveIndexTrace(trace);
        }
        return stats;
    }
}
