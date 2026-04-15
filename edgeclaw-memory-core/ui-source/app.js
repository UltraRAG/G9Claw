const params = new URLSearchParams(window.location.search);

const state = {
  token: params.get("token") || "",
  projectPath: params.get("projectPath") || "",
  workspaceQuery: "",
  overview: null,
  settings: null,
  workspace: null,
  userSummary: null,
  indexTraces: [],
  dreamTraces: [],
};

const workspacePathEl = document.getElementById("workspacePath");
const statusBarEl = document.getElementById("statusBar");
const overviewCardsEl = document.getElementById("overviewCards");
const projectMetaEl = document.getElementById("projectMeta");
const settingsSummaryEl = document.getElementById("settingsSummary");
const userSummaryEl = document.getElementById("userSummary");
const workspaceSearchEl = document.getElementById("workspaceSearch");
const manifestContentEl = document.getElementById("manifestContent");
const projectEntriesEl = document.getElementById("projectEntries");
const feedbackEntriesEl = document.getElementById("feedbackEntries");
const deprecatedEntriesEl = document.getElementById("deprecatedEntries");
const indexTraceListEl = document.getElementById("indexTraceList");
const dreamTraceListEl = document.getElementById("dreamTraceList");
const detailEmptyEl = document.getElementById("detailEmpty");
const detailViewEl = document.getElementById("detailView");
const detailMetaEl = document.getElementById("detailMeta");
const detailTitleEl = document.getElementById("detailTitle");
const detailDescriptionEl = document.getElementById("detailDescription");
const detailContentEl = document.getElementById("detailContent");
const detailActionsEl = document.getElementById("detailActions");
const refreshBtn = document.getElementById("refreshBtn");
const indexBtn = document.getElementById("indexBtn");
const dreamBtn = document.getElementById("dreamBtn");
const exportBtn = document.getElementById("exportBtn");
const importBtn = document.getElementById("importBtn");
const importInput = document.getElementById("importInput");
const clearBtn = document.getElementById("clearBtn");
const editProjectMetaBtn = document.getElementById("editProjectMetaBtn");
const editSettingsBtn = document.getElementById("editSettingsBtn");

workspacePathEl.textContent = state.projectPath || "未提供 projectPath";

function setStatus(message, kind = "info") {
  if (!message) {
    statusBarEl.classList.add("hidden");
    statusBarEl.textContent = "";
    return;
  }
  statusBarEl.classList.remove("hidden");
  statusBarEl.textContent = message;
  statusBarEl.dataset.kind = kind;
}

function headers(extra = {}) {
  return {
    Authorization: `Bearer ${state.token}`,
    ...extra,
  };
}

function withProjectPath(url) {
  const next = new URL(url, window.location.origin);
  if (state.projectPath) next.searchParams.set("projectPath", state.projectPath);
  return `${next.pathname}${next.search}`;
}

async function fetchJson(url, options = {}) {
  const requestUrl = withProjectPath(url);
  const response = await fetch(requestUrl, {
    method: options.method || "GET",
    headers: headers(options.headers),
    ...(options.body ? { body: JSON.stringify({ ...options.body, projectPath: state.projectPath }) } : {}),
  });
  const raw = await response.text();
  const data = raw ? JSON.parse(raw) : null;
  if (!response.ok) {
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }
  return data;
}

async function fetchBlob(url) {
  const response = await fetch(withProjectPath(url), {
    headers: headers(),
  });
  if (!response.ok) {
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
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function showDetail({ meta = "", title = "", description = "", content = "", actions = [] }) {
  detailMetaEl.textContent = meta;
  detailTitleEl.textContent = title;
  detailDescriptionEl.textContent = description;
  detailContentEl.textContent = content;
  clearNode(detailActionsEl);
  for (const action of actions) {
    const button = el("button", action.variant === "ghost" ? "ghost" : "inline", action.label);
    if (action.variant === "danger") button.classList.add("danger");
    button.addEventListener("click", action.onClick);
    detailActionsEl.append(button);
  }
  detailEmptyEl.classList.add("hidden");
  detailViewEl.classList.remove("hidden");
}

function buildStatCard(label, value, hint = "") {
  const card = el("div", "stat-card");
  card.append(el("strong", "", String(value)));
  card.append(el("div", "", label));
  if (hint) card.append(el("div", "subtle", hint));
  return card;
}

function renderOverview() {
  clearNode(overviewCardsEl);
  const overview = state.overview || {};
  const workspace = state.workspace || {};
  overviewCardsEl.append(
    buildStatCard("待处理会话", overview.pendingSessions || 0),
    buildStatCard("当前 Project", overview.projectMetaPresent ? "已配置" : "待补充"),
    buildStatCard("项目记忆", workspace.totalProjects || 0),
    buildStatCard("协作反馈", workspace.totalFeedback || 0),
    buildStatCard("用户画像", state.userSummary?.files?.length ? 1 : 0),
    buildStatCard("最近 Index", formatDateTime(overview.lastIndexedAt || "")),
    buildStatCard("最近 Dream", formatDateTime(overview.lastDreamAt || "")),
  );
}

function renderProjectMeta() {
  clearNode(projectMetaEl);
  const projectMeta = state.workspace?.projectMeta;
  if (!projectMeta) {
    projectMetaEl.append(el("div", "empty-state", "当前 project 还没有元信息。"));
    return;
  }
  const card = el("div", "entry-card");
  card.append(el("h4", "", projectMeta.projectName || "Current Project"));
  card.append(el("div", "entry-meta", `${projectMeta.status || "in_progress"} · ${formatDateTime(projectMeta.updatedAt)}`));
  card.append(el("div", "", projectMeta.description || "暂无项目描述。"));
  if (Array.isArray(projectMeta.aliases) && projectMeta.aliases.length) {
    const aliasBlock = el("div", "subtle", `别名：${projectMeta.aliases.join(" / ")}`);
    card.append(aliasBlock);
  }
  projectMetaEl.append(card);
}

function renderUserSummary() {
  clearNode(userSummaryEl);
  const summary = state.userSummary;
  if (!summary || (!summary.profile && !summary.preferences?.length && !summary.constraints?.length && !summary.relationships?.length)) {
    userSummaryEl.append(el("div", "empty-state", "当前没有用户画像。"));
    return;
  }
  if (summary.profile) {
    const block = el("div", "entry-card");
    block.append(el("h4", "", "Profile"));
    block.append(el("div", "", summary.profile));
    userSummaryEl.append(block);
  }
  const sections = [
    ["Preferences", summary.preferences || []],
    ["Constraints", summary.constraints || []],
    ["Relationships", summary.relationships || []],
  ];
  for (const [title, items] of sections) {
    if (!items.length) continue;
    const block = el("div", "entry-card");
    block.append(el("h4", "", title));
    const list = el("ul", "");
    for (const item of items) {
      list.append(el("li", "", item));
    }
    block.append(list);
    userSummaryEl.append(block);
  }
}

function renderSettings() {
  clearNode(settingsSummaryEl);
  const settings = state.settings;
  if (!settings) {
    settingsSummaryEl.append(el("div", "empty-state", "当前没有可用设置。"));
    return;
  }
  const card = el("div", "entry-card");
  card.append(el("h4", "", "Index / Dream"));
  const list = el("ul", "");
  list.append(el("li", "", `reasoningMode: ${settings.reasoningMode || "answer_first"}`));
  list.append(el("li", "", `autoIndexIntervalMinutes: ${settings.autoIndexIntervalMinutes ?? 60}`));
  list.append(el("li", "", `autoDreamIntervalMinutes: ${settings.autoDreamIntervalMinutes ?? 360}`));
  card.append(list);
  settingsSummaryEl.append(card);
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
      {
        label: "编辑",
        onClick: () => void editEntry(record),
      },
      {
        label: record.deprecated ? "恢复" : "弃用",
        onClick: () => void toggleDeprecation(record),
      },
      {
        label: "删除",
        variant: "danger",
        onClick: () => void deleteEntry(record),
      },
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
    body: {
      action: "edit_entry",
      id: record.relativePath,
      name,
      description,
    },
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
    body: {
      action: "delete_entries",
      ids: [record.relativePath],
    },
  });
  setStatus("记忆已删除。");
  await loadWorkspace();
  detailViewEl.classList.add("hidden");
  detailEmptyEl.classList.remove("hidden");
}

function buildEntryCard(record) {
  const card = el("div", "entry-card");
  card.append(el("h4", "", record.name));
  card.append(el("div", "entry-meta", `${record.type} · ${formatDateTime(record.updatedAt)}`));
  card.append(el("div", "", record.description));
  const actions = el("div", "entry-actions");
  const viewButton = el("button", "ghost inline", "查看");
  viewButton.addEventListener("click", () => void openMemoryDetail(record.relativePath));
  actions.append(viewButton);
  const editButton = el("button", "ghost inline", "编辑");
  editButton.addEventListener("click", () => void editEntry(record));
  actions.append(editButton);
  const toggleButton = el("button", "ghost inline", record.deprecated ? "恢复" : "弃用");
  toggleButton.addEventListener("click", () => void toggleDeprecation(record));
  actions.append(toggleButton);
  const deleteButton = el("button", "inline danger", "删除");
  deleteButton.addEventListener("click", () => void deleteEntry(record));
  actions.append(deleteButton);
  card.append(actions);
  return card;
}

function renderWorkspace() {
  const workspace = state.workspace;
  manifestContentEl.textContent = workspace?.manifestContent || "暂无 manifest。";
  const projectEntries = workspace?.projectEntries || [];
  const feedbackEntries = workspace?.feedbackEntries || [];
  const deprecatedEntries = [
    ...(workspace?.deprecatedProjectEntries || []),
    ...(workspace?.deprecatedFeedbackEntries || []),
  ];

  if (!projectEntries.length) renderEmpty(projectEntriesEl, "当前没有项目记忆。");
  else {
    clearNode(projectEntriesEl);
    projectEntries.forEach((record) => projectEntriesEl.append(buildEntryCard(record)));
  }

  if (!feedbackEntries.length) renderEmpty(feedbackEntriesEl, "当前没有协作反馈。");
  else {
    clearNode(feedbackEntriesEl);
    feedbackEntries.forEach((record) => feedbackEntriesEl.append(buildEntryCard(record)));
  }

  if (!deprecatedEntries.length) renderEmpty(deprecatedEntriesEl, "当前没有已弃用记忆。");
  else {
    clearNode(deprecatedEntriesEl);
    deprecatedEntries.forEach((record) => deprecatedEntriesEl.append(buildEntryCard(record)));
  }
  renderProjectMeta();
}

async function openTraceDetail(kind, id) {
  const record = await fetchJson(`/api/memory/${kind}/${encodeURIComponent(id)}`);
  showDetail({
    meta: `${kind} · ${formatDateTime(record.startedAt || record.finishedAt || "")}`,
    title: id,
    description: record.outcome?.summary || record.status || "",
    content: stringifyDetail(record),
  });
}

function buildTraceCard(record, kind) {
  const card = el("div", "trace-card");
  const title = kind === "index-traces" ? record.indexTraceId : record.dreamTraceId;
  card.append(el("h4", "", title));
  card.append(el("div", "trace-meta", `${record.status} · ${formatDateTime(record.startedAt)}`));
  if (record.outcome?.summary) {
    card.append(el("div", "", record.outcome.summary));
  } else if (record.steps?.length) {
    card.append(el("div", "", `步骤数：${record.steps.length}`));
  }
  const actions = el("div", "trace-actions");
  const button = el("button", "ghost inline", "查看");
  button.addEventListener("click", () => void openTraceDetail(kind, title));
  actions.append(button);
  card.append(actions);
  return card;
}

function renderTraceLists() {
  if (!state.indexTraces.length) renderEmpty(indexTraceListEl, "暂无 Index 追踪。");
  else {
    clearNode(indexTraceListEl);
    state.indexTraces.forEach((trace) => indexTraceListEl.append(buildTraceCard(trace, "index-traces")));
  }

  if (!state.dreamTraces.length) renderEmpty(dreamTraceListEl, "暂无 Dream 追踪。");
  else {
    clearNode(dreamTraceListEl);
    state.dreamTraces.forEach((trace) => dreamTraceListEl.append(buildTraceCard(trace, "dream-traces")));
  }
}

async function loadOverview() {
  state.overview = await fetchJson("/api/memory/overview");
  renderOverview();
}

async function loadSettings() {
  state.settings = await fetchJson("/api/memory/settings");
  renderSettings();
}

async function loadWorkspace() {
  const query = state.workspaceQuery ? `&q=${encodeURIComponent(state.workspaceQuery)}` : "";
  state.workspace = await fetchJson(`/api/memory/workspace?limit=200${query}`);
  renderWorkspace();
  renderOverview();
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
  if (!state.token || !state.projectPath) {
    setStatus("缺少 token 或 projectPath，无法加载 memory dashboard。", "error");
    return;
  }
  setStatus("正在加载当前 workspace 记忆…");
  try {
    await Promise.all([loadOverview(), loadSettings(), loadWorkspace(), loadUserSummary(), loadTraces()]);
    setStatus("当前 workspace 记忆已刷新。");
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

async function runAction(label, path) {
  setStatus(`${label} 执行中…`);
  try {
    const result = await fetchJson(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: {},
    });
    setStatus(`${label} 完成：${stringifyDetail(result.summary || result)}`);
    await loadDashboard();
  } catch (error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }
}

refreshBtn.addEventListener("click", () => void loadDashboard());
indexBtn.addEventListener("click", () => void runAction("Index", "/api/memory/index/run"));
dreamBtn.addEventListener("click", () => void runAction("Dream", "/api/memory/dream/run"));

exportBtn.addEventListener("click", async () => {
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
});

importBtn.addEventListener("click", () => importInput.click());
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

clearBtn.addEventListener("click", async () => {
  if (!window.confirm("确认清空当前 workspace 的全部记忆吗？")) return;
  await runAction("清空", "/api/memory/clear");
});

workspaceSearchEl.addEventListener("input", () => {
  state.workspaceQuery = workspaceSearchEl.value.trim();
  void loadWorkspace();
});

editProjectMetaBtn?.addEventListener("click", async () => {
  const current = state.workspace?.projectMeta || {};
  const projectName = window.prompt("更新项目名称", current.projectName || "");
  if (projectName === null) return;
  const description = window.prompt("更新项目描述", current.description || "");
  if (description === null) return;
  const aliasesRaw = window.prompt("更新项目别名，使用英文逗号分隔", Array.isArray(current.aliases) ? current.aliases.join(", ") : "");
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
});

editSettingsBtn?.addEventListener("click", async () => {
  const current = state.settings || {};
  const reasoningMode = window.prompt("更新 reasoningMode(answer_first / accuracy_first)", current.reasoningMode || "answer_first");
  if (reasoningMode === null) return;
  const autoIndexIntervalMinutes = window.prompt("更新 autoIndexIntervalMinutes", String(current.autoIndexIntervalMinutes ?? 60));
  if (autoIndexIntervalMinutes === null) return;
  const autoDreamIntervalMinutes = window.prompt("更新 autoDreamIntervalMinutes", String(current.autoDreamIntervalMinutes ?? 360));
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
});

void loadDashboard();
