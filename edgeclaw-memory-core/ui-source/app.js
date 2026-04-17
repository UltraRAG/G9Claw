const params = new URLSearchParams(window.location.search);

const state = {
  token: params.get("token") || "",
  projectPath: params.get("projectPath") || "",
  workspaceQuery: "",
  activePage: "project",
  activeTraceTab: "recall",
  overview: null,
  settings: null,
  workspace: null,
  userSummary: null,
  caseTraces: [],
  indexTraces: [],
  dreamTraces: [],
  detailOpen: false,
  settingsOpen: false,
};

const DEFAULT_ACTIVITY = "已就绪";

const appScrimEl = document.getElementById("appScrim");
const activityTextEl = document.getElementById("activityText");
const statusBarEl = document.getElementById("statusBar");
const navLastIndexedEl = document.getElementById("navLastIndexed");
const navProjectCountEl = document.getElementById("navProjectCount");
const navUserCountEl = document.getElementById("navUserCount");
const navTraceCountEl = document.getElementById("navTraceCount");
const boardNavTabs = Array.from(document.querySelectorAll(".nav-tab[data-page]"));
const traceSubTabs = Array.from(document.querySelectorAll(".trace-tab[data-trace]"));
const settingsToggleBtn = document.getElementById("settingsToggleBtn");
const settingsDrawerEl = document.getElementById("settingsDrawer");
const settingsCloseBtn = document.getElementById("settingsCloseBtn");
const saveSettingsBtn = document.getElementById("saveSettingsBtn");
const settingAutoIndexEl = document.getElementById("settingAutoIndex");
const settingAutoDreamEl = document.getElementById("settingAutoDream");
const refreshBtn = document.getElementById("refreshBtn");
const indexBtn = document.getElementById("indexBtn");
const dreamBtn = document.getElementById("dreamBtn");
const exportBtn = document.getElementById("exportBtn");
const importBtn = document.getElementById("importBtn");
const importInput = document.getElementById("importInput");
const clearBtn = document.getElementById("clearBtn");
const workspaceSearchEl = document.getElementById("workspaceSearch");
const workspaceSearchBtn = document.getElementById("workspaceSearchBtn");
const listSearchRowEl = document.getElementById("listSearchRow");
const projectBoardEl = document.getElementById("projectBoard");
const userBoardEl = document.getElementById("userBoard");
const traceBoardEl = document.getElementById("traceBoard");
const projectContextSectionEl = document.getElementById("projectContextSection");
const projectEntriesEl = document.getElementById("projectEntries");
const projectEntriesCountEl = document.getElementById("projectEntriesCount");
const feedbackEntriesSectionEl = document.getElementById("feedbackEntriesSection");
const feedbackEntriesEl = document.getElementById("feedbackEntries");
const feedbackEntriesCountEl = document.getElementById("feedbackEntriesCount");
const deprecatedEntriesSectionEl = document.getElementById("deprecatedEntriesSection");
const deprecatedEntriesEl = document.getElementById("deprecatedEntries");
const deprecatedEntriesCountEl = document.getElementById("deprecatedEntriesCount");
const userSummaryEl = document.getElementById("userSummary");
const userSummaryCountEl = document.getElementById("userSummaryCount");

const recallPanelEl = document.getElementById("recallPanel");
const recallCaseSelectEl = document.getElementById("recallCaseSelect");
const recallTraceCountEl = document.getElementById("recallTraceCount");
const recallDetailEl = document.getElementById("recallDetail");
const recallEmptyEl = document.getElementById("recallEmpty");
const recallMetaTableEl = document.getElementById("recallMetaTable");
const recallContextEl = document.getElementById("recallContext");
const recallToolEventsEl = document.getElementById("recallToolEvents");
const recallReplyEl = document.getElementById("recallReply");
const recallStepsEl = document.getElementById("recallSteps");

const indexPanelEl = document.getElementById("indexPanel");
const indexTraceSelectEl = document.getElementById("indexTraceSelect");
const indexTraceCountEl = document.getElementById("indexTraceCount");
const indexDetailEl = document.getElementById("indexDetail");
const indexEmptyEl = document.getElementById("indexEmpty");
const indexStepsEl = document.getElementById("indexSteps");

const dreamPanelEl = document.getElementById("dreamPanel");
const dreamTraceSelectEl = document.getElementById("dreamTraceSelect");
const dreamTraceCountEl = document.getElementById("dreamTraceCount");
const dreamDetailEl = document.getElementById("dreamDetail");
const dreamEmptyEl = document.getElementById("dreamEmpty");
const dreamStepsEl = document.getElementById("dreamSteps");

const detailDrawerEl = document.getElementById("detailDrawer");
const detailCloseBtn = document.getElementById("detailCloseBtn");
const detailEmptyEl = document.getElementById("detailEmpty");
const detailViewEl = document.getElementById("detailView");
const detailMetaEl = document.getElementById("detailMeta");
const detailTitleEl = document.getElementById("detailTitle");
const detailDescriptionEl = document.getElementById("detailDescription");
const detailActionsEl = document.getElementById("detailActions");
const detailContentEl = document.getElementById("detailContent");

const PAGE_CONFIG = {
  project: { title: "项目记忆" },
  user: { title: "用户画像" },
  trace: { title: "记忆追踪" },
};

/* ── Utilities ── */

function setActivity(msg = DEFAULT_ACTIVITY) { activityTextEl.textContent = msg || DEFAULT_ACTIVITY; }

function updateAppScrim() {
  const open = state.detailOpen || state.settingsOpen;
  appScrimEl.classList.toggle("is-open", open);
  appScrimEl.classList.toggle("hidden", !open);
}

function setStatus(message, kind = "info") {
  if (!message) { statusBarEl.classList.add("hidden"); statusBarEl.textContent = ""; setActivity(DEFAULT_ACTIVITY); return; }
  if (kind === "error") { statusBarEl.classList.remove("hidden"); statusBarEl.textContent = message; statusBarEl.dataset.kind = kind; setActivity("发生错误"); return; }
  statusBarEl.classList.add("hidden"); statusBarEl.textContent = ""; delete statusBarEl.dataset.kind; setActivity(message);
}

function headers(extra = {}) { return state.token ? { Authorization: `Bearer ${state.token}`, ...extra } : { ...extra }; }

function withProjectPath(url) {
  const next = new URL(url, window.location.origin);
  if (state.projectPath) next.searchParams.set("projectPath", state.projectPath);
  return `${next.pathname}${next.search}`;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(withProjectPath(url), {
    method: options.method || "GET", headers: headers(options.headers),
    ...(options.body ? { body: JSON.stringify({ ...options.body, projectPath: state.projectPath }) } : {}),
  });
  const raw = await response.text();
  let data = null;
  if (raw) { try { data = JSON.parse(raw); } catch { data = null; } }
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error("需要登录后才能访问当前项目的 Memory Dashboard。");
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }
  return data;
}

async function fetchBlob(url) {
  const response = await fetch(withProjectPath(url), { headers: headers() });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error("需要登录后才能访问当前项目的 Memory Dashboard。");
    throw new Error(await response.text());
  }
  return response.blob();
}

function el(tag, cls, text) { const n = document.createElement(tag); if (cls) n.className = cls; if (typeof text === "string") n.textContent = text; return n; }
function clearNode(n) { while (n.firstChild) n.removeChild(n.firstChild); }
function renderEmpty(t, text) { clearNode(t); t.append(el("div", "empty-state", text)); }

function formatDateTime(v) { if (!v) return "—"; const d = new Date(v); if (Number.isNaN(d.getTime())) return v; return d.toLocaleString(); }
function stringifyDetail(v) { return typeof v === "string" ? v : JSON.stringify(v, null, 2); }
function basename(v) { const s = String(v || "").replace(/[\\/]+$/, "").split(/[\\/]/).filter(Boolean); return s[s.length - 1] || v || "Current Project"; }

function countUserSummaryRecords(s) {
  if (!s) return 0;
  return s.profile || s.preferences?.length || s.constraints?.length || s.relationships?.length ? 1 : 0;
}

function getProjectCardCount() { return state.workspace?.projectEntries?.length || 0; }

function updateCounts() {
  navProjectCountEl.textContent = String(getProjectCardCount());
  navUserCountEl.textContent = String(countUserSummaryRecords(state.userSummary));
  navTraceCountEl.textContent = String(state.caseTraces.length + state.indexTraces.length + state.dreamTraces.length);
  projectEntriesCountEl.textContent = String(state.workspace?.projectEntries?.length || 0);
  feedbackEntriesCountEl.textContent = String(state.workspace?.feedbackEntries?.length || 0);
  deprecatedEntriesCountEl.textContent = String((state.workspace?.deprecatedProjectEntries?.length || 0) + (state.workspace?.deprecatedFeedbackEntries?.length || 0));
  userSummaryCountEl.textContent = String(countUserSummaryRecords(state.userSummary));
  recallTraceCountEl.textContent = String(state.caseTraces.length);
  indexTraceCountEl.textContent = String(state.indexTraces.length);
  dreamTraceCountEl.textContent = String(state.dreamTraces.length);
  navLastIndexedEl.textContent = formatDateTime(state.overview?.lastIndexedAt || "") === "—" ? "等待索引" : formatDateTime(state.overview?.lastIndexedAt || "");
}

/* ── Page / Tab Navigation ── */

function applyPageChrome() {
  listSearchRowEl.classList.toggle("hidden", state.activePage !== "project");
  projectBoardEl.classList.toggle("board-active", state.activePage === "project");
  userBoardEl.classList.toggle("board-active", state.activePage === "user");
  traceBoardEl.classList.toggle("board-active", state.activePage === "trace");
  boardNavTabs.forEach((b) => b.classList.toggle("active", b.dataset.page === state.activePage));
}

function setActivePage(page) { if (!PAGE_CONFIG[page]) return; state.activePage = page; applyPageChrome(); }

function applyTraceTabChrome() {
  traceSubTabs.forEach((b) => b.classList.toggle("active", b.dataset.trace === state.activeTraceTab));
  recallPanelEl.classList.toggle("trace-panel-active", state.activeTraceTab === "recall");
  indexPanelEl.classList.toggle("trace-panel-active", state.activeTraceTab === "index");
  dreamPanelEl.classList.toggle("trace-panel-active", state.activeTraceTab === "dream");
}

function setActiveTraceTab(tab) { state.activeTraceTab = tab; applyTraceTabChrome(); }

/* ── Settings Drawer ── */

function openSettingsDrawer() {
  state.settingsOpen = true;
  settingsDrawerEl.classList.remove("hidden");
  if (state.settings) {
    settingAutoIndexEl.value = String(Math.round((state.settings.autoIndexIntervalMinutes ?? 60) / 60));
    settingAutoDreamEl.value = String(Math.round((state.settings.autoDreamIntervalMinutes ?? 360) / 60));
  }
  updateAppScrim();
}

function closeSettingsDrawer() { state.settingsOpen = false; settingsDrawerEl.classList.add("hidden"); updateAppScrim(); }

/* ── Detail Drawer ── */

function openDetailDrawer() { state.detailOpen = true; detailDrawerEl.classList.remove("hidden"); updateAppScrim(); }
function closeDetailDrawer() { state.detailOpen = false; detailDrawerEl.classList.add("hidden"); updateAppScrim(); }

function showDetail({ meta = "", title = "", description = "", content = "", actions = [] }) {
  detailMetaEl.textContent = meta;
  detailTitleEl.textContent = title;
  detailDescriptionEl.textContent = description;
  detailContentEl.textContent = content;
  clearNode(detailActionsEl);
  actions.forEach((a) => {
    const btn = el("button", "tool-btn", a.label);
    if (a.variant === "danger") btn.classList.add("danger");
    btn.addEventListener("click", a.onClick);
    detailActionsEl.append(btn);
  });
  detailEmptyEl.classList.add("hidden");
  detailViewEl.classList.remove("hidden");
  openDetailDrawer();
}

/* ── Project Context Card (editable) ── */

function renderProjectContext() {
  clearNode(projectContextSectionEl);
  const pm = state.workspace?.projectMeta;
  const projectName = pm?.projectName || basename(state.projectPath);

  const wrapper = el("div", "project-context-head");
  const copy = el("div", "project-context-copy");
  copy.append(el("h4", "", projectName));
  copy.append(el("p", "", pm?.description || "当前打开的 workspace 就是唯一顶层 project。"));
  wrapper.append(copy);

  const editBtn = el("button", "action-btn", "编辑");
  editBtn.addEventListener("click", () => void editProjectMeta());
  wrapper.append(editBtn);

  projectContextSectionEl.append(wrapper);

  const meta = el("div", "project-context-meta");
  [
    `状态 ${pm?.status || "in_progress"}`,
    `项目记忆 ${state.workspace?.projectEntries?.length || 0}`,
    `协作反馈 ${state.workspace?.feedbackEntries?.length || 0}`,
    `项目路径 ${basename(state.projectPath)}`,
  ].forEach((text) => meta.append(el("span", "context-chip", text)));
  projectContextSectionEl.append(meta);
}

/* ── User Summary (ONLY user data) ── */

function renderUserSummary() {
  clearNode(userSummaryEl);
  const summary = state.userSummary;
  if (!summary || (!summary.profile && !summary.preferences?.length && !summary.constraints?.length && !summary.relationships?.length)) {
    userSummaryEl.append(el("div", "empty-state", "当前没有用户画像。"));
    updateCounts(); applyPageChrome(); return;
  }
  if (summary.profile) {
    const card = el("div", "entry-card"); card.dataset.kind = "feedback";
    card.append(el("h4", "", "Profile"));
    card.append(el("div", "", summary.profile));
    userSummaryEl.append(card);
  }
  [["Preferences", summary.preferences || []], ["Constraints", summary.constraints || []], ["Relationships", summary.relationships || []]].forEach(([title, items]) => {
    if (!items.length) return;
    const card = el("div", "entry-card"); card.dataset.kind = "feedback";
    card.append(el("h4", "", title));
    const list = el("ul", "");
    items.forEach((item) => list.append(el("li", "", item)));
    card.append(list);
    userSummaryEl.append(card);
  });
  updateCounts(); applyPageChrome();
}

/* ── Memory Entry CRUD ── */

async function openMemoryDetail(id) {
  const records = await fetchJson(`/api/memory/memory/get?ids=${encodeURIComponent(id)}`);
  const record = Array.isArray(records) ? records[0] : null;
  if (!record) { setStatus("未找到该记忆文件。", "error"); return; }
  showDetail({
    meta: `${record.type} · ${formatDateTime(record.updatedAt)}`,
    title: record.name, description: record.description, content: record.content,
    actions: [
      { label: "编辑", onClick: () => void editEntry(record) },
      { label: record.deprecated ? "恢复" : "弃用", onClick: () => void toggleDeprecation(record) },
      { label: "删除", variant: "danger", onClick: () => void deleteEntry(record) },
    ],
  });
}

async function editEntry(record) {
  const name = window.prompt("更新记忆名称", record.name); if (name === null) return;
  const description = window.prompt("更新记忆描述", record.description); if (description === null) return;
  await fetchJson("/api/memory/memory/actions", { method: "POST", headers: { "Content-Type": "application/json" }, body: { action: "edit_entry", id: record.relativePath, name, description } });
  setStatus("记忆已更新。"); await loadWorkspace(); await openMemoryDetail(record.relativePath);
}

async function toggleDeprecation(record) {
  await fetchJson("/api/memory/memory/actions", { method: "POST", headers: { "Content-Type": "application/json" }, body: { action: record.deprecated ? "restore_entries" : "deprecate_entries", ids: [record.relativePath] } });
  setStatus(record.deprecated ? "记忆已恢复。" : "记忆已弃用。"); await loadWorkspace(); await openMemoryDetail(record.relativePath);
}

async function deleteEntry(record) {
  if (!window.confirm(`确认删除 ${record.name}？`)) return;
  await fetchJson("/api/memory/memory/actions", { method: "POST", headers: { "Content-Type": "application/json" }, body: { action: "delete_entries", ids: [record.relativePath] } });
  setStatus("记忆已删除。"); await loadWorkspace(); detailViewEl.classList.add("hidden"); detailEmptyEl.classList.remove("hidden");
}

function buildEntryCard(record) {
  const card = el("div", "entry-card");
  card.dataset.kind = record.deprecated ? "deprecated" : record.type;
  const head = el("div", "entry-head");
  head.append(el("h4", "", record.name));
  const badge = el("span", "entry-badge", record.deprecated ? "已弃用" : record.type === "feedback" ? "反馈" : "项目");
  badge.dataset.kind = record.deprecated ? "deprecated" : record.type;
  head.append(badge);
  card.append(head);
  card.append(el("div", "entry-meta", `${formatDateTime(record.updatedAt)} · ${record.relativePath}`));
  card.append(el("div", "", record.description || "暂无描述。"));
  const actions = el("div", "entry-actions");
  [["查看", () => void openMemoryDetail(record.relativePath)], ["编辑", () => void editEntry(record)], [record.deprecated ? "恢复" : "弃用", () => void toggleDeprecation(record)], ["删除", () => void deleteEntry(record), "danger"]].forEach(([label, onClick, variant]) => {
    const btn = el("button", "tool-btn", label);
    if (variant === "danger") btn.classList.add("danger");
    btn.addEventListener("click", onClick);
    actions.append(btn);
  });
  card.append(actions);
  return card;
}

function renderWorkspace() {
  const ws = state.workspace;
  renderProjectContext();
  const pe = ws?.projectEntries || [], fe = ws?.feedbackEntries || [];
  const de = [...(ws?.deprecatedProjectEntries || []), ...(ws?.deprecatedFeedbackEntries || [])];
  clearNode(projectEntriesEl);
  if (!pe.length) renderEmpty(projectEntriesEl, "当前没有项目记忆。");
  else pe.forEach((r) => projectEntriesEl.append(buildEntryCard(r)));
  feedbackEntriesSectionEl.classList.toggle("hidden", !fe.length && !state.workspaceQuery);
  clearNode(feedbackEntriesEl);
  if (!fe.length) renderEmpty(feedbackEntriesEl, "当前没有协作反馈。");
  else fe.forEach((r) => feedbackEntriesEl.append(buildEntryCard(r)));
  deprecatedEntriesSectionEl.classList.toggle("hidden", !de.length);
  clearNode(deprecatedEntriesEl);
  if (!de.length) renderEmpty(deprecatedEntriesEl, "当前没有已弃用记忆。");
  else de.forEach((r) => deprecatedEntriesEl.append(buildEntryCard(r)));
  updateCounts(); applyPageChrome();
}

/* ══════════════════════════════════════════
   TIMELINE RENDERING (shared by all trace types)
   ══════════════════════════════════════════ */

function buildTimelineStep(stepNum, step) {
  const wrapper = el("div", "tl-step");
  const dot = el("div", "tl-dot", String(stepNum));
  dot.dataset.status = step.status || "info";
  wrapper.append(dot);

  const card = el("div", "tl-card");

  const head = el("div", "tl-head");
  head.append(el("span", "tl-title", step.title || `步骤 ${stepNum}`));
  if (step.kind) head.append(el("span", "tl-badge", step.kind.toUpperCase()));
  head.append(el("span", "tl-expand-icon", "▼"));
  card.append(head);

  if (step.outputSummary || step.inputSummary) {
    card.append(el("div", "tl-summary", step.outputSummary || step.inputSummary || ""));
  }

  const body = el("div", "tl-body");

  const metaRow = el("div", "tl-meta-row");
  const statusCell = el("div", "tl-meta-cell");
  statusCell.append(el("div", "tl-meta-label", "状态"));
  statusCell.append(el("div", "tl-meta-value", step.status || "—"));
  metaRow.append(statusCell);
  const kindCell = el("div", "tl-meta-cell");
  kindCell.append(el("div", "tl-meta-label", "步骤类型"));
  kindCell.append(el("div", "tl-meta-value", step.kind || "—"));
  metaRow.append(kindCell);
  body.append(metaRow);

  if (step.metrics && Object.keys(step.metrics).length) {
    body.append(el("div", "tl-section-title", "指标"));
    const table = el("table", "tl-kv-table");
    for (const [k, v] of Object.entries(step.metrics)) {
      const tr = el("tr", "");
      tr.append(el("td", "", k));
      tr.append(el("td", "", String(v)));
      table.append(tr);
    }
    body.append(table);
  }

  if (step.refs && Object.keys(step.refs).length) {
    body.append(el("div", "tl-section-title", "引用"));
    const table = el("table", "tl-kv-table");
    for (const [k, v] of Object.entries(step.refs)) {
      const tr = el("tr", "");
      tr.append(el("td", "", k));
      tr.append(el("td", "", Array.isArray(v) ? v.join(", ") : String(v)));
      table.append(tr);
    }
    body.append(table);
  }

  if (step.inputSummary) {
    body.append(el("div", "tl-section-title", "输入摘要"));
    body.append(el("pre", "tl-code", step.inputSummary));
  }

  if (step.outputSummary) {
    body.append(el("div", "tl-section-title", "输出摘要"));
    body.append(el("pre", "tl-code", step.outputSummary));
  }

  if (step.details && Array.isArray(step.details) && step.details.length) {
    body.append(el("div", "tl-section-title", "详细信息"));
    step.details.forEach((d) => {
      if (d.label) body.append(el("div", "tl-section-title", d.label));
      if (d.kind === "text" || d.kind === "note") {
        body.append(el("pre", "tl-code", d.text || ""));
      } else if (d.kind === "list" && d.items) {
        const ul = el("ul", "");
        d.items.forEach((item) => ul.append(el("li", "", item)));
        body.append(ul);
      } else if (d.kind === "kv" && d.entries) {
        const table = el("table", "tl-kv-table");
        d.entries.forEach((entry) => {
          const tr = el("tr", "");
          tr.append(el("td", "", entry.key || ""));
          tr.append(el("td", "", typeof entry.value === "string" ? entry.value : JSON.stringify(entry.value)));
          table.append(tr);
        });
        body.append(table);
      } else if (d.kind === "json") {
        body.append(el("pre", "tl-code", JSON.stringify(d.json, null, 2)));
      }
    });
  } else if (step.details && !Array.isArray(step.details)) {
    body.append(el("div", "tl-section-title", "详细信息"));
    body.append(el("pre", "tl-code", typeof step.details === "string" ? step.details : JSON.stringify(step.details, null, 2)));
  }

  if (step.promptDebug) {
    body.append(el("div", "tl-section-title", `Prompt Debug — ${step.promptDebug.requestLabel || ""}`));
    if (step.promptDebug.systemPrompt) {
      body.append(el("div", "tl-section-title", "System Prompt"));
      body.append(el("pre", "tl-code", step.promptDebug.systemPrompt));
    }
    if (step.promptDebug.userPrompt) {
      body.append(el("div", "tl-section-title", "User Prompt"));
      body.append(el("pre", "tl-code", step.promptDebug.userPrompt));
    }
    if (step.promptDebug.rawResponse) {
      body.append(el("div", "tl-section-title", "Raw Response"));
      body.append(el("pre", "tl-code", step.promptDebug.rawResponse));
    }
    if (step.promptDebug.parsedResult !== undefined) {
      body.append(el("div", "tl-section-title", "Parsed Result"));
      body.append(el("pre", "tl-code", JSON.stringify(step.promptDebug.parsedResult, null, 2)));
    }
  }

  card.append(body);

  head.addEventListener("click", () => wrapper.classList.toggle("is-open"));

  wrapper.append(card);
  return wrapper;
}

function renderTimeline(containerEl, steps) {
  clearNode(containerEl);
  if (!steps || !steps.length) {
    containerEl.append(el("div", "empty-state", "暂无步骤。"));
    return;
  }
  steps.forEach((step, i) => containerEl.append(buildTimelineStep(i + 1, step)));
}

/* ── Recall (Case Traces) ── */

function renderRecallCaseList() {
  clearNode(recallCaseSelectEl);
  const def = el("option", "", "选择一个 Recall 事例…"); def.value = ""; recallCaseSelectEl.append(def);
  state.caseTraces.forEach((c) => {
    const opt = el("option", "", `${c.query} — ${c.sessionKey} · ${formatDateTime(c.startedAt)}`);
    opt.value = c.caseId; recallCaseSelectEl.append(opt);
  });
  recallDetailEl.classList.add("hidden"); recallEmptyEl.classList.remove("hidden");
}

function buildKvCell(label, value) {
  const cell = el("div", "kv-cell");
  cell.append(el("div", "kv-label", label));
  cell.append(el("div", "kv-value", value));
  return cell;
}

async function loadRecallDetail(caseId) {
  if (!caseId) { recallDetailEl.classList.add("hidden"); recallEmptyEl.classList.remove("hidden"); return; }
  try {
    const r = await fetchJson(`/api/memory/cases/${encodeURIComponent(caseId)}`);
    recallEmptyEl.classList.add("hidden"); recallDetailEl.classList.remove("hidden");

    clearNode(recallMetaTableEl);
    recallMetaTableEl.append(buildKvCell("问题", r.query || "—"));
    recallMetaTableEl.append(buildKvCell("会话", r.sessionKey || "—"));
    recallMetaTableEl.append(buildKvCell("模式", r.retrieval?.intent || "auto"));
    recallMetaTableEl.append(buildKvCell("召回理由", r.retrieval?.intent || "none"));
    recallMetaTableEl.append(buildKvCell("状态", r.status || "—"));
    recallMetaTableEl.append(buildKvCell("注入", r.retrieval?.injected ? "是" : "否"));
    recallMetaTableEl.append(buildKvCell("开始", formatDateTime(r.startedAt)));
    recallMetaTableEl.append(buildKvCell("结束", formatDateTime(r.finishedAt)));

    recallContextEl.textContent = r.retrieval?.contextPreview || "无";

    clearNode(recallToolEventsEl);
    if (r.toolEvents?.length) {
      r.toolEvents.forEach((evt) => {
        const block = el("div", "");
        block.append(el("strong", "", evt.summary || evt.toolName || "tool"));
        if (evt.paramsPreview) block.append(el("pre", "tl-code", evt.paramsPreview));
        if (evt.resultPreview) block.append(el("pre", "tl-code", evt.resultPreview));
        recallToolEventsEl.append(block);
      });
    } else {
      recallToolEventsEl.textContent = "无";
    }

    recallReplyEl.textContent = r.assistantReply || "暂无回复。";

    const steps = r.retrieval?.trace?.steps || [];
    renderTimeline(recallStepsEl, steps);
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Index / Dream Trace Rendering ── */

function renderIndexTraceSelect() {
  clearNode(indexTraceSelectEl);
  const def = el("option", "", "选择一条 Index 追踪…"); def.value = ""; indexTraceSelectEl.append(def);
  state.indexTraces.forEach((t) => {
    const opt = el("option", "", `${t.indexTraceId} · ${t.status} · ${formatDateTime(t.startedAt)}`);
    opt.value = t.indexTraceId; indexTraceSelectEl.append(opt);
  });
  indexDetailEl.classList.add("hidden"); indexEmptyEl.classList.remove("hidden");
}

function renderDreamTraceSelect() {
  clearNode(dreamTraceSelectEl);
  const def = el("option", "", "选择一条 Dream 追踪…"); def.value = ""; dreamTraceSelectEl.append(def);
  state.dreamTraces.forEach((t) => {
    const opt = el("option", "", `${t.dreamTraceId} · ${t.status} · ${formatDateTime(t.startedAt)}`);
    opt.value = t.dreamTraceId; dreamTraceSelectEl.append(opt);
  });
  dreamDetailEl.classList.add("hidden"); dreamEmptyEl.classList.remove("hidden");
}

async function loadIndexDetail(traceId) {
  if (!traceId) { indexDetailEl.classList.add("hidden"); indexEmptyEl.classList.remove("hidden"); return; }
  try {
    const r = await fetchJson(`/api/memory/index-traces/${encodeURIComponent(traceId)}`);
    indexEmptyEl.classList.add("hidden"); indexDetailEl.classList.remove("hidden");
    renderTimeline(indexStepsEl, r.steps || []);
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

async function loadDreamDetail(traceId) {
  if (!traceId) { dreamDetailEl.classList.add("hidden"); dreamEmptyEl.classList.remove("hidden"); return; }
  try {
    const r = await fetchJson(`/api/memory/dream-traces/${encodeURIComponent(traceId)}`);
    dreamEmptyEl.classList.add("hidden"); dreamDetailEl.classList.remove("hidden");
    renderTimeline(dreamStepsEl, r.steps || []);
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Data Loading ── */

async function loadOverview() { state.overview = await fetchJson("/api/memory/overview"); updateCounts(); applyPageChrome(); }
async function loadSettings() { state.settings = await fetchJson("/api/memory/settings"); }
async function loadWorkspace() { const q = state.workspaceQuery ? `&q=${encodeURIComponent(state.workspaceQuery)}` : ""; state.workspace = await fetchJson(`/api/memory/workspace?limit=200${q}`); renderWorkspace(); }
async function loadUserSummary() { state.userSummary = await fetchJson("/api/memory/memory/user-summary"); renderUserSummary(); }
async function loadCaseTraces() { const c = await fetchJson("/api/memory/cases?limit=12"); state.caseTraces = Array.isArray(c) ? c : []; renderRecallCaseList(); updateCounts(); }
async function loadTraces() {
  const [it, dt] = await Promise.all([fetchJson("/api/memory/index-traces?limit=10"), fetchJson("/api/memory/dream-traces?limit=10")]);
  state.indexTraces = Array.isArray(it) ? it : []; state.dreamTraces = Array.isArray(dt) ? dt : [];
  renderIndexTraceSelect();
  renderDreamTraceSelect();
  updateCounts();
}

async function loadDashboard() {
  if (!state.projectPath) { setStatus("缺少 projectPath，无法加载当前项目的 Memory Dashboard。", "error"); return; }
  setStatus("正在刷新当前视图…");
  try { await Promise.all([loadOverview(), loadSettings(), loadWorkspace(), loadUserSummary(), loadCaseTraces(), loadTraces()]); setStatus(DEFAULT_ACTIVITY); }
  catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Actions ── */

async function runAction(label, path) {
  closeSettingsDrawer(); setStatus(`${label} 执行中…`);
  try { const r = await fetchJson(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: {} }); setStatus(`${label} 完成`); await loadDashboard(); return r; }
  catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); throw err; }
}

async function exportMemory() {
  try { const blob = await fetchBlob("/api/memory/export"); const href = URL.createObjectURL(blob); const link = document.createElement("a"); link.href = href; link.download = `edgeclaw-memory-${Date.now()}.json`; link.click(); URL.revokeObjectURL(href); setStatus("记忆已导出。"); }
  catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

async function clearMemory() { if (!window.confirm("确认清空当前 workspace 的全部记忆吗？")) return; await runAction("清空", "/api/memory/clear"); }

async function editProjectMeta() {
  const c = state.workspace?.projectMeta || {};
  const projectName = window.prompt("更新项目名称", c.projectName || basename(state.projectPath)); if (projectName === null) return;
  const description = window.prompt("更新项目描述", c.description || ""); if (description === null) return;
  const aliasesRaw = window.prompt("更新项目别名，使用英文逗号分隔", Array.isArray(c.aliases) ? c.aliases.join(", ") : ""); if (aliasesRaw === null) return;
  const status = window.prompt("更新项目状态", c.status || "in_progress"); if (status === null) return;
  try {
    await fetchJson("/api/memory/project-meta", { method: "POST", headers: { "Content-Type": "application/json" }, body: { projectName, description, aliases: aliasesRaw.split(",").map((i) => i.trim()).filter(Boolean), status } });
    setStatus("项目元信息已更新。"); await loadDashboard();
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

async function saveSettings() {
  const indexH = Number.parseInt(settingAutoIndexEl.value, 10);
  const dreamH = Number.parseInt(settingAutoDreamEl.value, 10);
  try {
    await fetchJson("/api/memory/settings", { method: "POST", headers: { "Content-Type": "application/json" }, body: { autoIndexIntervalMinutes: (Number.isFinite(indexH) ? indexH : 1) * 60, autoDreamIntervalMinutes: (Number.isFinite(dreamH) ? dreamH : 6) * 60 } });
    setStatus("设置已保存。"); await loadSettings();
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Event Bindings ── */

boardNavTabs.forEach((b) => b.addEventListener("click", () => { closeSettingsDrawer(); setActivePage(b.dataset.page || "project"); }));
traceSubTabs.forEach((b) => b.addEventListener("click", () => setActiveTraceTab(b.dataset.trace || "recall")));
recallCaseSelectEl.addEventListener("change", () => void loadRecallDetail(recallCaseSelectEl.value));
indexTraceSelectEl.addEventListener("change", () => void loadIndexDetail(indexTraceSelectEl.value));
dreamTraceSelectEl.addEventListener("change", () => void loadDreamDetail(dreamTraceSelectEl.value));
settingsToggleBtn.addEventListener("click", () => { if (state.settingsOpen) closeSettingsDrawer(); else openSettingsDrawer(); });
settingsCloseBtn.addEventListener("click", () => closeSettingsDrawer());
saveSettingsBtn.addEventListener("click", () => void saveSettings());
refreshBtn.addEventListener("click", () => void loadDashboard());
indexBtn.addEventListener("click", () => void runAction("索引同步", "/api/memory/index/run"));
dreamBtn.addEventListener("click", () => void runAction("记忆 Dream", "/api/memory/dream/run"));
exportBtn.addEventListener("click", () => void exportMemory());
importBtn.addEventListener("click", () => importInput.click());
clearBtn.addEventListener("click", () => void clearMemory());

workspaceSearchEl.addEventListener("input", () => { state.workspaceQuery = workspaceSearchEl.value.trim(); if (state.activePage === "project") void loadWorkspace(); });
workspaceSearchEl.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); state.workspaceQuery = workspaceSearchEl.value.trim(); void loadWorkspace(); } });
workspaceSearchBtn.addEventListener("click", () => { state.workspaceQuery = workspaceSearchEl.value.trim(); void loadWorkspace(); });

importInput.addEventListener("change", async (e) => {
  const file = e.target.files?.[0]; if (!file) return;
  try { const text = await file.text(); const payload = JSON.parse(text); await fetchJson("/api/memory/import", { method: "POST", headers: { "Content-Type": "application/json" }, body: payload }); setStatus("记忆已导入。"); await loadDashboard(); }
  catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
  finally { importInput.value = ""; }
});

detailCloseBtn.addEventListener("click", () => closeDetailDrawer());
appScrimEl.addEventListener("click", () => { closeSettingsDrawer(); closeDetailDrawer(); });

/* ── Init ── */

renderUserSummary();
renderRecallCaseList();
renderIndexTraceSelect();
renderDreamTraceSelect();
setActivePage("project");
applyTraceTabChrome();
void loadDashboard();
