# EdgeClaw Memory Integration Implementation Plan

> **2026-04-15 当前有效口径（以此为准）**
>
> - `当前打开的 EdgeClaw workspace = 唯一顶层 project`。
> - 这个 current project 下本来就应该有多条 `Project/*.md` 和 `Feedback/*.md` 记忆文件；多条文件是正确设计，不是异常。
> - 当前有效布局是 `current-project-v2/memory/` 下的：
>   - `project.meta.md`
>   - `Project/*.md`
>   - `Feedback/*.md`
>   - `MEMORY.md`
>   - `global/User/user-profile.md`
> - `tmp`、多 project shortlist、`Project Clarification Required`、`projects/_tmp/*`、`projects/project_*/project.meta.md` 都已经退出当前 runtime 主流程。
> - 本文中凡是提到旧 `tmp/formal project` 流程、`single-workspace-v1` 或“把同一 project 收敛成单条 `Project/*.md`”的内容，都属于历史中间方案，已被本次 current-project 重新校准取代。

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `ClawXMemory-main` 的记忆能力从 OpenClaw 插件形态改为 EdgeClaw 内建能力，替换现有旧记忆路径，并在 `claudecodeui` 中提供一级 `memory` 主 Tab 与看板入口。

**Architecture:** 方案采用“共享 core + 双端适配”结构。把 `ClawXMemory-main/clawxmemory/src/core/*` 与看板静态资源抽离为本地共享包 `edgeclaw-memory-core`，由 `claude-code-main` 负责会话捕获、召回注入、Agent 工具与旧记忆下线，由 `claudecodeui` 负责 `/api/memory/*`、静态看板承载和主 Tab 入口；一期通过 feature flag 冷启动切换，不迁移旧记忆数据。

**Tech Stack:** TypeScript, Bun, Node.js, Express, React, SQLite, markdown-first file memory, iframe-hosted static dashboard.

---

## 1. 背景与结论

### 1.1 业务目标

- 把记忆能力从 OpenClaw 插件迁移为 EdgeClaw 原生能力，减少运行时耦合。
- 用新记忆系统替换 EdgeClaw 当前的旧记忆方案，避免双写、双召回、双入口。
- 复用现有 ClawXMemory 看板能力，同时把入口并入 EdgeClaw 主界面。

### 1.2 可行性结论

- 结论：技术上可行，复杂度中高，推荐按一期方案推进。
- 可直接复用：`ClawXMemory-main/clawxmemory/src/core/*`、`src/message-utils.ts`、`ui-source/*`。
- 不建议复用：`ClawXMemory-main/clawxmemory/src/index.ts`、`src/hooks.ts`、`src/prompt-section.ts`、`src/runtime.ts`、`src/tools.ts`，因为这些文件绑定了 OpenClaw plugin-sdk 运行时。
- 一期最稳妥的路径不是“兼容插件壳”，而是“抽 core + 重做 EdgeClaw 适配层”。

### 1.3 一期范围

- 保留能力：`memory_overview`、`memory_list`、`memory_search`、`memory_get`、`memory_flush`、`memory_dream`。
- 新增 UI：一级 `memory` 主 Tab。
- 数据策略：冷启动，不迁移旧记忆数据。
- 发布策略：feature flag 控制，新记忆启用后必须彻底关闭旧记忆 owner。

### 1.4 一期非目标

- 不做旧记忆数据迁移工具。
- 不重写 ClawXMemory 看板为原生 React 面板。
- 不保留 OpenClaw 插件运行时作为生产依赖。
- 不在一期内做多项目并行召回策略改造，继续保持 single-project recall。

## 2. 现状盘点

### 2.1 `ClawXMemory-main` 可复用资产

- 领域核心：`ClawXMemory-main/clawxmemory/src/core/*`
- 消息标准化：`ClawXMemory-main/clawxmemory/src/message-utils.ts`
- 看板资源：`ClawXMemory-main/clawxmemory/ui-source/index.html`
- 看板逻辑：`ClawXMemory-main/clawxmemory/ui-source/app.js`
- 看板样式：`ClawXMemory-main/clawxmemory/ui-source/app.css`

### 2.2 `claude-code-main` 当前旧记忆入口

- `claude-code-main/src/memdir/paths.ts`
- `claude-code-main/src/constants/prompts.ts`
- `claude-code-main/src/QueryEngine.ts`
- `claude-code-main/src/query/stopHooks.ts`
- `claude-code-main/src/services/extractMemories/*`
- `claude-code-main/src/services/autoDream/*`
- `claude-code-main/src/utils/attachments.ts`

### 2.3 `claudecodeui` 当前 UI 与服务入口

- 服务端挂载：`claudecodeui/server/index.js`
- 现有 API 路由模式：`claudecodeui/server/routes/taskmaster.js`
- Tab 类型：`claudecodeui/src/types/app.ts`
- Tab 状态：`claudecodeui/src/hooks/useProjectsState.ts`
- 主内容切换：`claudecodeui/src/components/main-content/view/MainContent.tsx`
- Tab 头部：`claudecodeui/src/components/main-content/view/subcomponents/MainContentTabSwitcher.tsx`
- 标题逻辑：`claudecodeui/src/components/main-content/view/subcomponents/MainContentTitle.tsx`

## 3. 目标架构

### 3.1 共享包

- 新建本地包：`edgeclaw-memory-core/`
- 责任：
  - 承载 ClawXMemory core 代码
  - 暴露 `EdgeClawMemoryService`
  - 暴露 prompt section builder
  - 暴露 dashboard 静态资源

### 3.2 `claude-code-main` 适配层

- 新增 `EdgeClawMemoryService` 单例或按 workspace 复用实例。
- 在回答前执行 memory gate + retrieve，并将结果以 system context 注入。
- 在回答后捕获 user / assistant / tool turn，写入 L0 并触发 flush/dream。
- 重新声明 `memory_*` Agent tools。
- 在 feature flag 开启时关闭旧 `memdir`、旧 `MEMORY.md`、旧 relevance recall、旧后台抽取任务。

### 3.3 `claudecodeui` 适配层

- 新增 `/api/memory/*` 路由。
- 新增一级 `memory` 主 Tab。
- 同域托管 ClawXMemory dashboard 静态资源。
- 在 `memory` Tab 内用 iframe 承载 dashboard。
- iframe 需要显式传递鉴权 token 与当前项目路径，否则 dashboard 内部 `fetch("./api/...")` 无法通过现有 Bearer 鉴权。

### 3.4 数据与发布

- 新记忆独立目录，独立 SQLite 控制平面。
- 默认目录建议：`~/.edgeclaw/memory/workspaces/<workspace-hash>/`
- 一期冷启动。
- 使用 `EDGECLAW_MEMORY_ENABLED` 一类的 feature flag 控制切流。

## 4. 风险与应对

- 风险：新旧记忆并存导致双写、双召回、提示污染。
  - 应对：以 feature flag 为单一切换点，启用新记忆时让 `isAutoMemoryEnabled()` 明确返回 false。
- 风险：静态 dashboard 无法继承 Web UI 的 Bearer 鉴权。
  - 应对：改造 `ui-source/app.js`，统一从 query string 读取 `token` 与 `projectPath` 并为请求补齐 Header。
  - 补充：静态资源请求（`app.js`、`app.css`、图片）不会自动继承 iframe URL 的 query string，需要服务端额外允许从 `Referer` 里的 dashboard token 恢复鉴权。
- 风险：一期不迁移旧数据会让已积累记忆不可见。
  - 应对：在规划书和发布说明中明确“一期冷启动”边界，避免误导业务方。
- 风险：`QueryEngine` 接入点不当会造成 system prompt 回归风险。
  - 应对：把新召回作为附加 context 插入，保留原有 prompt 拼装顺序，不在一期重构主 prompt 管线。
- 风险：后台 flush / dream 的时机不稳定。
  - 应对：一期先提供显式工具和 API，后台自动化仅做最小集成。

## 5. 里程碑与工期

- M1 核心抽离与基础适配：3-5 个工作日
- M2 `claude-code-main` 记忆替换与工具接入：5-7 个工作日
- M3 `claudecodeui` API、看板承载与主 Tab：4-6 个工作日
- M4 回归、灰度、上线文档：3-4 个工作日
- 总计：
  - 2 人并行：约 3-4 周
  - 1 人串行：约 5-6 周

## 6. 验收标准

- 新记忆启用后，旧记忆不再写入、不再参与 prompt、不再参与 UI。
- 空仓冷启动时，capture、flush、dream、retrieve、dashboard 展示全部可用。
- `memory_*` tools 的行为与 ClawXMemory 原插件保持语义一致。
- `memory` 主 Tab 可直达，看板可读取当前项目数据。
- `chat / files / shell / git / tasks` 不发生功能回归。

## 7. 实施任务拆解

### Task 1: 抽离共享 memory core 包

**Files:**
- Create: `edgeclaw-memory-core/package.json`
- Create: `edgeclaw-memory-core/tsconfig.base.json`
- Create: `edgeclaw-memory-core/tsconfig.json`
- Create: `edgeclaw-memory-core/src/index.ts`
- Create: `edgeclaw-memory-core/src/service.ts`
- Create: `edgeclaw-memory-core/src/core/*`
- Create: `edgeclaw-memory-core/src/message-utils.ts`
- Create: `edgeclaw-memory-core/ui-source/*`

**Steps:**
1. 复制 `ClawXMemory-main/clawxmemory/src/core/*` 与 `src/message-utils.ts` 到新包。
2. 为新包补齐 TypeScript 构建入口，输出目录使用 `lib/`，避免落到根 `.gitignore` 已忽略的 `dist/`。
3. 在 `src/service.ts` 封装 `MemoryRepository`、`HeartbeatIndexer`、`ReasoningRetriever`、`DreamRewriteRunner`。
4. 暴露 `captureTurn`、`retrieveContext`、`flush`、`dream`、`overview`、`list/get/search`、`act`、`export/import/clear`。
5. 暴露 `buildMemoryRecallSystemContext()` 和 EdgeClaw 版 prompt helper。

**Verification:**
- 运行：`cd edgeclaw-memory-core && npm install && npm run build`
- 预期：生成 `edgeclaw-memory-core/lib/*`，无类型错误。

### Task 2: 接入 feature flag 并关闭旧记忆 owner

**Files:**
- Modify: `claude-code-main/src/memdir/paths.ts`
- Modify: `claude-code-main/src/constants/prompts.ts`
- Modify: `claude-code-main/src/query/stopHooks.ts`
- Modify: `claude-code-main/src/QueryEngine.ts`

**Steps:**
1. 新增 `isEdgeClawMemoryEnabled()` 判断。
2. 在 `isAutoMemoryEnabled()` 中加入互斥逻辑，启用新记忆时直接关闭旧记忆。
3. 让旧的后台 extract/dream hook 在新记忆开启时跳过。
4. 在 prompt 构造阶段切换为新记忆的 prompt section。

**Verification:**
- 运行：`cd claude-code-main && bun x tsc --noEmit`
- 预期：无类型错误，旧记忆开关逻辑可编译通过。

### Task 3: 在 `QueryEngine` 注入召回与 turn capture

**Files:**
- Create: `claude-code-main/src/services/edgeclawMemory/index.ts`
- Create: `claude-code-main/src/services/edgeclawMemory/service.ts`
- Modify: `claude-code-main/src/QueryEngine.ts`

**Steps:**
1. 为当前 workspace 创建或复用 `EdgeClawMemoryService` 实例。
2. 在回答前根据当前 query 和 recent messages 执行 `retrieveContext()`。
3. 将召回结果作为附加 system context 注入，不打乱原 prompt 主体。
4. 在 turn 完成后捕获本轮 user / assistant / tool transcript，写入 `captureTurn()`。
5. 保证异常路径和中断路径不会重复 capture。

**Verification:**
- 运行：`cd claude-code-main && bun x tsc --noEmit`
- 手测：启动 CLI 后进行一轮对话，检查新 memory 目录是否出现 L0/索引产物。

### Task 4: 平移 `memory_*` Agent tools

**Files:**
- Create: `claude-code-main/src/tools/MemoryOverviewTool/MemoryOverviewTool.ts`
- Create: `claude-code-main/src/tools/MemoryListTool/MemoryListTool.ts`
- Create: `claude-code-main/src/tools/MemorySearchTool/MemorySearchTool.ts`
- Create: `claude-code-main/src/tools/MemoryGetTool/MemoryGetTool.ts`
- Create: `claude-code-main/src/tools/MemoryFlushTool/MemoryFlushTool.ts`
- Create: `claude-code-main/src/tools/MemoryDreamTool/MemoryDreamTool.ts`
- Modify: `claude-code-main/src/tools.ts`
- Modify: `claude-code-main/src/constants/tools.ts`
- Modify: `claude-code-main/src/types/tools.ts`

**Steps:**
1. 以 `buildTool(...)` 模式声明 6 个新工具。
2. 工具语义对齐 ClawXMemory 原插件输出。
3. 工具内部统一调用 `EdgeClawMemoryService`，不要直接操作仓储层。
4. 对错误消息、参数校验、无数据场景做兼容处理。

**Verification:**
- 运行：`cd claude-code-main && bun x tsc --noEmit`
- 手测：逐个调用 `memory_overview / memory_list / memory_search / memory_get / memory_flush / memory_dream`。

### Task 5: 新增 `claudecodeui` memory API 与 dashboard 承载

**Files:**
- Create: `claudecodeui/server/routes/memory.js`
- Modify: `claudecodeui/server/index.js`
- Create: `claudecodeui/server/services/memoryService.js` 或同类封装文件
- Create: `claudecodeui/server/public/memory/*` 或等效静态托管目录

**Steps:**
1. 参照 `taskmaster` 路由模式新增 `/api/memory/*`。
2. API 覆盖：`overview`、`settings`、`index/run`、`dream/run`、`snapshot`、`memory/list`、`memory/get`、`memory/actions`、`projects`、`tmp`、`cases`、`index-traces`、`dream-traces`、`export`、`import`、`clear`。
3. 服务端按 `projectPath` 选择当前 workspace 对应的 memory service。
4. 同域托管 dashboard 静态资源。
5. 改造 dashboard `app.js`，为所有请求补齐 `Authorization` 和 `projectPath`。

**Verification:**
- 运行：`cd claudecodeui && npm run typecheck`
- 运行：`cd claudecodeui && npm run build`
- 手测：直接打开 memory dashboard 路由，接口能正常返回 200。

### Task 6: 新增一级 `memory` 主 Tab

**Files:**
- Modify: `claudecodeui/src/types/app.ts`
- Modify: `claudecodeui/src/hooks/useProjectsState.ts`
- Modify: `claudecodeui/src/components/main-content/view/MainContent.tsx`
- Modify: `claudecodeui/src/components/main-content/view/subcomponents/MainContentTabSwitcher.tsx`
- Modify: `claudecodeui/src/components/main-content/view/subcomponents/MainContentTitle.tsx`
- Create: `claudecodeui/src/components/main-content/view/memory/MemoryPanel.tsx`

**Steps:**
1. 将 `AppTab` 扩展为包含 `'memory'`。
2. 把 `memory` 加入内建 Tab 列表，而不是 plugin tab。
3. 新建 `MemoryPanel`，内部用 iframe 承载同域 dashboard。
4. 透传 Bearer token、当前 `projectPath`、必要主题参数。
5. 确保空项目、未选项目、iframe 加载失败时有降级提示。

**Verification:**
- 运行：`cd claudecodeui && npm run typecheck`
- 手测：切换到 `memory` Tab，可看到 dashboard，项目切换后数据随之变化。

### Task 7: 管理操作、导入导出与 traces 对齐

**Files:**
- Modify: `edgeclaw-memory-core/src/service.ts`
- Modify: `claudecodeui/server/routes/memory.js`
- Modify: `claudecodeui/server/public/memory/app.js` 或实际托管文件

**Steps:**
1. 透出 `edit`、`deprecate`、`restore`、`archive_tmp`、`delete`、`export`、`import`、`clear`。
2. 透出 `case`、`index`、`dream` trace 查询接口。
3. 操作后统一刷新 retriever transient state，避免陈旧缓存。

**Verification:**
- 手测：编辑、废弃、恢复、导出、导入、清空、trace 查看全部可用。

### Task 8: 回归、灰度与上线文档

**Files:**
- Create: `docs/plans/edgeclaw-memory-rollout-checklist.md`
- Create: `docs/plans/edgeclaw-memory-test-matrix.md`
- Modify: `README.md` 或相关运维文档入口

**Steps:**
1. 编写测试矩阵，覆盖冷启动、正常采集、召回路由、工具对齐、管理操作、UI 对齐、互斥回归、主产品回归。
2. 明确 feature flag 开关、灰度顺序、回滚条件。
3. 记录“启用新记忆前必须关闭旧记忆 owner”的上线前检查项。

**Verification:**
- 预发布环境完成一轮完整回归。
- 具备一键关闭 `EDGECLAW_MEMORY_ENABLED` 的回滚能力。

## 8. 测试矩阵

- 空仓冷启动：无历史数据时 capture、flush、dream、retrieve、dashboard 全链路通过。
- 正常对话采集：业务轮次写入 L0；命令噪声、空回复、纯系统消息不入库。
- Recall 路由：`none / user / project_memory` 正常切换。
- Tool 对齐：`memory_*` 参数、返回、错误语义与原插件一致。
- 管理操作：编辑、废弃、恢复、归档、导入、导出、清空都作用于真实 file-memory。
- UI 对齐：overview、project、tmp、user、trace 五类视图均可达。
- 互斥回归：启用新记忆后，旧 `memdir` 不再写入、不再召回、不再影响 UI。
- 主产品回归：`chat / files / shell / git / tasks` 不受影响。

## 9. 推荐决策

- 建议立项，按一期方案执行。
- 先完成共享 core 与旧记忆互斥，再做 UI，看板接入放在后半段。
- 在拿到业务确认前，不要启动“旧数据迁移”支线，否则范围会明显膨胀。

## 10. 交付物清单

- 一份共享 memory core 包
- 一套 `claude-code-main` 新记忆服务与工具
- 一套 `claudecodeui` memory API 与一级主 Tab
- 一套看板静态资源承载方案
- 一份测试矩阵
- 一份上线与回滚清单

## 11. 实施进展更新

### 2026-04-15 当前状态

- 已完成：
  - 新建 `edgeclaw-memory-core/`，已抽离 `ClawXMemory-main/clawxmemory/src/core/*`、`src/message-utils.ts` 与 `ui-source/*`。
  - 新增 `edgeclaw-memory-core/src/service.ts`，已封装 `EdgeClawMemoryService`，对外暴露 `captureTurn`、`retrieveContext`、`flush`、`dream`、`overview`、`list/get/search`、`act`、`export/import/clear`。
  - `claude-code-main` 已接入 `EDGECLAW_MEMORY_ENABLED` feature flag，并在 `claude-code-main/src/memdir/paths.ts` 中关闭旧 auto-memory owner。
  - `claude-code-main/src/constants/prompts.ts` 已切换为新 memory prompt section。
  - `claude-code-main/src/QueryEngine.ts` 已接入回答前 recall 注入，以及回答后 turn capture；turn capture 成功后会 opportunistic 地按配置触发后台 flush/dream 检查。
  - `claude-code-main` 已新增 `memory_overview`、`memory_list`、`memory_search`、`memory_get`、`memory_flush`、`memory_dream` 六个工具，并加入工具注册。
  - `claudecodeui/server/routes/memory.js` 已新增 `/api/memory/*` 路由。
  - `claudecodeui/server/index.js` 已新增 `/memory-dashboard` 同域静态承载，并挂载 `/api/memory`。
  - `claudecodeui/server/middleware/auth.js` 已补齐 dashboard 静态资源鉴权兜底，可从 `Referer` 中恢复 iframe token，避免 `app.js` / `app.css` / 图片子资源 401。
  - `claudecodeui` 前端已新增一级 `memory` 主 Tab，并通过 iframe 承载现有 dashboard。
  - dashboard 已改造为透传 `token` 与 `projectPath`，请求已切到 `/api/memory/*`。

### 已记录的实现调整

- 调整：新系统当前实现为“L0 capture + 手动 flush/dream”。
  说明：当前已完成回答后采集，并把数据写入待索引的 L0 队列；同时补了一个 opportunistic 的后台维护触发：在 turn capture 成功后，会按 `autoIndexIntervalMinutes / autoDreamIntervalMinutes` 与当前概览状态决定是否异步执行 flush/dream。这里不是独立常驻 scheduler，而是“有新 turn 时顺带触发”的最小实现。

- 调整：新 memory extractor 采用 OpenAI-compatible 配置输入，但已补齐 OpenClaw 配置回退。
  说明：当前 `edgeclaw-memory-core` 的模型解析优先级为：
  - 显式传入的 `EdgeClawMemoryService({ llm })`
  - `EDGECLAW_MEMORY_PROVIDER / MODEL / BASE_URL / API_KEY / API_TYPE`
  - `~/.openclaw/openclaw.json`
  - `OPENAI_MODEL / OPENAI_BASE_URL / OPENAI_API_KEY`
  其中 `~/.openclaw/openclaw.json` 会读取 `agents.defaults.model.primary` 与 `models.providers.*`，并自动映射 provider、model、baseUrl、apiKey、apiType；`modelRef` 带 `provider/model` 前缀的情况也已修正为正确解析。

- 调整：`claude-code-main/src/types/tools.ts` 本轮未修改。
  说明：当前工具接入不依赖新增公共 tool type，注册和可用性控制分别落在 `src/tools.ts` 与 `src/constants/tools.ts` 即可满足。

### 当前验证结果

- 已完成验证：
  - `cd edgeclaw-memory-core && npm run build`
  - `cd claudecodeui && npm run typecheck`
  - `cd claudecodeui && npm run build`
  - `node --check claudecodeui/server/routes/memory.js`
  - `node --check claudecodeui/server/services/memoryService.js`
  - `node --check claudecodeui/server/index.js`
  - `node --check claudecodeui/server/middleware/auth.js`
  - `cd claude-code-main && npx tsc --noEmit -p tsconfig.json --ignoreDeprecations 6.0 | rg 'src/services/edgeclawMemory|src/tools/Memory(Overview|List|Search|Get|Flush|Dream)Tool|src/tools/MemoryTool'`
    说明：该过滤验证没有再报出 `src/services/edgeclawMemory/*` 与新增 memory tool 文件的错误。
  - 已在独立临时 HOME 下启动 `claudecodeui` 生产服务实例，完成一轮黑盒链路：
    - 注册临时用户并登录
    - 把当前仓库路径作为项目接入
    - `clear -> import -> overview -> settings -> list -> get -> actions -> projects -> tmp -> snapshot -> export`
    - 校验 `/memory-dashboard/index.html?token=...&projectPath=...` 可访问
    - 校验在**没有 Authorization header** 的情况下，仅凭 `Referer` 中的 dashboard token 即可成功读取 `/memory-dashboard/app.js` 与 `/memory-dashboard/app.css`
  - 已在新的独立临时 HOME 下复制 `~/.openclaw/openclaw.json`，完成第二轮黑盒回归：
    - 直接以 `EdgeClawMemoryService` 预置 2 条 L0 session，验证待索引状态
    - 启动 `claudecodeui` 生产服务并访问主页面 `/`，返回 `200`
    - 注册临时用户并把当前仓库路径作为项目接入，返回 `200`
    - `GET /api/memory/overview` 在 flush 前返回 `pendingSessions: 2`
    - `POST /api/memory/index/run` 返回 `200`，结果为 `capturedSessions: 2`、`writtenFiles: 1`、`writtenProjectFiles: 1`
    - `POST /api/memory/dream/run` 返回 `200`，结果为 `reviewedFiles: 1`、`rewrittenProjects: 1`、`deletedFiles: 1`
    - `GET /api/memory/overview` 在 dream 后返回 `formalProjectCount: 1`、`tmpTotalFiles: 0`
    - 再次校验 `/memory-dashboard/index.html` 以及无 `Authorization` header 的 `/memory-dashboard/app.js`、`/memory-dashboard/app.css`，均返回 `200`

- 黑盒测试结论：
  - 通过：memory API 的基础管理面、数据导入导出、分组展示、tmp 视图、entry 编辑都可用。
  - 通过：dashboard 文档和静态资源在鉴权开启时可正常加载，说明 iframe token 透传 + `Referer` 兜底方案有效。
  - 通过：在**不额外设置 `EDGECLAW_MEMORY_*` 环境变量**、仅复制 `~/.openclaw/openclaw.json` 的条件下，`POST /api/memory/index/run` 与 `POST /api/memory/dream/run` 均成功，说明 OpenClaw 配置回退已经生效。
  - 观察：本轮种子数据经 flush 后先写入 tmp 项目记忆，dream 再将其提升为正式项目；这符合当前“先 capture/index、再由 dream 做整理提升”的一期实现路径。

### 2026-04-15 第二轮真实对话黑盒回归

- 目标：
  - 用自然语言会话而不是导入包来验证 `capture -> index -> recall -> dream`。
  - 样本覆盖：用户长期偏好、项目定义、一期范围、项目风险。

- 本轮输入样本：
  - 用户偏好：
    - `请记住我的长期偏好：默认使用中文输出；如果有结论，请先给结论再给细节；不要改动我的 .gitignore 文件。`
    - `再记一条长期信息：我更关心项目进度、风险和上线阻塞点，不需要泛泛而谈。`
  - 项目记忆：
    - `请记住这个项目：项目名叫 EdgeClaw Memory Integration，别名 edgeclaw-memory。目标是把 ClawXMemory 插件能力直接内建进 EdgeClaw。`
    - `请记住当前一期范围：替换旧记忆；保留 memory_overview、memory_list、memory_search、memory_get、memory_flush、memory_dream；并且在 UI 新增一级 memory tab。`
    - `请记住当前风险：现在 recall 只从 formal project 读取，所以刚 flush 出来的 tmp 项目记忆，在 dream 之前很可能无法跨会话召回。`

- 实际结果：
  - `flush` 成功：
    - `capturedSessions: 5`
    - `writtenFiles: 3`
    - `writtenProjectFiles: 2`
    - `writtenFeedbackFiles: 1`
    - `userProfilesUpdated: 1`
  - `flush` 后状态：
    - `userProfileCount: 1`
    - `tmpTotalFiles: 3`
    - `formalProjectCount: 0`
  - `dream` 成功：
    - `reviewedFiles: 4`
    - `rewrittenProjects: 2`
    - `deletedFiles: 2`
    - `profileUpdated: true`
  - `dream` 后状态：
    - `formalProjectCount: 2`
    - `tmpTotalFiles: 1`

- recall 验证：
  - 通过：显式用户问题 `请回忆我的个人长期偏好：默认语言、回答结构、以及不能改动的文件分别是什么？` 走到了 `route=user`，成功注入 `global/User/user-profile.md`。
  - 通过：无关问题 `给我解释一下 TypeScript 的泛型。` 走到了 `route=none`，没有注入记忆。
  - 通过：`dream` 之后，以下三类项目问题都能稳定选中 `EdgeClaw Memory Integration`：
    - 按正式项目名提问
    - 按项目别名 `edgeclaw-memory` 提问
    - 先在 recent user message 提到项目名，再问“这个项目怎么样”
  - 观察：`dream` 之前项目 recall 会进入 `route=project_memory`，但因为没有 formal project，会注入 `Project Clarification Required`，不会加载项目文件。这验证了当前实现确实依赖 formal project 才能做跨会话项目 recall。

- 本轮新增发现的问题：
  - 问题 1：项目范围被错误拆成了另一个 formal project。
    - 现象：`请记住当前一期范围...` 这条信息没有并入 `EdgeClaw Memory Integration`，而是被索引成了新的项目 `Memory System Update`。
    - 结果：`dream` 后形成了两个 formal project：
      - `EdgeClaw Memory Integration`
      - `Memory System Update`
    - 影响：按 `EdgeClaw Memory Integration` 提问“一期保留哪些 memory tools”时，recall 只选中了 `projects/project_2db05e7585/Project/current-stage.md`，拿不到真正记录工具清单的文件。
  - 问题 2：项目风险样本被 index 直接丢弃。
    - 现象：`sessionKey=project-3` 的 index trace 显示 `turn_classified -> classified=discarded`，最终 `stored=0`。
    - 影响：`这个项目当前最大的风险是什么？` 在 `dream` 后虽然能选中正确项目，但 recall 中没有风险信息。
  - 问题 3：user profile 抽取不完整。
    - 现象：最终 `global/User/user-profile.md` 只保留了“默认使用中文输出”和“不要改动 .gitignore”，丢失了“先给结论再给细节”。
    - 影响：用户回答风格偏好在长期记忆里不完整。
  - 问题 4：部分用户长期偏好被落成 tmp feedback，而不是用户画像。
    - 现象：`我更关心项目进度、风险和上线阻塞点，不需要泛泛而谈` 被存成了 `projects/_tmp/Feedback/reporting-rule-*.md`，没有归入 global user profile。
    - 影响：这类跨项目的沟通偏好不会稳定出现在 `route=user` 的 recall 结果里。
  - 问题 5：混合型用户问题容易误走 `project_memory`。
    - 现象：`之后回复我时，应该使用什么语言？结论怎么组织？还有什么文件不能乱动？` 这类问题本质上是在问用户偏好，但本轮被 gate 判成了 `project_memory`，并附带了 `Project Clarification Required`。
    - 影响：用户侧体验会显得“答非所问”，尤其是在还没有 formal project 的早期阶段。

### 2026-04-15 第三轮修复与回归结果

- 已完成的修复：
  - 修复：索引器现在在分类时会同时拿到：
    - 当前批次前序消息
    - 工作区中已存在的 formal/tmp 项目 identity hints
    结果：后续的“当前一期范围”“当前风险”这类跟进句，不再凭空发散成新的项目名。
  - 修复：`llm-extraction` 增加了用户长期偏好启发式。
    - 新覆盖：默认语言、回答结构、`.gitignore` 边界、`更关注进度/风险/阻塞点`、`不需要泛泛而谈`
    - 结果：这些内容现在优先进入 `user-profile`，而不是误落到 tmp feedback。
  - 修复：`file memory gate` 新增本地 heuristic。
    - 结果：明显是在问用户偏好的 query，会直接走 `route=user`，不再误判成 `project_memory`。
  - 修复：`recall` 新增 tmp project fallback。
    - 结果：在 `dream` 之前，如果 formal project 还不存在，但 tmp 项目 identity 已经唯一可判定，项目 recall 可以直接从 tmp 项目组取数，不再强制进入 clarification。

- 第三轮回归结论：
  - 用户偏好链路：
    - 通过：`默认使用中文输出`
    - 通过：`如果有结论，先给结论再给细节`
    - 通过：`不要改动我的 .gitignore 文件`
    - 通过：`更关注项目进度、风险和上线阻塞点`
    - 通过：`不需要泛泛而谈`
    - 结果：以上内容已稳定进入 `global/User/user-profile.md`
  - index 链路：
    - 通过：`project-2` 与 `project-3` 不再被拆成独立项目名，三条项目记忆全部落在 `EdgeClaw Memory Integration` 这一 tmp project identity 下。
    - 通过：`project-3` 不再 `classified=discarded`，而是成功写成 tmp project memory。
  - recall 链路：
    - 通过：用户偏好问题现在稳定走 `route=user`。
    - 通过：无关问题仍然走 `route=none`。
    - 通过：`dream` 前提问 `EdgeClaw Memory Integration 一期要保留哪些 memory tools？`，现在已经可以直接命中 tmp project identity：
      - `resolvedProjectId = tmp:edgeclaw memory integration`
      - 无 `Project Clarification Required`
      - recall 内容中已包含 memory tools 清单
    - 通过：`dream` 后提问 `这个项目当前最大的风险是什么？`，现在可以稳定命中 formal project，且 recall 内容包含风险信息。
  - dream 链路：
    - 通过：tmp 项目组只整理为一个 formal project：
      - `EdgeClaw Memory Integration`
    - 通过：不再额外生成错误的 `Memory System Update` formal project。

- 已关闭的问题：
  - 已关闭：项目范围被错误拆成 `Memory System Update`
  - 已关闭：项目风险样本被 index 丢弃
  - 已关闭：user profile 丢失“先给结论再给细节”
  - 已关闭：`更关注进度/风险/阻塞点` 被误归类为 tmp feedback
  - 已关闭：混合型用户问题误走 `project_memory`
  - 已关闭：`dream` 前 formal project 不存在时，项目 recall 强制 clarification

- 尚未完成验证：
  - `claude-code-main` 全量类型检查未能达到 green。

- 未完成原因：
  - 当前机器没有 `bun`，因此无法直接执行 `claude-code-main` 的既有验证链。
  - 在补装依赖并用 `npx tsc --noEmit -p tsconfig.json --ignoreDeprecations 6.0` 验证后，`claude-code-main` 暴露出大量仓库既有类型问题，主要集中在 feature-gated 模块缺失、`MACRO` 全局、SDK 类型漂移等，与本次 memory 集成不是一一对应关系。
  - `claudecodeui` 构建已通过，但 Vite 仍输出仓库现有的 CSS minify warning 和 chunk size warning；当前未在本轮继续处理这类与 memory 集成无关的问题。

### 2026-04-15 单工作区模型中间方案记录（已被 current-project 重新校准取代）

- 本轮已落地的架构变更：
  - `edgeclaw-memory-core` 已切换到单工作区数据目录：
    - `~/.edgeclaw/memory/workspaces/<workspace-hash>/single-workspace-v1/memory/`
  - 新布局已生效：
    - `memory/MEMORY.md`
    - `memory/Project/*.md`
    - `memory/Feedback/*.md`
    - `memory/global/User/user-profile.md`
  - 旧的 `projects/_tmp/*`、`projects/project_*/project.meta.md` 不再进入新 runtime 主流程。

- 本轮已完成的行为改造：
  - `flush` 现在直接写当前 workspace 的 `Project/` / `Feedback/`，不再经过 `_tmp` 暂存层。
  - `retrieveContext` 已改为只在当前 workspace 内召回项目记忆，不再做：
    - project shortlist
    - tmp fallback
    - formal project selection
    - `Project Clarification Required`
  - `dream` 已改为单工作区整理模式：
    - 不再创建 formal project
    - 不再生成或注入 `project.meta.md`
    - 当前版本只做当前 workspace 记忆的重复项整理、文件合并与 manifest 修复
  - `memory_list` 已移除 `projectId`
  - `memory_search` 已移除：
    - `selectedProjectId`
    - `disambiguationRequired`
    - “No formal project was selected...” warning
  - `memory_actions` 主流程已移除：
    - `archive_tmp`
    - `edit_project_meta`
  - `claudecodeui` memory API 主流程已移除：
    - `GET /api/memory/projects`
    - `GET /api/memory/tmp`
  - `claudecodeui` 新增：
    - `GET /api/memory/workspace`
  - dashboard 已重写为单 workspace 页面，不再显示：
    - project list
    - tmp 视图
    - archive tmp
    - edit project meta

- 新一轮验证结果：
  - `edgeclaw-memory-core`：
    - 通过：`npm run build`
  - `claudecodeui`：
    - 通过：`npm run typecheck`
    - 通过：`npm run build`
    - 观察：构建仍带仓库既有 CSS minify warning 和 chunk size warning，未在本轮处理
  - 单工作区服务级黑盒：
    - 通过：`capture -> flush -> retrieve -> dream -> retrieve`
    - 通过：写盘文件仅出现：
      - `MEMORY.md`
      - `Project/*.md`
      - `global/User/user-profile.md`
    - 通过：未再出现：
      - `projects/_tmp/...`
      - `projects/project_*/project.meta.md`
    - 通过：`dream` 前提问“这个项目一期要保留哪些 memory tools？”可直接召回当前 workspace 项目记忆
    - 通过：`dream` 前提问“这个项目当前最大的风险是什么？”可直接召回当前 workspace 项目记忆
    - 通过：以上两类问题在 `dream` 后继续可用，且无 `Project Clarification Required`

- 当前已记录的实现观察：
  - 观察：在单工作区模型下，抽取器仍可能生成多个不同标题的项目记忆文件，例如：
    - `Project/记忆模块一期重构-*.md`
    - `Project/当前打开项目-*.md`
  - 说明：这些文件现在都属于同一个 workspace 记忆空间，不再代表多个内部 project，也不会触发第二层 project 选择。
  - 结论：这属于“同一 workspace 内的多个项目记忆条目”，不是旧模型里的“多个 formal/tmp project”。当前不阻塞单工作区主链路。

### 2026-04-15 小红书文案场景黑盒结果

- 场景输入：
  - 项目背景：小红书账号孵化，一期主题是“初夏通勤穿搭”，目标是产出 10 篇可复用爆文模板
  - 项目阶段：当前处于选题和标题模板设计阶段，下一步整理 20 个对标标题
  - 项目风险：内容太像广告会降低收藏率
  - 交付规则：先给 5 个标题，再给正文，再给封面文案，语气不要太像硬广
  - 用户偏好：默认中文、先给结论再给细节、不要改 `.gitignore`

- 通过项：
  - `flush` 后写盘路径仍然只落在：
    - `MEMORY.md`
    - `Project/*.md`
    - `Feedback/*.md`
    - `global/User/user-profile.md`
  - 未出现：
    - `projects/_tmp/...`
    - `projects/project_*/project.meta.md`
  - 项目问题召回：
    - “这个小红书项目当前最大的风险是什么？” 能直接命中 workspace 项目记忆
    - “这个小红书项目现在处于什么阶段，下一步做什么？” 在 `dream` 前后都能直接命中
  - 协作规则召回：
    - “你之后给我这个项目文案时应该怎么组织输出？” 能单独命中 `Feedback/delivery-rule-*.md`
    - “给这个项目写文案时要避免什么语气？” 能命中交付规则和项目风险约束
  - 用户偏好召回：
    - “之后默认用什么语言回复？回答结构怎么安排？有什么文件不能乱动？” 正确走 `route=user`

- 新增观察：
  - 观察 1：`route=user` 当前会把 `global/User/user-profile.md` 注入两次
    - 现象：召回上下文中既有 user base block，又再次把同一文件作为 selected file 注入
    - 影响：不会导致错误答案，但会造成 context 冗余
    - 后续状态：该问题已在 current-project 重新校准中修复，现状是 `global/User/user-profile.md` 只注入 1 次
  - 观察 2：同一 current project 下出现多条 `Project/*.md`
    - 现象：本轮生成了多条项目进展记忆，例如：
      - `Project/小红书账号孵化-*.md`
      - `Project/选题和标题模板设计项目-*.md`
    - 重新校准结论：这不是“被拆成两个 project”，而是“同一个 current project 下记录了多条项目进展记忆”，符合 ClawXMemory 原始设计。
    - 后续关注点：只需要继续提升这些条目的整理质量，不需要把它们强行收敛成单个 `Project/*.md` 文件。

- 改动范围核对：
  - 本轮代码改动仍然集中在 memory 相关区域：
    - `edgeclaw-memory-core/*`
    - `claudecodeui/server/routes/memory.js`
    - `claude-code-main/src/tools/Memory*`
    - 实施报告文档
  - 未触碰 `chat / files / shell / git / tasks` 主流程代码。

### 2026-04-15 Current-Project 重新校准落地结果（当前有效）

- 已完成的 current-project 校准：
  - 已恢复 `project.meta.md`，并重新纳入当前 runtime 主流程。
  - 已恢复当前 project 元数据编辑能力：
    - `EdgeClawMemoryService.getProjectMeta()`
    - `EdgeClawMemoryService.updateProjectMeta()`
    - `memory_actions -> edit_project_meta`
    - `/api/memory/project-meta`
  - 当前有效数据目录为：
    - `~/.edgeclaw/memory/workspaces/<workspace-hash>/current-project-v2/memory/`
  - 当前有效文件布局为：
    - `project.meta.md`
    - `Project/*.md`
    - `Feedback/*.md`
    - `MEMORY.md`
    - `global/User/user-profile.md`
  - `flush` 直接写当前 project 的 `Project/` / `Feedback/`，不再经过 tmp。
  - `recall` 保留 `none / user / project_memory` 三路 gate，但 `project_memory` 只面向当前 project：
    - 不再做 project shortlist
    - 不再做 tmp fallback
    - 不再做 formal project selection
    - 不再返回 `Project Clarification Required`
  - `recall` 现在会把 `project.meta.md` 与 `global/User/user-profile.md` 一起注入上下文，并修复了 `user-profile.md` 重复注入。
  - `dream` 现在只整理当前 project 的多条 `Project/Feedback` 记忆，并更新 `project.meta.md` 与 `user-profile.md`；不会创建第二层 project，也不会生成 tmp/formal promotion。
  - dashboard 已改成单 current-project 视图，显示并可编辑：
    - Current Project Meta
    - Project Memory
    - Feedback Memory
    - User Profile
    - Trace
    - Settings

- 本轮补充修复：
  - 已修复：Dream / extractor 提示词里的旧 `tmp/formal project` 语义，已统一改为 current-project 语义。
  - 已修复：`project.meta.md` 不再吸收 `current-stage`、`reporting-rule` 这类单条记忆文件名作为 alias。
  - 已修复：`buildProjectMetaSeed()` 与 `upsertCandidate()` 现在只保留真正的 project alias，不再把 `Project/*.md` 条目名回填到 project meta。

- 最新验证结果：
  - `edgeclaw-memory-core`
    - 通过：`npm run typecheck`
    - 通过：`npm run build`
  - `claudecodeui`
    - 通过：`npm run typecheck`
    - 通过：`npm run build`
    - 说明：仍有仓库既有 CSS minify warning 和 chunk size warning，本轮未处理
  - 服务级真实黑盒：
    - 输入样本覆盖：
      - current project 定义
      - current project 阶段 / 风险 / 下一步
      - current project 反馈规则
      - global user 偏好
    - `flush` 结果：
      - `capturedSessions: 4`
      - `writtenFiles: 3`
      - `writtenProjectFiles: 2`
      - `writtenFeedbackFiles: 1`
      - `userProfilesUpdated: 1`
    - `dream` 结果：
      - `reviewedFiles: 3`
      - `rewrittenProjects: 1`
      - `deletedFiles: 3`
      - `status: success`
    - `project.meta.md`：
      - 已稳定生成
      - `projectName = EdgeClaw Memory Integration`
      - `aliases` 不再混入 `current-stage`
    - recall：
      - `这个项目当前最大的风险是什么？`：
        - `route = project_memory`
        - `project.meta.md` 已注入
        - `dream` 前后都能召回当前 project 风险
      - `默认用什么语言回复？还有什么文件不能乱动？`：
        - `route = user`
        - `global/User/user-profile.md` 只注入 1 次
        - `默认使用中文回复` 与 `.gitignore` 边界都能召回
    - 写盘隔离：
      - 未再出现 `projects/_tmp/...`
      - 未再出现 `projects/project_*/project.meta.md`

- 当前结论：
  - current-project 重新校准已经落地完成。
  - 现在的 memory 结构和语义已经重新对齐到你最初描述的 ClawXMemory 模型：
    - 一个当前 project
    - 一个 `project.meta.md`
    - 多条 `Project/*.md`
    - 多条 `Feedback/*.md`
    - 一个 global user profile
  - 当前改动仍然限定在 memory 相关模块，没有扩散到 `chat / files / shell / git / tasks` 主流程。

### 2026-04-16 Memory Dashboard 空状态修复

- 问题复盘：
  - `Memory` Tab 外层 `MemoryPanel` 之前把 `auth-token` 当成必需条件；如果本地 UI 处于 `CLOUDCLI_DISABLE_LOCAL_AUTH` 免登录模式，`localStorage` 里没有 token，iframe 就不会加载。
  - dashboard 自身 `ui-source/app.js` 也把“缺少 token”当成致命错误，因此即使后端允许免登录，也只会看到 `Memory dashboard is unavailable...` 占位，不会进入真实 dashboard。

- 本轮修复：
  - `claudecodeui/src/components/main-content/view/memory/MemoryPanel.tsx`
    - 改为：只要当前项目有 `projectPath` 就直接生成 iframe URL。
    - `token` 变成可选参数；有 token 时附加 `token=...`，没有 token 也允许进入 dashboard。
  - `edgeclaw-memory-core/ui-source/app.js`
    - 改为：仅 `projectPath` 缺失才阻止初始化。
    - `headers()` 只在 token 存在时附加 `Authorization`，避免发送空的 `Bearer `。
    - `fetchJson()` / `fetchBlob()` 对 `401/403` 统一转成页内“需要登录后才能访问当前项目的 Memory Dashboard”提示。
    - 初始加载前先渲染概览、Project Meta、Project / Feedback / User / Trace 的空状态，这样空仓或鉴权失败时也保留真实 dashboard 外壳。

- 本轮影响范围：
  - 只触达 memory UI 入口和 dashboard 前端静态资源。
  - 未修改 memory 数据模型、recall/index/dream API、`chat / files / shell / git / tasks` 主流程。

- 本轮验证：
  - `claudecodeui`
    - 通过：`npm run typecheck`
    - 通过：`npm run build`
  - `edgeclaw-memory-core`
    - dashboard 静态脚本改动已通过 `claudecodeui` 构建链路验证
  - 预期用户体验：
    - 免登录模式下，即使 `localStorage.auth-token` 为空，选中项目后也会直接进入真实 dashboard。
    - 空仓时显示 dashboard 内的空状态，而不是外层 “dashboard unavailable” 占位。

### 2026-04-16 Memory Tab 白页补充修复

- 现象：
  - 在 `http://localhost:5173` 开发环境里，`Memory` Tab 不再显示外层占位，但 iframe 仍是一整块白页。

- 原因：
  - `claudecodeui` 的 Vite dev server 只代理了 `/api`、`/ws`、`/shell`，没有代理 `/memory-dashboard`。
  - 因此 iframe 在 `5173` 下请求 `/memory-dashboard/index.html?...` 时，拿到的是 Vite 自己的前端壳或代理错误，而不是真正的 dashboard HTML。
  - 同时，本地开发后端 `3001` 一度未运行，也会让 dev proxy 返回 `ECONNREFUSED`，表现成空白页面。

- 修复：
  - `claudecodeui/vite.config.js`
    - 新增 `/memory-dashboard -> http://<serverPort>` 代理。
  - 重启本地开发链路：
    - `vite` 前端重新启动
    - `node server/index.js` 后端重新启动

- 验证：
  - `http://127.0.0.1:5173/memory-dashboard/index.html?projectPath=...`
    - 返回 `200`
    - HTML 标题为 `EdgeClaw Memory`
  - `http://127.0.0.1:5173/api/memory/overview?projectPath=...`
    - 返回 `200`
    - 返回正常 overview JSON，而不是代理错误或白页

### 2026-04-16 Memory Dashboard 视觉回归到旧版 ClawXMemory 风格

- 背景：
  - 现有 current-project dashboard 的功能可用，但视觉语言过于临时化，和旧版 ClawXMemory 的导航层级、信息密度、卡片风格差距较大。
  - 第一轮仅做“风格参考”仍然和旧版差距较大；这次改为直接对齐旧版的布局结构和交互层级。
  - 目标不是改 memory 逻辑，而是把 dashboard 外壳尽量收敛回旧版 ClawXMemory 的视觉框架。

- 本轮改动：
  - `edgeclaw-memory-core/ui-source/index.html`
    - 进一步重做为更贴近旧版截图的结构：
      - 左侧窄导航 `nav-rail`
      - 顶部 `ClawXMemory + activity` 头部
      - 顶部右侧操作按钮 `刷新 / 索引同步 / 记忆 Dream / 最近索引`
      - 左下角 `设置` 触发器与弹层
      - 主内容区单列看板
      - 右侧详情改为默认隐藏的抽屉，而不是常驻侧栏
    - 保留 current-project 模型下的三个一级视图：
      - 项目记忆
      - 用户画像
      - 记忆追踪
  - `edgeclaw-memory-core/ui-source/app.css`
    - 视觉基调继续收敛到旧版 ClawXMemory 的浅灰蓝系统、细边框、轻阴影、紧凑导航和扁平操作按钮。
    - 移除了上一版过重的当前 project 侧栏、概览卡常驻区和过大的标题层级。
    - 项目卡片、反馈卡片、trace 卡片统一改成接近旧版的轻量卡片语言。
  - `edgeclaw-memory-core/ui-source/app.js`
    - 新增当前页面状态切换：`project / user / trace`
    - 调整为旧版交互模式：
      - info 状态写到顶部 activity text，而不是常驻横幅
      - 设置入口改为左下角弹层
      - 详情改为右侧抽屉，默认隐藏
      - `feedback / deprecated / manifest` 这些附加区块在无内容时不再强占主视觉
    - 现有 `Project / Feedback / Deprecated / User / Trace / Detail` 数据逻辑保持不变，只调整承载容器和默认显隐

- 保持不变：
  - 不改 memory API
  - 不改 recall / index / dream 行为
  - 不改 current-project 数据模型
  - 不改 `chat / files / shell / git / tasks`

- 验证：
  - `node --check edgeclaw-memory-core/ui-source/app.js` 通过
  - `claudecodeui: npm run build` 通过
  - `/memory-dashboard/index.html` 返回的新 HTML 已包含：
    - `ClawXMemory`
    - `nav-rail`
    - `settingsToggleBtn`
    - `detailDrawer`
    - `项目记忆 / 用户画像 / 记忆追踪`

### 2026-04-16 Claude 自定义模型支持

- 背景：
  - 当前 memory 逻辑只接在 `Claude Code -> claude-code-main -> QueryEngine` 这条链上。
  - 但 UI 的 Claude 模型列表写死为 `sonnet / opus / haiku ...`，新会话默认会发 `sonnet`。
  - 同时 `claude-code-main/proxy.ts` 会把未知模型也改写成 `anthropic/...`，导致自部署模型 `qwen3.5-35b` 无法被 Claude 链路使用，表现为会话发送后长时间无响应。

- 本轮改动：
  - `claudecodeui/server/utils/claude-runtime-config.js`
    - 新增 Claude 运行时模型解析器，读取服务端 `ANTHROPIC_MODEL`，生成：
      - `defaultModel`
      - `availableModels`
    - 内置 Claude 模型保留不变；若环境变量模型不在内置列表中，则追加为一个自定义可选项。
  - `claudecodeui/server/index.js`
    - 新增只读接口：
      - `GET /api/agents/runtime-config`
    - 返回当前运行时 Claude 默认模型和可选模型列表。
  - `claudecodeui/server/claude-sdk.js`
    - Claude SDK 默认模型改为读取运行时配置，不再硬编码回退到 `sonnet`。
  - `claudecodeui/server/routes/commands.js`
    - `/model` 命令输出的 Claude 可用模型和默认模型改为使用运行时配置，避免和 UI 不一致。
  - `claudecodeui/src/components/chat/hooks/useChatProviderState.ts`
    - 前端启动时读取 `/api/agents/runtime-config`
    - Claude 模型下拉来源改为运行时配置
    - 若服务端配置了自定义默认模型，则会覆盖旧的 `localStorage.claude-model=sonnet`，避免新会话继续发错模型
  - `claudecodeui/src/components/chat/view/ChatInterface.tsx`
  - `claudecodeui/src/components/chat/view/subcomponents/ChatMessagesPane.tsx`
  - `claudecodeui/src/components/chat/view/subcomponents/ProviderSelectionEmptyState.tsx`
    - 将 Claude 下拉改为消费运行时模型列表
  - `claude-code-main/proxy.ts`
    - 模型映射规则调整为：
      - 已知 Claude 别名继续映射到 `anthropic/...`
      - 显式上游模型名保持不变
      - 未知模型名原样透传给上游

- 验证：
  - `claudecodeui: npm run build` 通过
  - `claudecodeui: npm run typecheck` 通过
  - `GET /api/agents/runtime-config`
    - 返回：
      - `defaultModel = qwen3.5-35b`
      - `availableModels` 包含内置 Claude 模型和自定义 `qwen3.5-35b`
  - `POST http://127.0.0.1:18080/v1/messages` with `model=qwen3.5-35b`
    - 返回 `200`
    - Anthropic 兼容响应中的 `model` 为 `qwen3.5-35b`
  - `POST http://127.0.0.1:18080/v1/messages` with `model=sonnet`
    - 仍返回上游 `404`
    - 说明 proxy 不再把未知模型改写成 `anthropic/<unknown>`，错误可见性符合预期

- 当前结论：
  - Claude 链路已经具备使用自定义模型的能力，`qwen3.5-35b` 可以作为 `Claude Code` 的实际执行模型。
  - 下一步可直接回到黑盒测试：
    - 新建 `Claude Code` 会话
    - 发送真实对话样本
    - 验证 `QueryEngine -> capture -> flush/index -> dashboard` 是否真正打通

### 2026-04-16 Claude Code 无响应修复

- 背景：
  - 在 `Claude Code + qwen3.5-35b` 已能识别模型后，前端仍表现为“消息发出后无回复”。
  - 这轮排查确认不是 memory 逻辑问题，而是 Claude 执行链本身存在两个 Bun / 本地源码兼容问题。

- 实际根因：
  - `claude-code-main/src/tools.ts`
    - 非 bare 模式初始化工具表时，会调用 `getSendMessageTool()`
    - 该函数使用 `require()` 加载 `SendMessageTool`
    - Bun 将 `SendMessageTool` 视为 async module，导致本地 `claude-code-main` 在工具初始化阶段直接中断
    - 结果表现为：
      - `Claude Code` 会话无回复
      - `QueryEngine` 实际没有进入正常对话轮次
  - `claudecodeui/server/claude-sdk.js`
    - SDK 子进程需要显式继承 `ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL / ANTHROPIC_MODEL`
    - 同时需要清掉冲突的 OAuth token 环境变量
    - 否则本地源码链可能回退到错误的认证分支

- 本轮改动：
  - `claude-code-main/src/tools.ts`
    - 将 `SendMessageTool` 从 `require()` 改为静态 `import`
    - 保留 `TeamCreateTool / TeamDeleteTool` 的 lazy require，不扩大改动范围
  - `claudecodeui/server/claude-sdk.js`
    - 继续使用运行时 `ANTHROPIC_*` 配置构建 Claude 子进程环境
    - 设置 `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1`
    - 当存在 API Key / Base URL 时，移除：
      - `ANTHROPIC_AUTH_TOKEN`
      - `CLAUDE_CODE_OAUTH_TOKEN`
    - 对本地 `claude-code-main` 子进程附加 `--print`
  - `claude-code-main/src/main.tsx`
    - 为 `stream-json` 输入增加 `PassThrough` 桥接，避免后续初始化阶段直接依赖原始 stdin 对象
    - 这不是最终根因，但保留为 SDK 输入路径的稳健性修正

- 验证：
  - `bun --eval import { getAllBaseTools } ...`
    - 现在可正常返回 built-in tools 列表，不再报：
      - `require() async module ... SendMessageTool`
  - 非 bare 本地 CLI：
    - `bun run ... cli.tsx -p --output-format stream-json --verbose --model qwen3.5-35b '你好，请只回复测试成功。'`
    - 返回：
      - `system:init`
      - `assistant`
      - `result: success`
  - 非 bare `stream-json` 控制流：
    - `initialize` 能正常返回 `control_response`
    - `initialize + user` 能正常返回 `assistant/result`
  - `claudecodeui/server/claude-sdk.js`
    - 在加载 `server/load-env.js` 的真实服务端环境下，`queryClaudeSDK()` 已能跑通
    - 事件序列为：
      - `session_created`
      - `text`
      - `status`
      - `complete`
  - 本地服务：
    - 已重启 `claudecodeui` server，当前监听：
      - `http://localhost:3001`
    - `5173` 前端和 `18080` Claude proxy 保持在线

- 当前结论：
  - `Claude Code -> 本地 claude-code-main -> QueryEngine -> qwen3.5-35b` 主聊天链路已恢复可用。
  - 之前“无法对话”不是 memory 没接上，而是本地 Claude 执行链在工具初始化阶段被 Bun 兼容问题提前打断。
  - 下一步可以重新回到真实黑盒：
    - 在 UI 新建 `Claude Code` 会话
    - 发送可记忆样本
    - 验证 `capture -> 手动索引 -> recall -> dashboard`

### 2026-04-16 Claude 用户消息重复显示修复

- 背景：
  - Claude 会话恢复可用后，前端聊天区出现“同一条用户输入显示两次”。
  - 典型现象：
    - 新会话发送 `你好`，右侧出现两条 `你好`
    - 已有会话发送 `北京今天天气如何`，右侧出现两条相同气泡

- 实际根因：
  - 前端 `useChatComposerState` 在发送时会先做一次 optimistic append，本地立即插入用户消息。
  - 同时 `claudecodeui/server/claude-sdk.js` 会把 Claude SDK 实时流里回放的 `role=user` 消息继续经 `claudeAdapter.normalizeMessage()` 转发给前端。
  - 结果就是：
    - 本地 optimistic 一条
    - Claude 实时回放再来一条
    - 两者时间戳不同、id 不同，因此不会被 session store 按 id 去重

- 本轮改动：
  - `claudecodeui/server/providers/claude/adapter.js`
    - 为 `normalizeMessage()` 增加 `includeUserText` 选项
    - 默认仍为 `true`
    - 这样历史消息加载、session 回放仍会保留用户消息
  - `claudecodeui/server/claude-sdk.js`
    - Claude 实时 WebSocket 流调用 adapter 时改为：
      - `includeUserText: false`
    - 只屏蔽 Claude 实时流里的用户文本回放
    - 不影响：
      - assistant 文本
      - tool_use / tool_result
      - status / complete / permission 事件
      - session 历史加载

- 验证：
  - 服务级 `queryClaudeSDK()` 回归：
    - 事件序列变为：
      - `session_created`
      - `text(role=assistant)`
      - `status`
      - `complete`
    - `userTextCount=0`
    - `assistantTextCount=1`
  - `claudecodeui`：
    - `npm run typecheck` 通过

- 当前结论：
  - Claude 聊天区重复显示问题根因已明确，是“前端 optimistic append + Claude 实时 user replay”叠加，不是 session store 或 memory 捕获导致。
  - 修复后：
    - 历史消息仍完整保留用户气泡
    - 实时对话只保留前端本地那一条用户气泡
    - 不会再因为 Claude SDK 回放而出现第二条重复用户消息
