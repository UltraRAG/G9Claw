import { renderTraceI18nText } from "./trace-i18n.js";

const params = new URLSearchParams(window.location.search);

const MEMORY_LOCALE = params.get("locale") === "zh" ? "zh" : "en";
const MEMORY_THEME = params.get("theme") === "dark" ? "dark" : "light";
const DATE_TIME_LOCALE = MEMORY_LOCALE === "zh" ? "zh-CN" : "en-US";

function applyMemoryTheme(theme) {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;

  const colorSchemeMeta = document.querySelector('meta[name="color-scheme"]');
  if (colorSchemeMeta) {
    colorSchemeMeta.setAttribute("content", theme);
  }
}

const UI_STRINGS = {
  zh: {
    "doc.title": "Memory",
    "status.ready": "已就绪",
    "status.errorOccurred": "发生错误",
    "status.waitingForIndex": "等待索引",
    "status.refreshing": "正在刷新当前视图…",
    "status.running": "{0} 执行中…",
    "status.done": "{0} 完成",
    "status.noSteps": "暂无步骤。",
    "status.notFoundMemory": "未找到该记忆文件。",
    "status.memoryUpdated": "记忆已更新。",
    "status.memoryRestored": "记忆已恢复。",
    "status.memoryDeprecated": "记忆已弃用。",
    "status.memoryDeleted": "记忆已删除。",
    "status.memoryExported": "记忆已导出。",
    "status.memoryImported": "记忆已导入。",
    "status.currentProjectMemoryExported": "当前项目记忆已导出。",
    "status.currentProjectMemoryImported": "当前项目记忆已导入。",
    "status.allProjectsMemoryExported": "全部项目记忆已导出。",
    "status.allProjectsMemoryImported": "全部项目记忆已导入。",
    "status.projectMetaUpdated": "项目元信息已更新。",
    "status.settingsSaved": "设置已保存。",
    "status.lastDreamRolledBack": "已回滚上一次 Dream。",
    "status.noToolEvents": "无",
    "status.noReply": "暂无回复。",
    "status.noContext": "无",
    "status.yes": "是",
    "status.no": "否",
    "status.unknown": "未知",
    "nav.project": "项目记忆",
    "nav.user": "用户画像",
    "nav.trace": "记忆追踪",
    "topbar.lastIndexed": "最近索引",
    "search.placeholder": "搜索当前视图",
    "actions.search": "搜索",
    "actions.refresh": "刷新",
    "actions.index": "索引同步",
    "actions.dream": "记忆 Dream",
    "actions.settings": "设置",
    "actions.close": "关闭",
    "actions.saveSettings": "保存设置",
    "actions.exportCurrentProject": "导出当前项目记忆",
    "actions.importCurrentProject": "导入当前项目记忆",
    "actions.exportAllProjects": "导出全部项目记忆",
    "actions.importAllProjects": "导入全部项目记忆",
    "actions.rollbackLastDream": "回滚上一次 Dream",
    "actions.clearProject": "清空当前项目记忆",
    "actions.clearAll": "清空所有记忆",
    "actions.edit": "编辑",
    "actions.view": "查看",
    "actions.deprecate": "弃用",
    "actions.restore": "恢复",
    "actions.delete": "删除",
    "actions.cancel": "取消",
    "actions.save": "保存",
    "project.section.title": "项目记忆",
    "project.section.subtitle": "当前 project 的进展、事实和状态记录",
    "feedback.section.title": "协作反馈",
    "feedback.section.subtitle": "用户对当前 project 的偏好、约束和交付规则",
    "deprecated.section.title": "已弃用",
    "deprecated.section.subtitle": "已标记为弃用的项目记忆与协作反馈",
    "user.section.title": "用户画像",
    "user.section.subtitle": "长期身份背景信息",
    "trace.tab.recall": "Recall",
    "trace.tab.index": "Index",
    "trace.tab.dream": "Dream",
    "trace.selectCase": "选择案例",
    "trace.selectTrace": "选择追踪",
    "trace.selectRecallCase": "选择一个 Recall 事例…",
    "trace.selectIndexTrace": "选择一条 Index 追踪…",
    "trace.selectDreamTrace": "选择一条 Dream 追踪…",
    "trace.injectedContext": "注入上下文",
    "trace.toolEvents": "工具活动",
    "trace.finalReply": "最终回答",
    "trace.reasoningTimeline": "推理过程",
    "trace.empty.recall": "选择一个事例查看 Recall 详情。",
    "trace.empty.trace": "选择一条追踪查看详情。",
    "trace.meta.query": "问题",
    "trace.meta.session": "会话",
    "trace.meta.mode": "模式",
    "trace.meta.reason": "召回理由",
    "trace.meta.status": "状态",
    "trace.meta.injected": "注入",
    "trace.meta.started": "开始",
    "trace.meta.finished": "结束",
    "trace.sourceLabel": "来源：{0} · 状态：{1}。说明：{2}",
    "trace.index.explanation": "Index 追踪展示的是 Dream 前的 append-only 产物；主视图展示的是当前文件状态，可能已经被 Dream 合并。",
    "trace.dream.explanation": "Dream 追踪展示的是合并、重写和删除过程；主视图展示的是 Dream 完成后的当前文件状态。",
    "route.user": "用户",
    "route.project": "项目",
    "route.mix": "项目 + 用户",
    "route.none": "无",
    "trigger.manual": "手动",
    "trigger.scheduled": "自动",
    "trigger.rollback": "回滚",
    "displayStatus.noop": "空跑",
    "displayStatus.completed": "已完成",
    "displayStatus.error": "错误",
    "displayStatus.running": "运行中",
    "displayStatus.skipped": "跳过",
    "project.context.defaultDescription": "当前打开的 workspace 就是唯一顶层 project。",
    "project.context.statusChip": "状态 {0}",
    "project.context.projectMemoryChip": "项目记忆 {0}",
    "project.context.feedbackChip": "协作反馈 {0}",
    "project.context.pathChip": "项目路径 {0}",
    "project.currentProject": "当前项目",
    "user.identityBackground": "身份背景",
    "user.emptySummary": "当前还没有汇总后的用户画像；User Notes 会在 Dream 后合并到这里。",
    "workspace.empty.project": "当前没有项目记忆。",
    "workspace.empty.feedback": "当前没有协作反馈。",
    "workspace.empty.deprecated": "当前没有已弃用记忆。",
    "record.badge.deprecated": "已弃用",
    "record.badge.feedback": "反馈",
    "record.badge.project": "项目",
    "detail.title": "详情",
    "detail.empty": "选择一条记忆查看详情。",
    "detail.meta": "{0} · {1}",
    "detail.noDescription": "暂无描述。",
    "timeline.status": "状态",
    "timeline.stepType": "步骤类型",
    "timeline.metrics": "指标",
    "timeline.refs": "引用",
    "timeline.inputSummary": "输入摘要",
    "timeline.outputSummary": "输出摘要",
    "timeline.details": "详细信息",
    "timeline.promptDebug": "Prompt Debug — {0}",
    "timeline.systemPrompt": "System Prompt",
    "timeline.userPrompt": "User Prompt",
    "timeline.rawResponse": "Raw Response",
    "timeline.parsedResult": "Parsed Result",
    "settings.title": "设置",
    "settings.parameters.title": "参数设置",
    "settings.autoIndex.label": "自动索引间隔",
    "settings.autoIndex.hint": "0 表示关闭自动任务",
    "settings.autoDream.label": "自动 Dream 间隔",
    "settings.autoDream.hint": "只有自上次 Dream 以来有记忆文件更新时，自动 Dream 才会真正执行。",
    "settings.unit.minutes": "分钟",
    "settings.unit.hours": "小时",
    "settings.dataManagement.title": "数据管理",
    "settings.data.currentProject": "当前项目",
    "settings.data.allMemory": "全部记忆",
    "settings.snapshot.none": "还没有可用的 Dream 快照。",
    "settings.snapshot.ready": "可回滚",
    "settings.snapshot.stale": "快照已失效",
    "settings.snapshot.meta": "快照：{0} · 来源：{1} · {2}",
    "confirm.importCurrentProject": "导入将覆盖当前项目记忆，但不会影响其他项目，也不会修改工作区代码文件。确认继续吗？",
    "confirm.importAllProjects": "导入将覆盖全部项目记忆和全局用户画像，但不会修改工作区代码文件。确认继续吗？",
    "confirm.rollbackLastDream": "回滚将恢复上一次 Dream 前的记忆快照，并覆盖当前项目记忆与全局用户画像中的 Dream 结果。不会修改工作区代码文件。确认继续吗？",
    "confirm.deleteMemory": "确认删除 {0}？",
    "confirm.clearProject": "确认清空当前项目的全部记忆吗？这不会删除全局用户身份背景。",
    "confirm.clearAll": "确认清空所有记忆吗？这会删除所有项目记忆以及全局用户身份背景。",
    "prompt.editMemoryName": "更新记忆名称",
    "prompt.editMemoryDescription": "更新记忆描述",
    "prompt.editProjectName": "更新项目名称",
    "prompt.editProjectDescription": "更新项目描述",
    "prompt.editProjectStatus": "更新项目状态",
    "editor.project.title": "编辑项目信息",
    "editor.project.subtitle": "修改项目 meta，不会直接重写已有记忆正文。",
    "editor.project.name": "项目名称",
    "editor.project.description": "项目摘要",
    "editor.project.status": "项目状态",
    "editor.project.save": "保存项目信息",
    "editor.memory.title.project": "编辑项目记忆",
    "editor.memory.title.feedback": "编辑协作反馈",
    "editor.memory.subtitle": "只编辑头字段，不直接暴露原始 markdown。",
    "editor.memory.name": "记忆名称",
    "editor.memory.description": "记忆摘要",
    "editor.memory.save": "保存记忆",
    "editor.status.planned": "计划中",
    "editor.status.in_progress": "进行中",
    "editor.status.done": "已完成",
    "editor.error.projectNameRequired": "项目名称不能为空。",
    "editor.error.memoryNameRequired": "记忆名称不能为空。",
    "actions.back": "← 返回",
    "error.authRequired": "需要登录后才能访问当前项目的 Memory Dashboard。",
    "error.missingProjectPath": "缺少 projectPath，无法加载当前项目的 Memory Dashboard。",
    "error.bundleDownloadReturnedHtml": "导出接口返回了 HTML 页面，而不是记忆 JSON。通常是服务未重启或路由未生效，请重启 CloudCLI 后重新导出。",
    "error.bundleDownloadInvalidJson": "导出接口返回的不是合法 JSON，无法生成记忆导出文件。",
    "error.apiReturnedHtml": "接口返回了 HTML 页面，而不是预期的 JSON。通常是服务未重启或路由未生效。",
    "error.apiReturnedInvalidJson": "接口返回的不是合法 JSON。",
    "error.importFileIsHtml": "你选择的文件不是记忆导出包，而是一页 HTML 页面。通常是之前导出时服务未重启或路由未生效，请重新导出后再导入。",
    "error.importFileInvalidJson": "你选择的文件不是合法的记忆 JSON 导出包。",
  },
  en: {
    "doc.title": "Memory",
    "status.ready": "Ready",
    "status.errorOccurred": "Error",
    "status.waitingForIndex": "Waiting for indexing",
    "status.refreshing": "Refreshing the current view…",
    "status.running": "{0} in progress…",
    "status.done": "{0} completed",
    "status.noSteps": "No steps yet.",
    "status.notFoundMemory": "Memory file not found.",
    "status.memoryUpdated": "Memory updated.",
    "status.memoryRestored": "Memory restored.",
    "status.memoryDeprecated": "Memory deprecated.",
    "status.memoryDeleted": "Memory deleted.",
    "status.memoryExported": "Memory exported.",
    "status.memoryImported": "Memory imported.",
    "status.currentProjectMemoryExported": "Current project memory exported.",
    "status.currentProjectMemoryImported": "Current project memory imported.",
    "status.allProjectsMemoryExported": "All-project memory exported.",
    "status.allProjectsMemoryImported": "All-project memory imported.",
    "status.projectMetaUpdated": "Project metadata updated.",
    "status.settingsSaved": "Settings saved.",
    "status.lastDreamRolledBack": "Rolled back the last Dream.",
    "status.noToolEvents": "None",
    "status.noReply": "No reply yet.",
    "status.noContext": "None",
    "status.yes": "Yes",
    "status.no": "No",
    "status.unknown": "Unknown",
    "nav.project": "Project Memory",
    "nav.user": "User Profile",
    "nav.trace": "Memory Traces",
    "topbar.lastIndexed": "Last indexed",
    "search.placeholder": "Search current view",
    "actions.search": "Search",
    "actions.refresh": "Refresh",
    "actions.index": "Index Sync",
    "actions.dream": "Memory Dream",
    "actions.settings": "Settings",
    "actions.close": "Close",
    "actions.saveSettings": "Save Settings",
    "actions.exportCurrentProject": "Export Current Project Memory",
    "actions.importCurrentProject": "Import Current Project Memory",
    "actions.exportAllProjects": "Export All Projects Memory",
    "actions.importAllProjects": "Import All Projects Memory",
    "actions.rollbackLastDream": "Rollback Last Dream",
    "actions.clearProject": "Clear Current Project Memory",
    "actions.clearAll": "Clear All Memory",
    "actions.edit": "Edit",
    "actions.view": "View",
    "actions.deprecate": "Deprecate",
    "actions.restore": "Restore",
    "actions.delete": "Delete",
    "actions.cancel": "Cancel",
    "actions.save": "Save",
    "project.section.title": "Project Memory",
    "project.section.subtitle": "Progress, facts, and status records for the current project.",
    "feedback.section.title": "Collaboration Feedback",
    "feedback.section.subtitle": "Preferences, constraints, and delivery rules for the current project.",
    "deprecated.section.title": "Deprecated",
    "deprecated.section.subtitle": "Project memory and collaboration feedback marked as deprecated.",
    "user.section.title": "User Profile",
    "user.section.subtitle": "Long-term identity background information.",
    "trace.tab.recall": "Recall",
    "trace.tab.index": "Index",
    "trace.tab.dream": "Dream",
    "trace.selectCase": "Select Case",
    "trace.selectTrace": "Select Trace",
    "trace.selectRecallCase": "Select a Recall case…",
    "trace.selectIndexTrace": "Select an Index trace…",
    "trace.selectDreamTrace": "Select a Dream trace…",
    "trace.injectedContext": "Injected Context",
    "trace.toolEvents": "Tool Events",
    "trace.finalReply": "Final Reply",
    "trace.reasoningTimeline": "Reasoning Timeline",
    "trace.empty.recall": "Select a case to inspect Recall details.",
    "trace.empty.trace": "Select a trace to inspect details.",
    "trace.meta.query": "Query",
    "trace.meta.session": "Session",
    "trace.meta.mode": "Mode",
    "trace.meta.reason": "Recall Route",
    "trace.meta.status": "Status",
    "trace.meta.injected": "Injected",
    "trace.meta.started": "Started",
    "trace.meta.finished": "Finished",
    "trace.sourceLabel": "Source: {0} · Status: {1}. Note: {2}",
    "trace.index.explanation": "Index traces show append-only artifacts before Dream; the main board shows the current file state, which may already have been merged by Dream.",
    "trace.dream.explanation": "Dream traces show merge, rewrite, and deletion steps; the main board shows the current file state after Dream completes.",
    "route.user": "User",
    "route.project": "Project",
    "route.mix": "Project + User",
    "route.none": "None",
    "trigger.manual": "Manual",
    "trigger.scheduled": "Scheduled",
    "trigger.rollback": "Rollback",
    "displayStatus.noop": "No-op",
    "displayStatus.completed": "Completed",
    "displayStatus.error": "Error",
    "displayStatus.running": "Running",
    "displayStatus.skipped": "Skipped",
    "project.context.defaultDescription": "The current workspace is the only top-level project.",
    "project.context.statusChip": "Status {0}",
    "project.context.projectMemoryChip": "Project Memory {0}",
    "project.context.feedbackChip": "Collaboration Feedback {0}",
    "project.context.pathChip": "Project Path {0}",
    "project.currentProject": "Current Project",
    "user.identityBackground": "Identity Background",
    "user.emptySummary": "No consolidated user profile yet. User Notes will be merged here after Dream.",
    "workspace.empty.project": "No project memory yet.",
    "workspace.empty.feedback": "No collaboration feedback yet.",
    "workspace.empty.deprecated": "No deprecated memory yet.",
    "record.badge.deprecated": "Deprecated",
    "record.badge.feedback": "Feedback",
    "record.badge.project": "Project",
    "detail.title": "Details",
    "detail.empty": "Select a memory item to inspect details.",
    "detail.meta": "{0} · {1}",
    "detail.noDescription": "No description yet.",
    "timeline.status": "Status",
    "timeline.stepType": "Step Type",
    "timeline.metrics": "Metrics",
    "timeline.refs": "References",
    "timeline.inputSummary": "Input Summary",
    "timeline.outputSummary": "Output Summary",
    "timeline.details": "Details",
    "timeline.promptDebug": "Prompt Debug — {0}",
    "timeline.systemPrompt": "System Prompt",
    "timeline.userPrompt": "User Prompt",
    "timeline.rawResponse": "Raw Response",
    "timeline.parsedResult": "Parsed Result",
    "settings.title": "Settings",
    "settings.parameters.title": "Parameters",
    "settings.autoIndex.label": "Auto Index Interval",
    "settings.autoIndex.hint": "Set to 0 to disable automatic tasks.",
    "settings.autoDream.label": "Auto Dream Interval",
    "settings.autoDream.hint": "Automatic Dream only runs when memory files have changed since the last Dream.",
    "settings.unit.minutes": "Minutes",
    "settings.unit.hours": "Hours",
    "settings.dataManagement.title": "Data Management",
    "settings.data.currentProject": "Current Project",
    "settings.data.allMemory": "All Memory",
    "settings.snapshot.none": "No Dream snapshot is available yet.",
    "settings.snapshot.ready": "Rollback ready",
    "settings.snapshot.stale": "Snapshot stale",
    "settings.snapshot.meta": "Snapshot: {0} · Source: {1} · {2}",
    "confirm.importCurrentProject": "Importing will overwrite the current project's memory, but it will not affect other projects or modify workspace code files. Continue?",
    "confirm.importAllProjects": "Importing will overwrite all project memory and the global user profile, but it will not modify workspace code files. Continue?",
    "confirm.rollbackLastDream": "Rollback will restore the memory snapshot from before the last Dream and overwrite the current project's Dream results plus the global user profile updates. It will not modify workspace code files. Continue?",
    "confirm.deleteMemory": "Delete {0}?",
    "confirm.clearProject": "Clear all memory for the current project? This will not delete global user identity background.",
    "confirm.clearAll": "Clear all memory? This will delete all project memory and global user identity background.",
    "prompt.editMemoryName": "Update memory name",
    "prompt.editMemoryDescription": "Update memory description",
    "prompt.editProjectName": "Update project name",
    "prompt.editProjectDescription": "Update project description",
    "prompt.editProjectStatus": "Update project status",
    "editor.project.title": "Edit Project Info",
    "editor.project.subtitle": "Update project metadata without rewriting existing memory bodies.",
    "editor.project.name": "Project Name",
    "editor.project.description": "Project Summary",
    "editor.project.status": "Project Status",
    "editor.project.save": "Save Project Info",
    "editor.memory.title.project": "Edit Project Memory",
    "editor.memory.title.feedback": "Edit Collaboration Feedback",
    "editor.memory.subtitle": "Edit only header fields without exposing raw markdown.",
    "editor.memory.name": "Memory Name",
    "editor.memory.description": "Memory Summary",
    "editor.memory.save": "Save Memory",
    "editor.status.planned": "Planned",
    "editor.status.in_progress": "In Progress",
    "editor.status.done": "Done",
    "editor.error.projectNameRequired": "Project name is required.",
    "editor.error.memoryNameRequired": "Memory name is required.",
    "actions.back": "← Back",
    "error.authRequired": "Sign in to access the Memory Dashboard for the current project.",
    "error.missingProjectPath": "Missing projectPath; unable to load the Memory Dashboard for the current project.",
    "error.bundleDownloadReturnedHtml": "The export endpoint returned an HTML page instead of a memory JSON bundle. This usually means the service was not restarted or the route is not active. Restart CloudCLI and export again.",
    "error.bundleDownloadInvalidJson": "The export endpoint did not return valid JSON, so the memory export file could not be created.",
    "error.apiReturnedHtml": "The endpoint returned an HTML page instead of the expected JSON. This usually means the service was not restarted or the route is not active.",
    "error.apiReturnedInvalidJson": "The endpoint did not return valid JSON.",
    "error.importFileIsHtml": "The selected file is not a memory export bundle. It is an HTML page, usually because the earlier export hit an old or inactive route. Export again and retry the import.",
    "error.importFileInvalidJson": "The selected file is not a valid memory JSON export bundle.",
  },
};

const TRACE_LOCALES = {
  zh: {
    "trace.step.index_start": "开始索引",
    "trace.step.batch_loaded": "批次已加载",
    "trace.step.focus_turns_selected": "已选择焦点轮次",
    "trace.step.index_finished": "索引完成",
    "trace.step.recall_start": "开始 Recall",
    "trace.step.memory_gate": "记忆路由判定",
    "trace.step.user_base_loaded": "已加载用户基础信息",
    "trace.step.manifest_scanned": "已扫描清单",
    "trace.step.manifest_selected": "已选择清单文件",
    "trace.step.files_loaded": "文件已加载",
    "trace.step.context_rendered": "上下文已渲染",
    "trace.step.dream_start": "开始 Dream",
    "trace.step.snapshot_loaded": "快照已加载",
    "trace.step.dream_finished": "Dream 完成",
    "trace.step.project_meta_review": "项目元信息审查",
    "trace.step.user_profile_rewritten": "用户画像已重写",
    "trace.step.manifests_repaired": "清单已修复",
    "trace.step.project_header_scan": "项目记忆头部扫描",
    "trace.step.feedback_header_scan": "反馈记忆头部扫描",
    "trace.step.project_cluster_plan": "项目记忆聚类规划",
    "trace.step.feedback_cluster_plan": "反馈记忆聚类规划",
    "trace.step.project_cluster_refine": "项目记忆聚类精炼",
    "trace.step.feedback_cluster_refine": "反馈记忆聚类精炼",
    "trace.text.index_start.output.preparing_batch": "正在准备批次索引：{0}。",
    "trace.text.batch_loaded.input": "共 {0} 段，时间范围 {1} 到 {2}",
    "trace.text.batch_loaded.output": "批次上下文中已加载 {0} 条消息。",
    "trace.text.focus_turns_selected.input": "本批次共有 {0} 个用户轮次。",
    "trace.text.focus_turns_selected.output.classifying": "将逐条分类这些用户轮次。",
    "trace.text.focus_turns_selected.output.no_user_turns": "未找到用户轮次；该批次将标记为已索引，但不会存储记忆。",
    "trace.text.index_error.title": "索引错误",
    "trace.detail.batch_summary": "批次摘要",
    "trace.detail.batch_context": "批次上下文",
    "trace.detail.focus_selection_summary": "焦点选择摘要",
    "trace.detail.focus_turn": "焦点轮次 {0}",
    "trace.detail.focus_user_turn": "焦点用户输入",
    "trace.detail.classification_result": "分类结果",
    "trace.detail.classifier_candidates": "分类候选",
    "trace.detail.persisted_files": "已持久化文件",
    "trace.detail.index_error": "索引错误",
    "trace.detail.stored_results": "存储结果",
    "trace.detail.recall_inputs": "Recall 输入",
    "trace.detail.route": "路由",
    "trace.detail.user_profile": "用户画像",
    "trace.detail.source_files": "来源文件",
    "trace.detail.manifest_scan": "清单扫描",
    "trace.detail.sorted_candidates": "排序后的候选",
    "trace.detail.manifest_candidate_ids": "清单候选 ID",
    "trace.detail.selected_file_ids": "已选择文件 ID",
    "trace.detail.requested_ids": "请求的 ID",
    "trace.detail.loaded_files": "已加载文件",
    "trace.detail.context_summary": "上下文摘要",
    "trace.detail.injected_blocks": "注入块",
    "trace.detail.snapshot_summary": "快照摘要",
    "trace.detail.project_meta": "项目元信息",
  },
  en: {},
};

function formatMessage(template, ...args) {
  return String(template).replace(/\{(\d+)\}/g, (_, index) => {
    const value = args[Number(index)];
    return value == null ? "" : String(value);
  });
}

function t(key, ...args) {
  const template = UI_STRINGS[MEMORY_LOCALE]?.[key] ?? UI_STRINGS.en[key] ?? key;
  return formatMessage(template, ...args);
}

const state = {
  token: params.get("token") || "",
  projectPath: params.get("projectPath") || "",
  locale: MEMORY_LOCALE,
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
  editorOpen: false,
  editorSession: null,
  memoryDetailOpen: false,
  previousPage: "project",
  maintenanceBusy: false,
};

applyMemoryTheme(MEMORY_THEME);
document.documentElement.lang = MEMORY_LOCALE === "zh" ? "zh-CN" : "en";
document.title = t("doc.title");

const DEFAULT_ACTIVITY = t("status.ready");

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
const settingsModalEl = document.getElementById("settingsModal");
const settingsCloseBtn = document.getElementById("settingsCloseBtn");
const saveSettingsBtn = document.getElementById("saveSettingsBtn");
const settingAutoIndexEl = document.getElementById("settingAutoIndex");
const settingAutoIndexUnitEl = document.getElementById("settingAutoIndexUnit");
const settingAutoDreamEl = document.getElementById("settingAutoDream");
const settingAutoDreamUnitEl = document.getElementById("settingAutoDreamUnit");
const refreshBtn = document.getElementById("refreshBtn");
const indexBtn = document.getElementById("indexBtn");
const dreamBtn = document.getElementById("dreamBtn");
const exportCurrentProjectBtn = document.getElementById("exportCurrentProjectBtn");
const importCurrentProjectBtn = document.getElementById("importCurrentProjectBtn");
const rollbackLastDreamBtn = document.getElementById("rollbackLastDreamBtn");
const exportAllProjectsBtn = document.getElementById("exportAllProjectsBtn");
const importAllProjectsBtn = document.getElementById("importAllProjectsBtn");
const importCurrentProjectInput = document.getElementById("importCurrentProjectInput");
const importAllProjectsInput = document.getElementById("importAllProjectsInput");
const clearProjectBtn = document.getElementById("clearProjectBtn");
const clearAllBtn = document.getElementById("clearAllBtn");
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

const memoryDetailBoardEl = document.getElementById("memoryDetailBoard");
const detailBackBtn = document.getElementById("detailBackBtn");
const detailPageMetaEl = document.getElementById("detailPageMeta");
const detailPageTitleEl = document.getElementById("detailPageTitle");
const detailPageDescriptionEl = document.getElementById("detailPageDescription");
const detailPageActionsEl = document.getElementById("detailPageActions");
const detailPageContentEl = document.getElementById("detailPageContent");

const detailDrawerEl = document.getElementById("detailDrawer");
const detailCloseBtn = document.getElementById("detailCloseBtn");
const detailEmptyEl = document.getElementById("detailEmpty");
const detailViewEl = document.getElementById("detailView");
const detailMetaEl = document.getElementById("detailMeta");
const detailTitleEl = document.getElementById("detailTitle");
const detailDescriptionEl = document.getElementById("detailDescription");
const detailActionsEl = document.getElementById("detailActions");
const detailContentEl = document.getElementById("detailContent");
const editorModalEl = document.getElementById("editorModal");
const editorCloseBtn = document.getElementById("editorCloseBtn");
const editorFormEl = document.getElementById("editorForm");
const editorErrorEl = document.getElementById("editorError");
const editorModalTitleEl = document.getElementById("editorModalTitle");
const editorModalSubtitleEl = document.getElementById("editorModalSubtitle");
const editorProjectFieldsEl = document.getElementById("editorProjectFields");
const editorProjectNameEl = document.getElementById("editorProjectName");
const editorProjectStatusEl = document.getElementById("editorProjectStatus");
const editorProjectDescriptionEl = document.getElementById("editorProjectDescription");
const editorMemoryFieldsEl = document.getElementById("editorMemoryFields");
const editorMemoryNameEl = document.getElementById("editorMemoryName");
const editorMemoryDescriptionEl = document.getElementById("editorMemoryDescription");
const editorCancelBtn = document.getElementById("editorCancelBtn");
const editorSaveBtn = document.getElementById("editorSaveBtn");

const PAGE_CONFIG = {
  project: { title: t("nav.project") },
  user: { title: t("nav.user") },
  trace: { title: t("nav.trace") },
};

const SETTINGS_UNIT_STORAGE_KEYS = {
  autoIndex: "edgeclaw-memory:settings:autoIndexUnit",
  autoDream: "edgeclaw-memory:settings:autoDreamUnit",
};

const SETTINGS_FIELD_CONFIG = {
  autoIndex: {
    inputEl: settingAutoIndexEl,
    unitEl: settingAutoIndexUnitEl,
    storageKey: SETTINGS_UNIT_STORAGE_KEYS.autoIndex,
    settingsKey: "autoIndexIntervalMinutes",
    defaultMinutes: 60,
  },
  autoDream: {
    inputEl: settingAutoDreamEl,
    unitEl: settingAutoDreamUnitEl,
    storageKey: SETTINGS_UNIT_STORAGE_KEYS.autoDream,
    settingsKey: "autoDreamIntervalMinutes",
    defaultMinutes: 360,
  },
};

/* ── Utilities ── */

function normalizeSettingsUnit(value) {
  return value === "minutes" ? "minutes" : "hours";
}

function readSettingsUnitPreference(fieldKey) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return "hours";
  try {
    return normalizeSettingsUnit(window.localStorage.getItem(config.storageKey) || "hours");
  } catch {
    return "hours";
  }
}

function writeSettingsUnitPreference(fieldKey, unit) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return;
  try {
    window.localStorage.setItem(config.storageKey, normalizeSettingsUnit(unit));
  } catch {
    // Best effort only; the UI still works without persisted unit preferences.
  }
}

function getSettingsFieldMinutes(fieldKey) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return 0;
  const value = state.settings?.[config.settingsKey];
  return Number.isFinite(value) ? Number(value) : config.defaultMinutes;
}

function formatIntervalValue(minutes, unit) {
  const normalizedMinutes = Number.isFinite(minutes) ? Math.max(0, Number(minutes)) : 0;
  const value = unit === "minutes" ? normalizedMinutes : normalizedMinutes / 60;
  const rounded = Number(value.toFixed(4));
  if (Number.isNaN(rounded)) return "0";
  return Number.isInteger(rounded) ? String(rounded) : String(rounded);
}

function parseIntervalInputValue(value, fallbackMinutes, unit) {
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed)) return fallbackMinutes;
  return Math.max(0, unit === "minutes" ? parsed : parsed * 60);
}

function syncSettingsFieldDisplay(fieldKey, minutes) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return;
  const unit = normalizeSettingsUnit(config.unitEl.value);
  config.unitEl.value = unit;
  config.unitEl.dataset.prevUnit = unit;
  config.inputEl.value = formatIntervalValue(minutes, unit);
}

function syncSettingsInputsFromState() {
  Object.entries(SETTINGS_FIELD_CONFIG).forEach(([fieldKey, config]) => {
    const unit = readSettingsUnitPreference(fieldKey);
    config.unitEl.value = unit;
    config.unitEl.dataset.prevUnit = unit;
    syncSettingsFieldDisplay(fieldKey, getSettingsFieldMinutes(fieldKey));
  });
}

function getCurrentSettingsFieldMinutes(fieldKey) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return 0;
  const unit = normalizeSettingsUnit(config.unitEl.value);
  return parseIntervalInputValue(config.inputEl.value, getSettingsFieldMinutes(fieldKey), unit);
}

function handleSettingsUnitChange(fieldKey) {
  const config = SETTINGS_FIELD_CONFIG[fieldKey];
  if (!config) return;
  const previousUnit = normalizeSettingsUnit(config.unitEl.dataset.prevUnit);
  const currentMinutes = parseIntervalInputValue(
    config.inputEl.value,
    getSettingsFieldMinutes(fieldKey),
    previousUnit,
  );
  const nextUnit = normalizeSettingsUnit(config.unitEl.value);
  writeSettingsUnitPreference(fieldKey, nextUnit);
  config.unitEl.dataset.prevUnit = nextUnit;
  config.inputEl.value = formatIntervalValue(currentMinutes, nextUnit);
}

function applyStaticTranslations() {
  document.querySelectorAll("[data-i18n]").forEach((node) => {
    const key = node.getAttribute("data-i18n");
    if (key) node.textContent = t(key);
  });
  document.querySelectorAll("[data-i18n-placeholder]").forEach((node) => {
    const key = node.getAttribute("data-i18n-placeholder");
    if (key) node.setAttribute("placeholder", t(key));
  });
  document.querySelectorAll("[data-i18n-title]").forEach((node) => {
    const key = node.getAttribute("data-i18n-title");
    if (key) node.setAttribute("title", t(key));
  });
}

function setActivity(msg = DEFAULT_ACTIVITY) { activityTextEl.textContent = msg || DEFAULT_ACTIVITY; }

function updateAppScrim() {
  const open = state.detailOpen || state.settingsOpen || state.editorOpen;
  appScrimEl.classList.toggle("is-open", open);
  appScrimEl.classList.toggle("hidden", !open);
}

function formatProjectStatusLabel(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return t("editor.status.in_progress");
  return t(`editor.status.${normalized}`) === `editor.status.${normalized}` ? normalized : t(`editor.status.${normalized}`);
}

function setStatus(message, kind = "info") {
  if (!message) { statusBarEl.classList.add("hidden"); statusBarEl.textContent = ""; setActivity(DEFAULT_ACTIVITY); return; }
  if (kind === "error") { statusBarEl.classList.remove("hidden"); statusBarEl.textContent = message; statusBarEl.dataset.kind = kind; setActivity(t("status.errorOccurred")); return; }
  statusBarEl.classList.add("hidden"); statusBarEl.textContent = ""; delete statusBarEl.dataset.kind; setActivity(message);
}

function setMaintenanceBusy(next) {
  state.maintenanceBusy = Boolean(next);
  syncMaintenanceActionState();
}

function formatTraceTrigger(trigger) {
  if (trigger === "scheduled") return t("trigger.scheduled");
  if (trigger === "rollback") return t("trigger.rollback");
  return t("trigger.manual");
}

function formatRecallRoute(route) {
  switch (route) {
    case "user":
      return t("route.user");
    case "project":
      return t("route.project");
    case "mix":
      return t("route.mix");
    case "none":
      return t("route.none");
    case "project_memory":
      return t("route.project");
    default:
      return route || t("route.none");
  }
}

function formatTraceDisplayStatus(record) {
  if (record?.isNoOp) return t("displayStatus.noop");
  switch (record?.displayStatus) {
    case "Completed":
      return t("displayStatus.completed");
    case "No-op":
      return t("displayStatus.noop");
    case "Error":
      return t("displayStatus.error");
    case "Running":
      return t("displayStatus.running");
    default:
      break;
  }
  switch (record?.status) {
    case "completed":
      return t("displayStatus.completed");
    case "error":
      return t("displayStatus.error");
    case "running":
      return t("displayStatus.running");
    case "skipped":
      return t("displayStatus.skipped");
    default:
      return t("status.unknown");
  }
}

function headers(extra = {}) { return state.token ? { Authorization: `Bearer ${state.token}`, ...extra } : { ...extra }; }

function withProjectPath(url) {
  const next = new URL(url, window.location.origin);
  if (state.projectPath) next.searchParams.set("projectPath", state.projectPath);
  return `${next.pathname}${next.search}`;
}

function parseJsonText(raw) {
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

function looksLikeHtmlDocument(raw) {
  const trimmed = String(raw || "").trimStart().toLowerCase();
  return trimmed.startsWith("<!doctype html") || trimmed.startsWith("<html");
}

function createTaggedError(message, code) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function isRecoverableLegacyRouteError(error) {
  return ["html_response", "invalid_json_response", "not_found"].includes(error?.code);
}

async function requestText(url, options = {}) {
  const response = await fetch(withProjectPath(url), {
    method: options.method || "GET", headers: headers(options.headers),
    ...(options.body ? { body: JSON.stringify({ ...options.body, projectPath: state.projectPath }) } : {}),
  });
  const raw = await response.text();
  return { response, raw, data: parseJsonText(raw) };
}

async function fetchJson(url, options = {}) {
  const { response, raw, data } = await requestText(url, options);
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error(t("error.authRequired"));
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }
  return data;
}

async function fetchBundleText(url) {
  const { response, raw, data } = await requestText(url, { headers: headers() });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error(t("error.authRequired"));
    if (response.status === 404) throw createTaggedError(t("error.apiReturnedHtml"), "not_found");
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }
  if (looksLikeHtmlDocument(raw)) {
    throw createTaggedError(t("error.bundleDownloadReturnedHtml"), "html_response");
  }
  if (!data) {
    throw createTaggedError(t("error.bundleDownloadInvalidJson"), "invalid_json_response");
  }
  return raw;
}

async function postJsonExpectJson(url, body) {
  const { response, raw, data } = await requestText(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) throw new Error(t("error.authRequired"));
    if (response.status === 404) throw createTaggedError(t("error.apiReturnedHtml"), "not_found");
    throw new Error(data?.error || raw || `Request failed: ${response.status}`);
  }
  if (looksLikeHtmlDocument(raw)) {
    throw createTaggedError(t("error.apiReturnedHtml"), "html_response");
  }
  if (!data) {
    throw createTaggedError(t("error.apiReturnedInvalidJson"), "invalid_json_response");
  }
  return data;
}

function el(tag, cls, text) { const n = document.createElement(tag); if (cls) n.className = cls; if (typeof text === "string") n.textContent = text; return n; }
function clearNode(n) { while (n.firstChild) n.removeChild(n.firstChild); }
function renderEmpty(t, text) { clearNode(t); t.append(el("div", "empty-state", text)); }

function formatDateTime(v) { if (!v) return "—"; const d = new Date(v); if (Number.isNaN(d.getTime())) return v; return d.toLocaleString(DATE_TIME_LOCALE); }
function stringifyDetail(v) { return typeof v === "string" ? v : JSON.stringify(v, null, 2); }
function basename(v) { const s = String(v || "").replace(/[\\/]+$/, "").split(/[\\/]/).filter(Boolean); return s[s.length - 1] || v || t("project.currentProject"); }

function formatEntryType(type) {
  switch (type) {
    case "feedback":
      return t("record.badge.feedback");
    case "project":
      return t("record.badge.project");
    default:
      return type || t("status.unknown");
  }
}

function countUserSummaryRecords(s) {
  if (!s) return 0;
  return s.identityBackground?.length ? 1 : 0;
}

function formatLastDreamSnapshotSource(snapshot) {
  if (!snapshot) return t("status.unknown");
  if (snapshot.sourceAction === "rollback") return t("trigger.rollback");
  return formatTraceTrigger(snapshot.trigger);
}

function buildRollbackLastDreamTitle(snapshot) {
  if (!snapshot) {
    return t("settings.snapshot.none");
  }
  const stateLabel = snapshot.rollbackReady ? t("settings.snapshot.ready") : t("settings.snapshot.stale");
  return t(
    "settings.snapshot.meta",
    formatDateTime(snapshot.capturedAt),
    formatLastDreamSnapshotSource(snapshot),
    stateLabel,
  );
}

function syncMaintenanceActionState() {
  const snapshot = state.overview?.lastDreamSnapshot || null;
  dreamBtn.disabled = state.maintenanceBusy;
  if (rollbackLastDreamBtn) {
    rollbackLastDreamBtn.disabled = state.maintenanceBusy || !snapshot?.rollbackReady;
    rollbackLastDreamBtn.title = buildRollbackLastDreamTitle(snapshot);
  }
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
  navLastIndexedEl.textContent = formatDateTime(state.overview?.lastIndexedAt || "") === "—" ? t("status.waitingForIndex") : formatDateTime(state.overview?.lastIndexedAt || "");
  syncMaintenanceActionState();
}

/* ── Page / Tab Navigation ── */

function applyPageChrome() {
  const isDetail = state.memoryDetailOpen;
  listSearchRowEl.classList.toggle("hidden", state.activePage !== "project" || isDetail);
  projectBoardEl.classList.toggle("board-active", state.activePage === "project" && !isDetail);
  userBoardEl.classList.toggle("board-active", state.activePage === "user" && !isDetail);
  traceBoardEl.classList.toggle("board-active", state.activePage === "trace" && !isDetail);
  memoryDetailBoardEl.classList.toggle("board-active", isDetail);
  boardNavTabs.forEach((b) => b.classList.toggle("active", b.dataset.page === state.activePage && !isDetail));
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
  settingsModalEl.classList.remove("hidden");
  syncSettingsInputsFromState();
  updateAppScrim();
}

function closeSettingsDrawer() { state.settingsOpen = false; settingsModalEl.classList.add("hidden"); updateAppScrim(); }

/* ── Detail Drawer ── */

function openDetailDrawer() { state.detailOpen = true; detailDrawerEl.classList.remove("hidden"); updateAppScrim(); }
function closeDetailDrawer() { state.detailOpen = false; detailDrawerEl.classList.add("hidden"); updateAppScrim(); }

function showDetail({ meta = "", title = "", description = "", content = "", actions = [] }) {
  detailMetaEl.textContent = meta;
  detailTitleEl.textContent = title || t("detail.title");
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

/* ── Edit Modal ── */

function resetEditorError() {
  editorErrorEl.textContent = "";
  editorErrorEl.classList.add("hidden");
}

function showEditorError(message) {
  editorErrorEl.textContent = message;
  editorErrorEl.dataset.kind = "error";
  editorErrorEl.classList.remove("hidden");
}

function populateProjectStatusOptions(currentStatus) {
  clearNode(editorProjectStatusEl);
  const normalizedCurrent = String(currentStatus || "in_progress").trim() || "in_progress";
  const options = ["planned", "in_progress", "done"];
  if (!options.includes(normalizedCurrent)) {
    options.push(normalizedCurrent);
  }
  options.forEach((status) => {
    const option = document.createElement("option");
    option.value = status;
    option.textContent = formatProjectStatusLabel(status);
    if (status === normalizedCurrent) option.selected = true;
    editorProjectStatusEl.append(option);
  });
}

function openEditorModal(session) {
  state.editorSession = session;
  state.editorOpen = true;
  resetEditorError();

  editorProjectFieldsEl.classList.toggle("hidden", session.kind !== "project-meta");
  editorMemoryFieldsEl.classList.toggle("hidden", session.kind === "project-meta");

  if (session.kind === "project-meta") {
    editorModalTitleEl.textContent = t("editor.project.title");
    editorModalSubtitleEl.textContent = t("editor.project.subtitle");
    editorSaveBtn.textContent = t("editor.project.save");
    editorProjectNameEl.value = session.projectName;
    editorProjectDescriptionEl.value = session.description;
    populateProjectStatusOptions(session.status);
    editorProjectNameEl.focus();
  } else {
    editorModalTitleEl.textContent = t(`editor.memory.title.${session.record.type}`);
    editorModalSubtitleEl.textContent = t("editor.memory.subtitle");
    editorSaveBtn.textContent = t("editor.memory.save");
    editorMemoryNameEl.value = session.record.name || "";
    editorMemoryDescriptionEl.value = session.record.description || "";
    editorMemoryNameEl.focus();
  }

  editorModalEl.classList.remove("hidden");
  updateAppScrim();
}

function closeEditorModal() {
  state.editorOpen = false;
  state.editorSession = null;
  editorModalEl.classList.add("hidden");
  resetEditorError();
  editorFormEl.reset();
  updateAppScrim();
}

/* ── Project Context Card (editable) ── */

function renderProjectContext() {
  clearNode(projectContextSectionEl);
  const pm = state.workspace?.projectMeta;
  const projectName = pm?.projectName || basename(state.projectPath);

  const wrapper = el("div", "project-context-head");
  const copy = el("div", "project-context-copy");
  copy.append(el("h4", "", projectName));
  copy.append(el("p", "", pm?.description || t("project.context.defaultDescription")));
  wrapper.append(copy);

  const editBtn = el("button", "action-btn", t("actions.edit"));
  editBtn.addEventListener("click", () => void editProjectMeta());
  wrapper.append(editBtn);

  projectContextSectionEl.append(wrapper);

  const meta = el("div", "project-context-meta");
  [
    t("project.context.statusChip", formatProjectStatusLabel(pm?.status || "in_progress")),
    t("project.context.projectMemoryChip", state.workspace?.projectEntries?.length || 0),
    t("project.context.feedbackChip", state.workspace?.feedbackEntries?.length || 0),
    t("project.context.pathChip", basename(state.projectPath)),
  ].forEach((text) => meta.append(el("span", "context-chip", text)));
  projectContextSectionEl.append(meta);
}

/* ── User Summary (ONLY user data) ── */

function renderUserSummary() {
  clearNode(userSummaryEl);
  const summary = state.userSummary;
  const identityBackground = summary?.identityBackground || [];
  if (!summary || !identityBackground.length) {
    userSummaryEl.append(el("div", "empty-state", t("user.emptySummary")));
    updateCounts(); applyPageChrome(); return;
  }
  const card = el("div", "entry-card"); card.dataset.kind = "feedback";
  card.append(el("h4", "", t("user.identityBackground")));
  const list = el("ul", "");
  identityBackground.forEach((item) => list.append(el("li", "", item)));
  card.append(list);
  userSummaryEl.append(card);
  updateCounts(); applyPageChrome();
}

/* ── Memory Entry CRUD ── */

async function openMemoryDetail(id) {
  const records = await fetchJson(`/api/memory/memory/get?ids=${encodeURIComponent(id)}`);
  const record = Array.isArray(records) ? records[0] : null;
  if (!record) { setStatus(t("status.notFoundMemory"), "error"); return; }
  showMemoryDetailPage(record);
}

function showMemoryDetailPage(record) {
  state.previousPage = state.activePage;
  state.memoryDetailOpen = true;

  detailPageMetaEl.textContent = t("detail.meta", formatEntryType(record.type), formatDateTime(record.updatedAt));
  detailPageTitleEl.textContent = record.name;
  detailPageDescriptionEl.textContent = record.description || t("detail.noDescription");
  detailPageContentEl.textContent = record.content;

  clearNode(detailPageActionsEl);
  const actions = [];
  actions.push({ label: t("actions.edit"), onClick: () => void editEntry(record) });
  if (record.deprecated) {
    actions.push({ label: t("actions.restore"), onClick: () => void toggleDeprecation(record) });
    actions.push({ label: t("actions.delete"), variant: "danger", onClick: () => void deleteEntry(record) });
  } else {
    actions.push({ label: t("actions.deprecate"), onClick: () => void toggleDeprecation(record) });
  }
  actions.forEach((a) => {
    const btn = el("button", "tool-btn", a.label);
    if (a.variant === "danger") btn.classList.add("danger");
    btn.addEventListener("click", a.onClick);
    detailPageActionsEl.append(btn);
  });

  applyPageChrome();
}

function closeMemoryDetailPage() {
  state.memoryDetailOpen = false;
  state.activePage = state.previousPage || "project";
  applyPageChrome();
}

async function editEntry(record) {
  openEditorModal({
    kind: "memory-entry",
    record,
  });
}

async function toggleDeprecation(record) {
  await fetchJson("/api/memory/memory/actions", { method: "POST", headers: { "Content-Type": "application/json" }, body: { action: record.deprecated ? "restore_entries" : "deprecate_entries", ids: [record.relativePath] } });
  setStatus(record.deprecated ? t("status.memoryRestored") : t("status.memoryDeprecated")); await loadWorkspace(); await openMemoryDetail(record.relativePath);
}

async function deleteEntry(record) {
  if (!window.confirm(t("confirm.deleteMemory", record.name))) return;
  await fetchJson("/api/memory/memory/actions", { method: "POST", headers: { "Content-Type": "application/json" }, body: { action: "delete_entries", ids: [record.relativePath] } });
  setStatus(t("status.memoryDeleted")); await loadWorkspace(); closeMemoryDetailPage();
}

function buildEntryCard(record) {
  const card = el("div", "entry-card entry-card--clickable");
  card.dataset.kind = record.deprecated ? "deprecated" : record.type;
  const head = el("div", "entry-head");
  head.append(el("h4", "", record.name));
  const badge = el("span", "entry-badge", record.deprecated ? t("record.badge.deprecated") : record.type === "feedback" ? t("record.badge.feedback") : t("record.badge.project"));
  badge.dataset.kind = record.deprecated ? "deprecated" : record.type;
  head.append(badge);
  card.append(head);
  card.append(el("div", "entry-meta", `${formatDateTime(record.updatedAt)} · ${record.relativePath}`));
  card.append(el("div", "", record.description || t("detail.noDescription")));
  card.addEventListener("click", () => void openMemoryDetail(record.relativePath));
  return card;
}

function renderWorkspace() {
  const ws = state.workspace;
  renderProjectContext();
  const pe = ws?.projectEntries || [], fe = ws?.feedbackEntries || [];
  const de = [...(ws?.deprecatedProjectEntries || []), ...(ws?.deprecatedFeedbackEntries || [])];
  clearNode(projectEntriesEl);
  if (!pe.length) renderEmpty(projectEntriesEl, t("workspace.empty.project"));
  else pe.forEach((r) => projectEntriesEl.append(buildEntryCard(r)));
  feedbackEntriesSectionEl.classList.toggle("hidden", !fe.length && !state.workspaceQuery);
  clearNode(feedbackEntriesEl);
  if (!fe.length) renderEmpty(feedbackEntriesEl, t("workspace.empty.feedback"));
  else fe.forEach((r) => feedbackEntriesEl.append(buildEntryCard(r)));
  deprecatedEntriesSectionEl.classList.toggle("hidden", !de.length);
  clearNode(deprecatedEntriesEl);
  if (!de.length) renderEmpty(deprecatedEntriesEl, t("workspace.empty.deprecated"));
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
  const titleText = renderTraceI18nText(step.title, step.titleI18n, state.locale, TRACE_LOCALES) || step.title || `Step ${stepNum}`;
  const inputSummaryText = renderTraceI18nText(step.inputSummary, step.inputSummaryI18n, state.locale, TRACE_LOCALES);
  const outputSummaryText = renderTraceI18nText(step.outputSummary, step.outputSummaryI18n, state.locale, TRACE_LOCALES);

  const head = el("div", "tl-head");
  head.append(el("span", "tl-title", titleText));
  if (step.kind) head.append(el("span", "tl-badge", step.kind.toUpperCase()));
  head.append(el("span", "tl-expand-icon", "▼"));
  card.append(head);

  if (outputSummaryText || inputSummaryText) {
    card.append(el("div", "tl-summary", outputSummaryText || inputSummaryText || ""));
  }

  const body = el("div", "tl-body");

  const metaRow = el("div", "tl-meta-row");
  const statusCell = el("div", "tl-meta-cell");
  statusCell.append(el("div", "tl-meta-label", t("timeline.status")));
  statusCell.append(el("div", "tl-meta-value", step.status || "—"));
  metaRow.append(statusCell);
  const kindCell = el("div", "tl-meta-cell");
  kindCell.append(el("div", "tl-meta-label", t("timeline.stepType")));
  kindCell.append(el("div", "tl-meta-value", step.kind || "—"));
  metaRow.append(kindCell);
  body.append(metaRow);

  if (step.metrics && Object.keys(step.metrics).length) {
    body.append(el("div", "tl-section-title", t("timeline.metrics")));
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
    body.append(el("div", "tl-section-title", t("timeline.refs")));
    const table = el("table", "tl-kv-table");
    for (const [k, v] of Object.entries(step.refs)) {
      const tr = el("tr", "");
      tr.append(el("td", "", k));
      tr.append(el("td", "", Array.isArray(v) ? v.join(", ") : String(v)));
      table.append(tr);
    }
    body.append(table);
  }

  if (inputSummaryText) {
    body.append(el("div", "tl-section-title", t("timeline.inputSummary")));
    body.append(el("pre", "tl-code", inputSummaryText));
  }

  if (outputSummaryText) {
    body.append(el("div", "tl-section-title", t("timeline.outputSummary")));
    body.append(el("pre", "tl-code", outputSummaryText));
  }

  if (step.details && Array.isArray(step.details) && step.details.length) {
    body.append(el("div", "tl-section-title", t("timeline.details")));
    step.details.forEach((d) => {
      const detailLabel = renderTraceI18nText(d.label, d.labelI18n, state.locale, TRACE_LOCALES) || d.label;
      if (detailLabel) body.append(el("div", "tl-section-title", detailLabel));
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
    body.append(el("div", "tl-section-title", t("timeline.details")));
    body.append(el("pre", "tl-code", typeof step.details === "string" ? step.details : JSON.stringify(step.details, null, 2)));
  }

  if (step.promptDebug) {
    body.append(el("div", "tl-section-title", t("timeline.promptDebug", step.promptDebug.requestLabel || "")));
    if (step.promptDebug.systemPrompt) {
      body.append(el("div", "tl-section-title", t("timeline.systemPrompt")));
      body.append(el("pre", "tl-code", step.promptDebug.systemPrompt));
    }
    if (step.promptDebug.userPrompt) {
      body.append(el("div", "tl-section-title", t("timeline.userPrompt")));
      body.append(el("pre", "tl-code", step.promptDebug.userPrompt));
    }
    if (step.promptDebug.rawResponse) {
      body.append(el("div", "tl-section-title", t("timeline.rawResponse")));
      body.append(el("pre", "tl-code", step.promptDebug.rawResponse));
    }
    if (step.promptDebug.parsedResult !== undefined) {
      body.append(el("div", "tl-section-title", t("timeline.parsedResult")));
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
    containerEl.append(el("div", "empty-state", t("status.noSteps")));
    return;
  }
  steps.forEach((step, i) => containerEl.append(buildTimelineStep(i + 1, step)));
}

/* ── Recall (Case Traces) ── */

function renderRecallCaseList() {
  clearNode(recallCaseSelectEl);
  const def = el("option", "", t("trace.selectRecallCase")); def.value = ""; recallCaseSelectEl.append(def);
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
    recallMetaTableEl.append(buildKvCell(t("trace.meta.query"), r.query || "—"));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.session"), r.sessionKey || "—"));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.mode"), formatRecallRoute(r.retrieval?.intent || "auto")));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.reason"), formatRecallRoute(r.retrieval?.intent || "none")));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.status"), r.status || "—"));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.injected"), r.retrieval?.injected ? t("status.yes") : t("status.no")));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.started"), formatDateTime(r.startedAt)));
    recallMetaTableEl.append(buildKvCell(t("trace.meta.finished"), formatDateTime(r.finishedAt)));

    recallContextEl.textContent = r.retrieval?.contextPreview || t("status.noContext");

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
      recallToolEventsEl.textContent = t("status.noToolEvents");
    }

    recallReplyEl.textContent = r.assistantReply || t("status.noReply");

    const steps = r.retrieval?.trace?.steps || [];
    renderTimeline(recallStepsEl, steps);
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Index / Dream Trace Rendering ── */

function renderIndexTraceSelect() {
  clearNode(indexTraceSelectEl);
  const def = el("option", "", t("trace.selectIndexTrace")); def.value = ""; indexTraceSelectEl.append(def);
  state.indexTraces.forEach((t) => {
    const opt = el(
      "option",
      "",
      `${t.indexTraceId} · ${formatTraceTrigger(t.trigger)} · ${formatTraceDisplayStatus(t)} · ${formatDateTime(t.startedAt)}`,
    );
    opt.value = t.indexTraceId; indexTraceSelectEl.append(opt);
  });
  indexDetailEl.classList.add("hidden"); indexEmptyEl.classList.remove("hidden");
}

function renderDreamTraceSelect() {
  clearNode(dreamTraceSelectEl);
  const def = el("option", "", t("trace.selectDreamTrace")); def.value = ""; dreamTraceSelectEl.append(def);
  state.dreamTraces.forEach((t) => {
    const opt = el(
      "option",
      "",
      `${t.dreamTraceId} · ${formatTraceTrigger(t.trigger)} · ${formatTraceDisplayStatus(t)} · ${formatDateTime(t.startedAt)}`,
    );
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
    indexStepsEl.prepend(el(
      "div",
      "tl-summary",
      t("trace.sourceLabel", formatTraceTrigger(r.trigger), formatTraceDisplayStatus(r), t("trace.index.explanation")),
    ));
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

async function loadDreamDetail(traceId) {
  if (!traceId) { dreamDetailEl.classList.add("hidden"); dreamEmptyEl.classList.remove("hidden"); return; }
  try {
    const r = await fetchJson(`/api/memory/dream-traces/${encodeURIComponent(traceId)}`);
    dreamEmptyEl.classList.add("hidden"); dreamDetailEl.classList.remove("hidden");
    renderTimeline(dreamStepsEl, r.steps || []);
    dreamStepsEl.prepend(el(
      "div",
      "tl-summary",
      t("trace.sourceLabel", formatTraceTrigger(r.trigger), formatTraceDisplayStatus(r), t("trace.dream.explanation")),
    ));
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
  if (!state.projectPath) { setStatus(t("error.missingProjectPath"), "error"); return; }
  setStatus(t("status.refreshing"));
  try { await Promise.all([loadOverview(), loadSettings(), loadWorkspace(), loadUserSummary(), loadCaseTraces(), loadTraces()]); setStatus(DEFAULT_ACTIVITY); }
  catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Actions ── */

async function runAction(label, path, body = {}, options = {}) {
  closeSettingsDrawer();
  if (options.maintenance) setMaintenanceBusy(true);
  setStatus(t("status.running", label));
  try {
    const r = await fetchJson(path, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    setStatus(t("status.done", label));
    await loadDashboard();
    return r;
  } catch (err) {
    setStatus(err instanceof Error ? err.message : String(err), "error");
    throw err;
  } finally {
    if (options.maintenance) setMaintenanceBusy(false);
  }
}

function buildDownloadName(prefix) {
  return `${prefix}-${Date.now()}.json`;
}

function buildImportStatusMessage(successKey, response) {
  const warnings = Array.isArray(response?.warnings)
    ? response.warnings.filter((warning) => typeof warning === "string" && warning.trim())
    : [];
  return warnings.length > 0
    ? `${t(successKey)} ${warnings.join(" ")}`
    : t(successKey);
}

function parseBundleFileText(raw) {
  if (looksLikeHtmlDocument(raw)) {
    throw new Error(t("error.importFileIsHtml"));
  }
  const data = parseJsonText(raw);
  if (!data) {
    throw new Error(t("error.importFileInvalidJson"));
  }
  return data;
}

async function exportBundle(urls, downloadName, successKey) {
  try {
    const candidates = Array.isArray(urls) ? urls : [urls];
    let exportedText = null;
    let lastError = null;
    for (let index = 0; index < candidates.length; index += 1) {
      try {
        exportedText = await fetchBundleText(candidates[index]);
        break;
      } catch (error) {
        lastError = error;
        if (index === candidates.length - 1 || !isRecoverableLegacyRouteError(error)) {
          throw error;
        }
      }
    }
    if (typeof exportedText !== "string") {
      throw lastError || new Error(t("error.bundleDownloadInvalidJson"));
    }
    const blob = new Blob([exportedText], { type: "application/json" });
    const href = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = href;
    link.download = downloadName;
    link.click();
    URL.revokeObjectURL(href);
    setStatus(t(successKey));
  } catch (err) {
    setStatus(err instanceof Error ? err.message : String(err), "error");
  }
}

async function importBundle(file, urls, confirmKey, successKey) {
  if (!window.confirm(t(confirmKey))) return;
  try {
    const text = await file.text();
    const payload = parseBundleFileText(text);
    const candidates = Array.isArray(urls) ? urls : [urls];
    let response = null;
    let lastError = null;
    for (let index = 0; index < candidates.length; index += 1) {
      try {
        response = await postJsonExpectJson(candidates[index], payload);
        break;
      } catch (error) {
        lastError = error;
        if (index === candidates.length - 1 || !isRecoverableLegacyRouteError(error)) {
          throw error;
        }
      }
    }
    if (!response) {
      throw lastError || new Error(t("error.apiReturnedInvalidJson"));
    }
    setStatus(buildImportStatusMessage(successKey, response));
    await loadDashboard();
  } catch (err) {
    setStatus(err instanceof Error ? err.message : String(err), "error");
  }
}

async function exportCurrentProjectMemory() {
  await exportBundle(
    ["/api/memory/export/current-project", "/api/memory/export"],
    buildDownloadName("edgeclaw-memory-current-project"),
    "status.currentProjectMemoryExported",
  );
}

async function exportAllProjectsMemory() {
  await exportBundle(
    "/api/memory/export/all-projects",
    buildDownloadName("edgeclaw-memory-all-projects"),
    "status.allProjectsMemoryExported",
  );
}

async function clearCurrentProjectMemory() {
  if (!window.confirm(t("confirm.clearProject"))) return;
  await runAction(t("actions.clearProject"), "/api/memory/clear", { scope: "current_project" });
}

async function clearAllMemory() {
  if (!window.confirm(t("confirm.clearAll"))) return;
  await runAction(t("actions.clearAll"), "/api/memory/clear", { scope: "all_memory" });
}

async function rollbackLastDream() {
  if (!window.confirm(t("confirm.rollbackLastDream"))) return;
  closeSettingsDrawer();
  try {
    await runAction(
      t("actions.rollbackLastDream"),
      "/api/memory/dream/rollback-last",
      {},
      { maintenance: true },
    );
    setStatus(t("status.lastDreamRolledBack"));
  } catch {
    // runAction already surfaced the error
  }
}

async function editProjectMeta() {
  const c = state.workspace?.projectMeta || {};
  openEditorModal({
    kind: "project-meta",
    projectName: c.projectName || basename(state.projectPath),
    description: c.description || "",
    status: c.status || "in_progress",
  });
}

async function saveProjectMetaFromEditor() {
  const projectName = editorProjectNameEl.value.trim();
  if (!projectName) {
    showEditorError(t("editor.error.projectNameRequired"));
    editorProjectNameEl.focus();
    return;
  }

  const payload = {
    projectName,
    description: editorProjectDescriptionEl.value,
    status: editorProjectStatusEl.value || "in_progress",
  };

  try {
    editorSaveBtn.disabled = true;
    await fetchJson("/api/memory/project-meta", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: payload,
    });
    closeEditorModal();
    setStatus(t("status.projectMetaUpdated"));
    await loadDashboard();
  } catch (err) {
    showEditorError(err instanceof Error ? err.message : String(err));
  } finally {
    editorSaveBtn.disabled = false;
  }
}

async function saveMemoryEntryFromEditor(session) {
  const name = editorMemoryNameEl.value.trim();
  if (!name) {
    showEditorError(t("editor.error.memoryNameRequired"));
    editorMemoryNameEl.focus();
    return;
  }

  try {
    editorSaveBtn.disabled = true;
    await fetchJson("/api/memory/memory/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: {
        action: "edit_entry",
        id: session.record.relativePath,
        name,
        description: editorMemoryDescriptionEl.value,
      },
    });
    closeEditorModal();
    setStatus(t("status.memoryUpdated"));
    await loadWorkspace();
    if (state.memoryDetailOpen) await openMemoryDetail(session.record.relativePath);
  } catch (err) {
    showEditorError(err instanceof Error ? err.message : String(err));
  } finally {
    editorSaveBtn.disabled = false;
  }
}

async function handleEditorSubmit(event) {
  event.preventDefault();
  const session = state.editorSession;
  if (!session) return;
  if (session.kind === "project-meta") {
    await saveProjectMetaFromEditor();
    return;
  }
  await saveMemoryEntryFromEditor(session);
}

async function saveSettings() {
  const autoIndexIntervalMinutes = getCurrentSettingsFieldMinutes("autoIndex");
  const autoDreamIntervalMinutes = getCurrentSettingsFieldMinutes("autoDream");
  try {
    await fetchJson("/api/memory/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: { autoIndexIntervalMinutes, autoDreamIntervalMinutes },
    });
    setStatus(t("status.settingsSaved"));
    await loadSettings();
    syncSettingsInputsFromState();
  } catch (err) { setStatus(err instanceof Error ? err.message : String(err), "error"); }
}

/* ── Event Bindings ── */

boardNavTabs.forEach((b) => b.addEventListener("click", () => { closeSettingsDrawer(); state.memoryDetailOpen = false; setActivePage(b.dataset.page || "project"); }));
traceSubTabs.forEach((b) => b.addEventListener("click", () => setActiveTraceTab(b.dataset.trace || "recall")));
recallCaseSelectEl.addEventListener("change", () => void loadRecallDetail(recallCaseSelectEl.value));
indexTraceSelectEl.addEventListener("change", () => void loadIndexDetail(indexTraceSelectEl.value));
dreamTraceSelectEl.addEventListener("change", () => void loadDreamDetail(dreamTraceSelectEl.value));
settingsToggleBtn.addEventListener("click", () => { if (state.settingsOpen) closeSettingsDrawer(); else openSettingsDrawer(); });
settingsCloseBtn.addEventListener("click", () => closeSettingsDrawer());
saveSettingsBtn.addEventListener("click", () => void saveSettings());
settingAutoIndexUnitEl.addEventListener("change", () => handleSettingsUnitChange("autoIndex"));
settingAutoDreamUnitEl.addEventListener("change", () => handleSettingsUnitChange("autoDream"));
editorCloseBtn.addEventListener("click", () => closeEditorModal());
editorCancelBtn.addEventListener("click", () => closeEditorModal());
editorFormEl.addEventListener("submit", (event) => void handleEditorSubmit(event));
refreshBtn.addEventListener("click", () => void loadDashboard());
indexBtn.addEventListener("click", () => void runAction(t("actions.index"), "/api/memory/index/run", {}, { maintenance: true }));
dreamBtn.addEventListener("click", () => void runAction(t("actions.dream"), "/api/memory/dream/run", {}, { maintenance: true }));
exportCurrentProjectBtn.addEventListener("click", () => void exportCurrentProjectMemory());
importCurrentProjectBtn.addEventListener("click", () => importCurrentProjectInput.click());
rollbackLastDreamBtn?.addEventListener("click", () => void rollbackLastDream());
exportAllProjectsBtn.addEventListener("click", () => void exportAllProjectsMemory());
importAllProjectsBtn.addEventListener("click", () => importAllProjectsInput.click());
clearProjectBtn.addEventListener("click", () => void clearCurrentProjectMemory());
clearAllBtn.addEventListener("click", () => void clearAllMemory());

workspaceSearchEl.addEventListener("input", () => { state.workspaceQuery = workspaceSearchEl.value.trim(); if (state.activePage === "project") void loadWorkspace(); });
workspaceSearchEl.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); state.workspaceQuery = workspaceSearchEl.value.trim(); void loadWorkspace(); } });
workspaceSearchBtn.addEventListener("click", () => { state.workspaceQuery = workspaceSearchEl.value.trim(); void loadWorkspace(); });

importCurrentProjectInput.addEventListener("change", async (e) => {
  const file = e.target.files?.[0]; if (!file) return;
  try { await importBundle(file, ["/api/memory/import/current-project", "/api/memory/import"], "confirm.importCurrentProject", "status.currentProjectMemoryImported"); }
  finally { importCurrentProjectInput.value = ""; }
});

importAllProjectsInput.addEventListener("change", async (e) => {
  const file = e.target.files?.[0]; if (!file) return;
  try { await importBundle(file, "/api/memory/import/all-projects", "confirm.importAllProjects", "status.allProjectsMemoryImported"); }
  finally { importAllProjectsInput.value = ""; }
});

detailBackBtn.addEventListener("click", () => closeMemoryDetailPage());
detailCloseBtn.addEventListener("click", () => closeDetailDrawer());
settingsModalEl.addEventListener("click", (e) => { if (e.target === settingsModalEl) closeSettingsDrawer(); });
appScrimEl.addEventListener("click", () => { closeSettingsDrawer(); closeDetailDrawer(); closeEditorModal(); });

/* ── Init ── */

applyStaticTranslations();
renderUserSummary();
renderRecallCaseList();
renderIndexTraceSelect();
renderDreamTraceSelect();
setActivePage("project");
applyTraceTabChrome();
void loadDashboard();
