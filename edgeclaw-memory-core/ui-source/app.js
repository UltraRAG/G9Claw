const params = new URLSearchParams(window.location.search);

const state = {
  token: params.get("token") || "",
  projectPath: params.get("projectPath") || "",
  workspaceQuery: "",
  activePage: "project",
  overview: null,
  settings: null,
  workspace: null,
  userSummary: null,
  indexTraces: [],
  dreamTraces: [],
  detailOpen: false,
  settingsOpen: false,
};

const DEFAULT_ACTIVITY = "已就绪";

const appScrimEl = document.getElementById("appScrim");
const activityTextEl = document.getElementById("activityText");
const statusBarEl = document.getElementById("statusBar");
const browserTitleEl = document.getElementById("browserTitle");
const browserMetaEl = document.getElementById("browserMeta");
const navLastIndexedEl = document.getElementById("navLastIndexed");
const navProjectCountEl = document.getElementById("navProjectCount");
const navUserCountEl = document.getElementById("navUserCount");
const navTraceCountEl = document.getElementById("navTraceCount");
const boardNavTabs = Array.from(document.querySelectorAll(".nav-item[data-page]"));
const settingsToggleBtn = document.getElementById("settingsToggleBtn");
const settingsPopoverEl = document.getElementById("settingsPopover");
const refreshBtn = document.getElementById("refreshBtn");
const indexBtn = document.getElementById("indexBtn");
const dreamBtn = document.getElementById("dreamBtn");
const exportBtn = document.getElementById("exportBtn");
const importBtn = document.getElementById("importBtn");
const importInput = document.getElementById("importInput");
const clearBtn = document.getElementById("clearBtn");
const editProjectMetaBtn = document.getElementById("editProjectMetaBtn");
const editSettingsBtn = document.getElementById("editSettingsBtn");
const workspaceSearchEl = document.getElementById("workspaceSearch");
const workspaceSearchBtn = document.getElementById("workspaceSearchBtn");
const listSearchRowEl = document.getElementById("listSearchRow");
const projectBoardEl = document.getElementById("projectBoard");
const userBoardEl = document.getElementById("userBoard");
const traceBoardEl = document.getElementById("traceBoard");
const projectContextSectionEl = document.getElementById("projectContextSection");
const projectEntriesSectionEl = document.getElementById("projectEntriesSection");
const projectEntriesEl = document.getElementById("projectEntries");
const projectEntriesCountEl = document.getElementById("projectEntriesCount");
const feedbackEntriesSectionEl = document.getElementById("feedbackEntriesSection");
const feedbackEntriesEl = document.getElementById("feedbackEntries");
const feedbackEntriesCountEl = document.getElementById("feedbackEntriesCount");
const deprecatedEntriesSectionEl = document.getElementById("deprecatedEntriesSection");
const deprecatedEntriesEl = document.getElementById("deprecatedEntries");
const deprecatedEntriesCountEl = document.getElementById("deprecatedEntriesCount");
const projectMetaEl = document.getElementById("projectMeta");
const drawerProjectMetaEl = document.getElementById("drawerProjectMeta");
const userSummaryEl = document.getElementById("userSummary");
const userSummaryCountEl = document.getElementById("userSummaryCount");
const settingsSummaryEl = document.getElementById("settingsSummary");
const manifestSectionEl = document.getElementById("manifestSection");
const manifestContentEl = document.getElementById("manifestContent");
const indexTraceListEl = document.getElementById("indexTraceList");
const indexTraceCountEl = document.getElementById("indexTraceCount");
const dreamTraceListEl = document.getElementById("dreamTraceList");
const dreamTraceCountEl = document.getElementById("dreamTraceCount");
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

function setActivity(message = DEFAULT_ACTIVITY) {
  activityTextEl.textContent = message || DEFAULT_ACTIVITY;
}

function updateAppScrim() {
  const open = state.detailOpen || state.settingsOpen;
  appScrimEl.classList.toggle("is-open", open);
  appScrimEl.classList.toggle("hidden", !open);
}

function setStatus(message, kind = "info") {
  if (!message) {
    statusBarEl.classList.add("hidden");
    statusBarEl.textContent = "";
    setActivity(DEFAULT_ACTIVITY);
    return;
  }

  if (kind === "error") {
    statusBarEl.classList.remove("hidden");
    statusBarEl.textContent = message;
    statusBarEl.dataset.kind = kind;
    setActivity("发生错误");
    return;
  }

  statusBarEl.classList.add("hidden");
  statusBarEl.textContent = "";
  delete statusBarEl.dataset.kind;
  setActivity(message);
}

function headers(extra = {}) {
  return state.token
    ? { Authorization: `Bearer ${state.token}`, ...extra }
    : { ...extra };
}

function withProjectPath(url) {
  const next = new URL(url, window.location.origin);
  if (state.projectPath) next.searchParams.set("projectPath", state.projectPath);
  return `${next.pathname}${next.search}`;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(withProjectPath(url), {
    method: options.method || "GET",
    headers: headers(options.headers),
    ...(options.body ? { body: JSON.stringify({ ...options.body, projectPath: state.projectPath }) } : {}),
  });

  const raw = await response.text();
  let data = null;
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = null;
    }
  }

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new Error("需要登录后才能访问当前项目的 Memory Dashboard。");
    }
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }

  return data;
}

async function fetchBlob(url) {
  const response = await fetch(withProjectPath(url), { headers: headers() });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new Error("需要登录后才能访问当前项目的 Memory Dashboard。");
    }
    throw new Error(await response.text());
  }
  return response.blob();
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (typeof text === "string") node.textContent = text;
  return node;
}

function clearNode(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function renderEmpty(target, text) {
  clearNode(target);
  target.append(el("div", "empty-state", text));
}

function formatDateTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function stringifyDetail(value) {
  return typeof value === "string" ? value : JSON.stringify(value, null, 2);
}

function basename(value) {
  const normalized = String(value || "").replace(/[\\/]+$/, "");
  const segments = normalized.split(/[\\/]/).filter(Boolean);
  return segments[segments.length - 1] || normalized || "Current Project";
}

function countUserSummaryRecords(summary) {
  if (!summary) return 0;
  return summary.profile || summary.preferences?.length || summary.constraints?.length || summary.relationships?.length ? 1 : 0;
}

function getProjectCardCount() {
  return state.workspace?.projectEntries?.length || 0;
}

function getActivePageCount(page = state.activePage) {
  if (page === "project") return getProjectCardCount();
  if (page === "user") return countUserSummaryRecords(state.userSummary);
  return state.indexTraces.length + state.dreamTraces.length;
}

function updateCounts() {
  navProjectCountEl.textContent = String(getProjectCardCount());
  navUserCountEl.textContent = String(countUserSummaryRecords(state.userSummary));
  navTraceCountEl.textContent = String(state.indexTraces.length + state.dreamTraces.length);
  projectEntriesCountEl.textContent = String(state.workspace?.projectEntries?.length || 0);
  feedbackEntriesCountEl.textContent = String(state.workspace?.feedbackEntries?.length || 0);
  deprecatedEntriesCountEl.textContent = String(
    (state.workspace?.deprecatedProjectEntries?.length || 0) +
      (state.workspace?.deprecatedFeedbackEntries?.length || 0),
  );
  userSummaryCountEl.textContent = String(countUserSummaryRecords(state.userSummary));
  indexTraceCountEl.textContent = String(state.indexTraces.length);
  dreamTraceCountEl.textContent = String(state.dreamTraces.length);
  navLastIndexedEl.textContent =
    formatDateTime(state.overview?.lastIndexedAt || "") === "—"
      ? "等待索引"
      : formatDateTime(state.overview?.lastIndexedAt || "");
  browserMetaEl.textContent = String(getActivePageCount());
}

function applyPageChrome() {
  browserTitleEl.textContent = PAGE_CONFIG[state.activePage].title;
  browserMetaEl.textContent = String(getActivePageCount());
  listSearchRowEl.classList.toggle("hidden", state.activePage !== "project");
  projectBoardEl.classList.toggle("board-active", state.activePage === "project");
  userBoardEl.classList.toggle("board-active", state.activePage === "user");
  traceBoardEl.classList.toggle("board-active", state.activePage === "trace");
  boardNavTabs.forEach((button) => {
    button.classList.toggle("active", button.dataset.page === state.activePage);
  });
}

function setActivePage(page) {
  if (!PAGE_CONFIG[page]) return;
  state.activePage = page;
  applyPageChrome();
}

function closeSettingsPopover() {
  state.settingsOpen = false;
  settingsPopoverEl.classList.add("hidden");
  updateAppScrim();
}

function toggleSettingsPopover() {
  state.settingsOpen = !state.settingsOpen;
  settingsPopoverEl.classList.toggle("hidden", !state.settingsOpen);
  updateAppScrim();
}

function openDetailDrawer() {
  state.detailOpen = true;
  detailDrawerEl.classList.remove("hidden");
  updateAppScrim();
}

function closeDetailDrawer() {
  state.detailOpen = false;
  detailDrawerEl.classList.add("hidden");
  updateAppScrim();
}

function showDetail({ meta = "", title = "", description = "", content = "", actions = [] }) {
  detailMetaEl.textContent = meta;
  detailTitleEl.textContent = title;
  detailDescriptionEl.textContent = description;
  detailContentEl.textContent = content;
  clearNode(detailActionsEl);
  actions.forEach((action) => {
    const button = el("button", "tool-btn", action.label);
    if (action.variant === "danger") button.classList.add("danger");
    button.addEventListener("click", action.onClick);
    detailActionsEl.append(button);
  });
  detailEmptyEl.classList.add("hidden");
  detailViewEl.classList.remove("hidden");
  openDetailDrawer();
}

function renderProjectMetaBlock(target) {
  clearNode(target);
  const projectMeta = state.workspace?.projectMeta;
  if (!projectMeta) {
    target.append(el("div", "empty-state", "当前 project 还没有元信息。"));
    return;
  }

  const card = el("div", "entry-card");
  card.dataset.kind = "project";

  const head = el("div", "entry-head");
  head.append(el("h4", "", projectMeta.projectName || basename(state.projectPath)));
  const badge = el("span", "meta-badge", projectMeta.status || "in_progress");
  head.append(badge);
  card.append(head);

  card.append(el("div", "entry-meta", formatDateTime(projectMeta.updatedAt)));
  card.append(el("div", "", projectMeta.description || "暂无项目描述。"));

  if (Array.isArray(projectMeta.aliases) && projectMeta.aliases.length) {
    card.append(el("div", "entry-meta", `别名：${projectMeta.aliases.join(" / ")}`));
  }

  target.append(card);
}

function renderProjectContext() {
  clearNode(projectContextSectionEl);

  const wrapper = el("div", "project-context-head");
  const copy = el("div", "project-context-copy");
  const projectMeta = state.workspace?.projectMeta;
  const projectName = projectMeta?.projectName || basename(state.projectPath);
  copy.append(el("h4", "", projectName));
  copy.append(el("p", "", projectMeta?.description || "当前打开的 workspace 就是唯一顶层 project。这里汇总它的项目进展记忆和协作反馈。"));
  wrapper.append(copy);
  projectContextSectionEl.append(wrapper);

  const meta = el("div", "project-context-meta");
  const chips = [
    [`状态 ${projectMeta?.status || "in_progress"}`],
    [`项目记忆 ${state.workspace?.projectEntries?.length || 0}`],
    [`协作反馈 ${state.workspace?.feedbackEntries?.length || 0}`],
    [`项目路径 ${basename(state.projectPath)}`],
  ];
  chips.forEach(([text]) => meta.append(el("span", "context-chip", text)));
  projectContextSectionEl.append(meta);
}

function renderUserSummary() {
  clearNode(userSummaryEl);
  const summary = state.userSummary;
  if (!summary || (!summary.profile && !summary.preferences?.length && !summary.constraints?.length && !summary.relationships?.length)) {
    userSummaryEl.append(el("div", "empty-state", "当前没有用户画像。"));
    updateCounts();
    applyPageChrome();
    return;
  }

  if (summary.profile) {
    const card = el("div", "entry-card");
    card.dataset.kind = "feedback";
    card.append(el("h4", "", "Profile"));
    card.append(el("div", "", summary.profile));
    userSummaryEl.append(card);
  }

  [
    ["Preferences", summary.preferences || []],
    ["Constraints", summary.constraints || []],
    ["Relationships", summary.relationships || []],
  ].forEach(([title, items]) => {
    if (!items.length) return;
    const card = el("div", "entry-card");
    card.dataset.kind = "feedback";
    card.append(el("h4", "", title));
    const list = el("ul", "");
    items.forEach((item) => list.append(el("li", "", item)));
    card.append(list);
    userSummaryEl.append(card);
  });

  updateCounts();
  applyPageChrome();
}

function renderSettings() {
  clearNode(settingsSummaryEl);
  const settings = state.settings;
  if (!settings) {
    settingsSummaryEl.append(el("div", "empty-state", "当前没有可用设置。"));
    updateCounts();
    applyPageChrome();
    return;
  }

  const card = el("div", "entry-card");
  card.dataset.kind = "feedback";
  card.append(el("h4", "", "Index / Dream"));
  const list = el("ul", "");
  list.append(el("li", "", `reasoningMode: ${settings.reasoningMode || "answer_first"}`));
  list.append(el("li", "", `autoIndexIntervalMinutes: ${settings.autoIndexIntervalMinutes ?? 60}`));
  list.append(el("li", "", `autoDreamIntervalMinutes: ${settings.autoDreamIntervalMinutes ?? 360}`));
  card.append(list);
  settingsSummaryEl.append(card);

  const actions = el("div", "detail-actions");
  [
    ["编辑设置", () => void editSettings()],
    ["导出记忆", () => void exportMemory()],
    ["导入记忆", () => importInput.click()],
    ["清空记忆", () => void clearMemory()],
  ].forEach(([label, onClick]) => {
    const button = el("button", "tool-btn", label);
    button.addEventListener("click", onClick);
    actions.append(button);
  });
  settingsSummaryEl.append(actions);

  updateCounts();
  applyPageChrome();
}

async function openMemoryDetail(id) {
  const records = await fetchJson(`/api/memory/memory/get?ids=${encodeURIComponent(id)}`);
  const record = Array.isArray(records) ? records[0] : null;
  if (!record) {
    setStatus("未找到该记忆文件。", "error");
    return;
  }

  showDetail({
    meta: `${record.type} · ${formatDateTime(record.updatedAt)}`,
    title: record.name,
    description: record.description,
    content: record.content,
    actions: [
      { label: "编辑", onClick: () => void editEntry(record) },
      { label: record.deprecated ? "恢复" : "弃用", onClick: () => void toggleDeprecation(record) },
      { label: "删除", variant: "danger", onClick: () => void deleteEntry(record) },
    ],
  });
}

async function editEntry(record) {
  const name = window.prompt("更新记忆名称", record.name);
  if (name === null) return;
  const description = window.prompt("更新记忆描述", record.description);
  if (description === null) return;

  await fetchJson("/api/memory/memory/actions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: { action: "edit_entry", id: record.relativePath, name, description },
  });

  setStatus("记忆已更新。");
  await loadWorkspace();
  await openMemoryDetail(record.relativePath);
}

async function toggleDeprecation(record) {
  await fetchJson("/api/memory/memory/actions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: {
      action: record.deprecated ? "restore_entries" : "deprecate_entries",
      ids: [record.relativePath],
    },
  });
  setStatus(record.deprecated ? "记忆已恢复。" : "记忆已弃用。");
  await loadWorkspace();
  await openMemoryDetail(record.relativePath);
}

async function deleteEntry(record) {
  if (!window.confirm(`确认删除 ${record.name}？`)) return;
  await fetchJson("/api/memory/memory/actions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: { action: "delete_entries", ids: [record.relativePath] },
  });
  setStatus("记忆已删除。");
  await loadWorkspace();
  detailViewEl.classList.add("hidden");
  detailEmptyEl.classList.remove("hidden");
}

function buildEntryCard(record) {
  const card = el("div", "entry-card");
  card.dataset.kind = record.deprecated ? "deprecated" : record.type;

  const head = el("div", "entry-head");
  head.append(el("h4", "", record.name));
  const badge = el(
    "span",
    "entry-badge",
    record.deprecated ? "已弃用" : record.type === "feedback" ? "反馈" : "项目",
  );
  badge.dataset.kind = record.deprecated ? "deprecated" : record.type;
  head.append(badge);
  card.append(head);

  card.append(el("div", "entry-meta", `${formatDateTime(record.updatedAt)} · ${record.relativePath}`));
  card.append(el("div", "", record.description || "暂无描述。"));

  const actions = el("div", "entry-actions");
  [
    ["查看", () => void openMemoryDetail(record.relativePath)],
    ["编辑", () => void editEntry(record)],
    [record.deprecated ? "恢复" : "弃用", () => void toggleDeprecation(record)],
    ["删除", () => void deleteEntry(record), "danger"],
  ].forEach(([label, onClick, variant]) => {
    const button = el("button", "tool-btn", label);
    if (variant === "danger") button.classList.add("danger");
    button.addEventListener("click", onClick);
    actions.append(button);
  });
  card.append(actions);
  return card;
}

function renderWorkspace() {
  const workspace = state.workspace;
  renderProjectContext();

  const projectEntries = workspace?.projectEntries || [];
  const feedbackEntries = workspace?.feedbackEntries || [];
  const deprecatedEntries = [
    ...(workspace?.deprecatedProjectEntries || []),
    ...(workspace?.deprecatedFeedbackEntries || []),
  ];

  clearNode(projectEntriesEl);
  if (!projectEntries.length) renderEmpty(projectEntriesEl, "当前没有项目记忆。");
  else projectEntries.forEach((record) => projectEntriesEl.append(buildEntryCard(record)));

  feedbackEntriesSectionEl.classList.toggle("hidden", !feedbackEntries.length && !state.workspaceQuery);
  clearNode(feedbackEntriesEl);
  if (!feedbackEntries.length) renderEmpty(feedbackEntriesEl, "当前没有协作反馈。");
  else feedbackEntries.forEach((record) => feedbackEntriesEl.append(buildEntryCard(record)));

  deprecatedEntriesSectionEl.classList.toggle("hidden", !deprecatedEntries.length);
  clearNode(deprecatedEntriesEl);
  if (!deprecatedEntries.length) renderEmpty(deprecatedEntriesEl, "当前没有已弃用记忆。");
  else deprecatedEntries.forEach((record) => deprecatedEntriesEl.append(buildEntryCard(record)));

  renderProjectMetaBlock(projectMetaEl);
  renderProjectMetaBlock(drawerProjectMetaEl);

  manifestContentEl.textContent = workspace?.manifestContent || "暂无 manifest。";
  manifestSectionEl.classList.toggle("hidden", !(workspace?.manifestContent || "").trim());

  updateCounts();
  applyPageChrome();
}

async function openTraceDetail(kind, id) {
  const record = await fetchJson(`/api/memory/${kind}/${encodeURIComponent(id)}`);
  showDetail({
    meta: `${kind} · ${formatDateTime(record.startedAt || record.finishedAt || "")}`,
    title: id,
    description: record.outcome?.summary || record.status || "",
    content: stringifyDetail(record),
    actions: [],
  });
}

function buildTraceCard(record, kind) {
  const card = el("div", "trace-card");
  const traceId = kind === "index-traces" ? record.indexTraceId : record.dreamTraceId;

  const head = el("div", "trace-head");
  head.append(el("h4", "", traceId));
  head.append(el("span", "trace-badge", kind === "index-traces" ? "Index" : "Dream"));
  card.append(head);

  card.append(el("div", "trace-meta", `${record.status} · ${formatDateTime(record.startedAt)}`));
  card.append(el("div", "", record.outcome?.summary || (record.steps?.length ? `步骤数：${record.steps.length}` : "暂无摘要。")));

  const actions = el("div", "trace-actions");
  const button = el("button", "tool-btn", "查看");
  button.addEventListener("click", () => void openTraceDetail(kind, traceId));
  actions.append(button);
  card.append(actions);
  return card;
}

function renderTraceLists() {
  clearNode(indexTraceListEl);
  if (!state.indexTraces.length) renderEmpty(indexTraceListEl, "暂无 Index 追踪。");
  else state.indexTraces.forEach((trace) => indexTraceListEl.append(buildTraceCard(trace, "index-traces")));

  clearNode(dreamTraceListEl);
  if (!state.dreamTraces.length) renderEmpty(dreamTraceListEl, "暂无 Dream 追踪。");
  else state.dreamTraces.forEach((trace) => dreamTraceListEl.append(buildTraceCard(trace, "dream-traces")));

  updateCounts();
  applyPageChrome();
}

async function loadOverview() {
  state.overview = await fetchJson("/api/memory/overview");
  updateCounts();
  applyPageChrome();
}

async function loadSettings() {
  state.settings = await fetchJson("/api/memory/settings");
  renderSettings();
}

async function loadWorkspace() {
  const query = state.workspaceQuery ? `&q=${encodeURIComponent(state.workspaceQuery)}` : "";
  state.workspace = await fetchJson(`/api/memory/workspace?limit=200${query}`);
  renderWorkspace();
}

async function loadUserSummary() {
  state.userSummary = await fetchJson("/api/memory/memory/user-summary");
  renderUserSummary();
}

async function loadTraces() {
  const [indexTraces, dreamTraces] = await Promise.all([
    fetchJson("/api/memory/index-traces?limit=10"),
    fetchJson("/api/memory/dream-traces?limit=10"),
  ]);
  state.indexTraces = Array.isArray(indexTraces) ? indexTraces : [];
  state.dreamTraces = Array.isArray(dreamTraces) ? dreamTraces : [];
  renderTraceLists();
}

async function loadDashboard() {
  if (!state.projectPath) {
    setStatus("缺少 projectPath，无法加载当前项目的 Memory Dashboard。", "error");
    return;
  }

  setStatus("正在刷新当前视图…");
  try {
    await Promise.all([loadOverview(), loadSettings(), loadWorkspace(), loadUserSummary(), loadTraces()]);
    setStatus(DEFAULT_ACTIVITY);
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

async function runAction(label, path) {
  closeSettingsPopover();
  setStatus(`${label} 执行中…`);
  try {
    const result = await fetchJson(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: {},
    });
    setStatus(`${label} 完成`);
    await loadDashboard();
    return result;
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
    throw error;
  }
}

async function exportMemory() {
  closeSettingsPopover();
  try {
    const blob = await fetchBlob("/api/memory/export");
    const href = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = href;
    link.download = `edgeclaw-memory-${Date.now()}.json`;
    link.click();
    URL.revokeObjectURL(href);
    setStatus("记忆已导出。");
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

async function clearMemory() {
  closeSettingsPopover();
  if (!window.confirm("确认清空当前 workspace 的全部记忆吗？")) return;
  await runAction("清空", "/api/memory/clear");
}

async function editProjectMeta() {
  closeSettingsPopover();
  const current = state.workspace?.projectMeta || {};
  const projectName = window.prompt("更新项目名称", current.projectName || basename(state.projectPath));
  if (projectName === null) return;
  const description = window.prompt("更新项目描述", current.description || "");
  if (description === null) return;
  const aliasesRaw = window.prompt(
    "更新项目别名，使用英文逗号分隔",
    Array.isArray(current.aliases) ? current.aliases.join(", ") : "",
  );
  if (aliasesRaw === null) return;
  const status = window.prompt("更新项目状态", current.status || "in_progress");
  if (status === null) return;

  try {
    await fetchJson("/api/memory/project-meta", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: {
        projectName,
        description,
        aliases: aliasesRaw.split(",").map((item) => item.trim()).filter(Boolean),
        status,
      },
    });
    setStatus("当前 project 元信息已更新。");
    await loadDashboard();
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

async function editSettings() {
  closeSettingsPopover();
  const current = state.settings || {};
  const reasoningMode = window.prompt(
    "更新 reasoningMode(answer_first / accuracy_first)",
    current.reasoningMode || "answer_first",
  );
  if (reasoningMode === null) return;
  const autoIndexIntervalMinutes = window.prompt(
    "更新 autoIndexIntervalMinutes",
    String(current.autoIndexIntervalMinutes ?? 60),
  );
  if (autoIndexIntervalMinutes === null) return;
  const autoDreamIntervalMinutes = window.prompt(
    "更新 autoDreamIntervalMinutes",
    String(current.autoDreamIntervalMinutes ?? 360),
  );
  if (autoDreamIntervalMinutes === null) return;

  try {
    await fetchJson("/api/memory/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: {
        reasoningMode,
        autoIndexIntervalMinutes: Number.parseInt(autoIndexIntervalMinutes, 10),
        autoDreamIntervalMinutes: Number.parseInt(autoDreamIntervalMinutes, 10),
      },
    });
    setStatus("Memory 设置已更新。");
    await loadDashboard();
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

boardNavTabs.forEach((button) => {
  button.addEventListener("click", () => {
    closeSettingsPopover();
    setActivePage(button.dataset.page || "project");
  });
});

settingsToggleBtn.addEventListener("click", () => toggleSettingsPopover());
refreshBtn.addEventListener("click", () => void loadDashboard());
indexBtn.addEventListener("click", () => void runAction("索引同步", "/api/memory/index/run"));
dreamBtn.addEventListener("click", () => void runAction("记忆 Dream", "/api/memory/dream/run"));
exportBtn.addEventListener("click", () => void exportMemory());
importBtn.addEventListener("click", () => {
  closeSettingsPopover();
  importInput.click();
});
clearBtn.addEventListener("click", () => void clearMemory());
editProjectMetaBtn.addEventListener("click", () => void editProjectMeta());
editSettingsBtn.addEventListener("click", () => void editSettings());

workspaceSearchEl.addEventListener("input", () => {
  state.workspaceQuery = workspaceSearchEl.value.trim();
  if (state.activePage === "project") void loadWorkspace();
});
workspaceSearchEl.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    state.workspaceQuery = workspaceSearchEl.value.trim();
    void loadWorkspace();
  }
});
workspaceSearchBtn.addEventListener("click", () => {
  state.workspaceQuery = workspaceSearchEl.value.trim();
  void loadWorkspace();
});

importInput.addEventListener("change", async (event) => {
  const file = event.target.files?.[0];
  if (!file) return;
  try {
    const text = await file.text();
    const payload = JSON.parse(text);
    await fetchJson("/api/memory/import", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: payload,
    });
    setStatus("记忆已导入。");
    await loadDashboard();
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  } finally {
    importInput.value = "";
  }
});

detailCloseBtn.addEventListener("click", () => closeDetailDrawer());
appScrimEl.addEventListener("click", () => {
  closeSettingsPopover();
  closeDetailDrawer();
});

renderProjectMetaBlock(projectMetaEl);
renderProjectMetaBlock(drawerProjectMetaEl);
renderUserSummary();
renderSettings();
renderTraceLists();
setActivePage("project");
void loadDashboard();
