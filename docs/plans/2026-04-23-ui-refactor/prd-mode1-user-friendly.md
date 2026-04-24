# edgeclaw UI 重构 PRD

## 方案一：OpenAI 风格的 User-Friendly 版本

- 文档状态：Draft v1
- 日期：2026-04-23
- 适用范围：`claudecodeui`
- 视觉方案：Mode 1（shadcn / ChatGPT 风）
  - `/Users/miwi/edgeclaw-opc/docs/plans/2026-04-23-ui-refactor/prototype/shadcn.html`
- 参考文档：
  - `docs/plans/2026-04-23-ui-refactor/ui-modes-research.md`
  - `docs/plans/2026-04-23-ui-refactor/prd.md`

---

## 1. 产品一句话

把当前 edgeclaw 做成一个更像 ChatGPT、但保留开发工作台能力的 AI coding workspace：用户可以用更低认知负担开始对话、切换项目、查看文件、运行 shell、处理 git、查看 memory、使用 always-on 自动化与 dashboard。

---

## 2. 为什么要做

当前产品功能已经很强，但使用门槛偏高，主要问题不是能力不够，而是能力组织方式不够友好：

- 顶部 tab 较多，第一次进入时很难理解先点哪里
- Sidebar 更像文件管理器，不像以对话和项目为中心的 AI 工作台
- 同一屏里有很多“开发者视角”的结构，但缺少“任务开始点”
- 用户知道系统很强，却不知道“下一步该怎么开始”

这次重构不追求推翻能力，而是把现有能力重新编排成一个更自然的使用路径：

1. 先开始对话
2. 再进入项目上下文
3. 需要时再展开 Files / Shell / Git / Memory / Tasks 等能力

核心目标是把“功能很多”变成“入口清楚、上手简单、进阶不受限”。

---

## 3. 产品目标

### 3.1 核心目标

1. 让新用户第一次打开时就知道如何开始
2. 让高频用户更快进入“项目 + 对话 +代码操作”的连续流
3. 保留现有核心能力，不因为 UI 变简单而削弱产品深度
4. 统一视觉与交互，减少“工具拼接感”

### 3.2 成功标准

- 新用户进入产品后，能在 10 秒内理解主入口是“新建对话 / 进入项目”
- 项目内常见任务可以在一个连续工作流中完成：聊天 -> 看文件 -> 开 shell -> 看 git -> 回到聊天
- 大多数用户不需要理解“系统内部结构”，也能完成主要工作
- 老用户迁移后，现有核心能力仍然可用，不需要重新学习业务逻辑

---

## 4. 目标用户

### 4.1 主要用户

- 日常用 Claude Code / agent workflow 做开发的人
- 需要围绕项目持续对话、持续改代码、持续验证的人
- 既想要 ChatGPT 式简单入口，又需要 IDE / terminal / git 能力的人

### 4.2 次要用户

- 需要用 always-on 做定时巡检、发现问题、生成后续执行计划的人
- 需要通过 memory 和记忆面板理解项目上下文的人
- 需要 dashboard 看路由、成本、使用情况的人

---

## 5. 设计原则

### 5.1 先对话，后工具

用户最自然的起点不是“选一个 tab”，而是“我想让 AI 帮我做什么”。首页和项目页都要优先给出 composer。

### 5.2 默认简单，进阶不藏

默认界面尽量像 ChatGPT 一样干净；Files / Shell / Git / Memory / Tasks 等能力依然保留，但应在需要时展开，而不是一开始堆到用户面前。

### 5.3 项目是一等公民

项目不只是一个目录，也应该是一个带上下文的工作空间：有说明、有最近聊天、有相关工具入口。

### 5.4 视觉克制，信息明确

采用方案一：shadcn / ChatGPT 风。轻边框、清晰层级、低动画、亮暗双主题，重点是“可信、易读、易用”。

---

## 6. 视觉与交互方向

本次采用 **方案一：仿 OpenAI 模式（shadcn / ChatGPT 风）**。

### 6.1 视觉关键词

- 干净
- 克制
- 轻量
- 可读性高
- 熟悉的对话体验

### 6.2 视觉特征

- `zinc` 系中性色为主
- Inter 字体
- 用户消息与助手消息层级清楚
- 轻边框、轻阴影、低干扰
- 桌面端和移动端都优先保证清晰可读

### 6.3 为什么选它

- 和当前技术栈最兼容，落地风险最低
- 最容易承载“对话优先”的产品心智
- 对新用户最友好
- 不会因为风格过重影响长时间使用

---

## 7. 产品范围

本次 PRD 不是做一个新产品，而是把现有能力重构成更 user-friendly 的体验。

### 7.1 本次纳入的现有能力

- Chat 对话
- Projects / Sessions 管理
- Files
- Shell
- Git
- Memory
- Always-On
- Dashboard
- Tasks（当本地已启用且已安装时显示）
- Plugins
- Settings / Auth / Appearance / API / Router 等设置能力

### 7.2 本次不做的事

- 不重写 Claude CLI 或会话存储格式
- 不重做后端执行链路
- 不改变 memory 核心 schema
- 不做复杂团队协作、多用户权限体系
- 不追求“视觉惊艳”，重点是提升易用性

---

## 8. 新信息架构

采用更贴近 ChatGPT 的结构，把“开始工作”放在最前面。

### 8.1 总体布局

桌面端采用三段式体验：

1. 左侧 Sidebar：导航与上下文切换
2. 中间主区：聊天或项目主页
3. 右侧工作面板：Files / Shell / Git

其中，中间主区永远是主角；右侧工作面板是配合聊天工作的辅助区。

### 8.2 Sidebar 结构

Sidebar 建议按以下顺序组织：

1. Logo / 折叠
2. `+ New chat`
3. 全局工具
4. Projects
5. Chats
6. Footer / Settings

### 8.3 全局工具

为了控制复杂度，Sidebar 中只保留最重要的全局工具：

- Memory
- Always-On
- Tasks
- Dashboard

Files / Shell / Git 不再作为全局主导航，而是变成右侧工作面板。

---

## 9. 核心体验设计

## 9.1 Home：一个能立刻开始的首页

首页目标不是展示系统有多复杂，而是帮助用户立刻开始。

首页应包含：

- 显眼的 `New chat` 入口
- 最近使用的 Projects
- 最近 Chats
- 简单的推荐动作，例如：
  - 继续上次对话
  - 进入某个项目
  - 查看 Memory
  - 打开 Dashboard

### 首页文案原则

- 少解释系统结构
- 多引导“下一步动作”
- 空态要有明确行动建议

示例空态文案：

> Start with a new chat, or open a project to work with its code, files, and tools.

---

## 9.2 General Chat：最轻的开始方式

General Chat 是没有项目绑定的自由对话。

适用场景：

- 临时问答
- 思路讨论
- 让 AI 帮忙起草
- 不想先选项目时先开始聊

### 用户价值

- 降低第一次使用门槛
- 让用户像用 ChatGPT 一样先开口
- 减少“我得先配置很多东西才能开始”的心理阻力

### 关键要求

- `+ New chat` 永远清晰可见
- 新对话打开后立即可输入
- 对话创建后进入标准 chat 视图
- 如果后续用户决定与某个项目相关，应支持把这段对话归入项目

---

## 9.3 Projects：把“目录”升级成“工作空间”

项目不应该只是一个路径，而应该是一个可进入、可理解、可持续使用的工作上下文。

### Project Landing 页要回答三个问题

1. 这个项目是什么
2. 我可以立刻做什么
3. 最近在这个项目里发生了什么

### Project Landing 页内容

- 项目标题与简短说明
- 主 composer
- 最近聊天
- 相关工具入口
- 项目说明 / instructions 摘要

### 用户价值

- 进入项目后不再“空白”
- 用户知道可以直接发起项目内对话
- 用户能快速找回上下文

---

## 9.4 Chat：对话始终是主流程

无论是 General Chat 还是 Project Chat，聊天主界面都应该优先服务“连续完成任务”。

### 聊天界面要求

- 消息阅读舒适，长时间使用不疲劳
- 输入框位置稳定，发送动作明确
- 文件引用、工具展开、模型或权限设置都不应抢主流程
- 当 AI 生成内容较长时，排版应清楚，代码块和 markdown 易读

### 设计取向

- 更像 ChatGPT，不像杂乱控制台
- 工具能力通过边栏、菜单、辅助栏接入
- 保证“开口说话”永远是最简单的动作

---

## 9.5 右侧工作面板：让开发能力成为自然延伸

右侧工作面板包含：

- Files
- Shell
- Git

它的定位不是主导航，而是“和聊天一起工作的上下文工具”。

### 使用原则

- 用户在聊天中需要看代码、跑命令、看 git 时，再打开右侧面板
- 右侧面板记住上次状态，不打断主流程
- 右侧面板默认服务当前项目

### 具体价值

- Files：快速浏览项目结构、引用文件
- Shell：在同一上下文下执行命令
- Git：查看和处理代码变更

这样用户不需要在多个页面来回切换，可以围绕一个任务连续完成工作。

---

## 9.6 Memory：从“隐藏能力”变成“明确入口”

当前产品已经有 Memory 能力，但在新结构中应更容易被理解。

### 用户应该怎么理解 Memory

Memory 是项目的长期上下文和知识入口，不是聊天记录替代品。

### 在新 UI 中的定位

- 作为 Sidebar 的全局工具之一
- 与 Project Chat 并列，但不抢聊天主入口
- 在项目上下文下进入时，应尽量自动带入项目信息

### 用户收益

- 更容易理解某项目已有的记忆与背景
- 更方便从“聊天”切到“回顾项目长期上下文”

---

## 9.7 Always-On：从“高级功能”变成“高级但易理解”

Always-On 现在的能力很强，包括 cron、discovery、plan execution 等，但在用户体验上应避免术语堆砌。

### 用户应该感知到的价值

- 系统可以持续帮我观察项目
- 系统可以发现值得处理的问题
- 系统可以生成后续计划，必要时让我确认

### 页面表达方式

不要一上来展示复杂技术字段，而应先强调：

- 最近自动发现了什么
- 哪些计划待你确认
- 哪些任务正在运行
- 你可以现在立即执行什么

这能把 Always-On 从“高级面板”变成“可理解的自动化助手”。

---

## 9.8 Dashboard：给进阶用户的可视化视图

Dashboard 是进阶能力，不是主起点。

### 用户价值

- 看整体使用情况
- 看模型路由和成本
- 看系统运行状态

### 设计要求

- 在 Sidebar 有稳定入口
- 用更清楚的摘要卡片和图表表达信息
- 不要求所有用户都理解，但需要让需要它的人很快找到

---

## 9.9 Tasks：有则自然出现，无则不打扰

Tasks 是条件性能力。

### 设计原则

- 如果当前环境未启用或未安装，不展示或不强调
- 如果可用，则放在全局工具中，和 Memory / Always-On / Dashboard 同级

### 用户价值

- 对任务驱动型用户，提供更结构化的工作方式
- 对普通聊天用户，不增加额外复杂度

---

## 9.10 Plugins：从主流程移到设置与扩展区

插件仍然重要，但不应占据新用户的第一层心智。

### 原则

- 插件能力继续保留
- 但插件不应把主导航变得拥挤
- 更适合在 Settings / Plugins 中管理
- 需要时可以在主区打开插件内容

---

## 10. 关键用户路径

### 路径 1：第一次打开产品

1. 进入首页
2. 看到 `New chat` 与 Projects
3. 直接开始对话，或进入某个项目

### 路径 2：在项目里完成一个开发任务

1. 进入项目
2. 在 Project Landing 里描述需求
3. 进入项目聊天
4. 需要时打开 Files / Shell / Git
5. 完成后回到聊天继续推进

### 路径 3：查看项目长期上下文

1. 进入某项目
2. 从 Sidebar 打开 Memory
3. 回看项目记忆与上下文
4. 返回聊天继续工作

### 路径 4：用 Always-On 做自动化跟进

1. 从 Sidebar 打开 Always-On
2. 查看最近发现的问题或计划
3. 决定立即执行、稍后处理或继续观察

### 路径 5：进阶用户查看成本与路由

1. 从 Sidebar 打开 Dashboard
2. 查看成本、tokens、路由情况
3. 再回到当前聊天或项目

---

## 11. 功能需求

### 11.1 New chat

- 始终在最显眼位置
- 点击后立即进入可输入状态
- 创建 General Chat 的流程必须足够快

### 11.2 Projects 列表

- 清楚显示项目名称
- 支持搜索、进入、创建、基础管理
- 项目不再默认表现为“可展开的 session 树”

### 11.3 Chats 列表

- 展示最近聊天
- 清楚区分属于哪个项目，或属于 General
- 方便快速恢复上下文

### 11.4 Project Landing

- 有 composer
- 有项目简介
- 有最近聊天
- 有主要工具入口

### 11.5 Chat 视图

- 以消息流为核心
- 输入区稳定
- 长文、代码块、思考过程可读

### 11.6 Files / Shell / Git

- 以右侧面板形式存在
- 默认跟随当前项目
- 状态可记忆

### 11.7 Memory / Always-On / Dashboard / Tasks

- 统一作为 Sidebar 全局工具
- 进入后有明确的标题与返回聊天入口
- 不破坏用户当前聊天上下文

### 11.8 Settings

- 保留现有设置能力
- 分类清楚
- 不抢主流程

---

## 12. 内容与文案要求

这次 PRD 强调 user-friendly，因此产品文案也要更友好。

### 12.1 文案原则

- 少说系统内部术语
- 多说用户价值
- 动作词优先
- 空态要有下一步建议

### 12.2 示例

不推荐：

- `No session selected`
- `No project metadata`
- `Discovery execution unavailable`

更推荐：

- `Start a new chat to begin`
- `Add a short description so this project is easier to recognize later`
- `No follow-up tasks yet`

---

## 13. 非功能要求

### 13.1 性能

- 首屏要轻，首页不能像控制台一样拥挤
- 长聊天与多工具并存时，仍应保持稳定

### 13.2 可用性

- 新用户不看文档也能开始
- 老用户迁移成本低
- 移动端至少保留核心聊天与导航体验

### 13.3 一致性

- 明暗主题一致
- 所有主要视图风格统一
- 交互模式统一，不同页面不要像不同产品拼起来

---

## 14. MVP 范围建议

第一阶段建议先完成最影响体验的部分。

### MVP 应包含

1. 方案一视觉换皮
2. Sidebar 重组
3. `New chat`
4. Project Landing
5. Chat 主体验优化
6. 右侧 Files / Shell / Git 面板
7. Memory / Always-On / Dashboard 的新入口

### 第二阶段再做

1. 更完整的快捷键体系
2. 更强的文件引用体验
3. 更细的 project metadata 能力
4. 更完善的移动端优化
5. 插件入口进一步收纳

---

## 15. 风险与注意事项

### 15.1 风险

- 功能很多，容易在“更简单”和“功能不丢”之间拉扯
- 老用户习惯顶部 tab，需要平滑迁移
- 如果把太多高级能力继续放在第一层，新 UI 会再次变复杂

### 15.2 处理原则

- 主流程只保留最关键入口
- 高级能力保留，但后移
- 不一次性重做所有体验，先把主路径打通

---

## 16. 这版 PRD 的产品结论

对 edgeclaw 来说，最合适的方向不是“做一个更炫的 UI”，而是“把现有强能力用更自然的方式呈现出来”。

方案一适合做默认方案，因为它最符合以下目标：

- 新用户能立刻上手
- 老用户不会失去深度能力
- 工程落地风险最低
- 能承载当前 chat、project、files、shell、git、memory、always-on、dashboard 等完整能力

最终交付应该是一种体验：

> 像 ChatGPT 一样好开始，像开发工作台一样能深入做事。

---

## 17. 附录：功能映射

| 当前能力 | 新 UI 中的位置 | 面向用户的表达 |
| - | - | - |
| Chat | 主区核心视图 | 与 AI 对话完成任务 |
| Projects / Sessions | Sidebar | 进入不同工作上下文 |
| Files | 右侧面板 | 浏览与引用项目文件 |
| Shell | 右侧面板 | 在项目上下文中执行命令 |
| Git | 右侧面板 | 查看和处理代码变更 |
| Memory | Sidebar 全局工具 | 查看项目长期上下文 |
| Always-On | Sidebar 全局工具 | 自动巡检与后续计划 |
| Dashboard | Sidebar 全局工具 | 查看系统与使用情况 |
| Tasks | Sidebar 全局工具（条件显示） | 结构化任务管理 |
| Plugins | Settings / 扩展区 | 扩展产品能力 |
| Settings | Footer / 设置页 | 管理账号、外观、API、路由等 |

---

## 18. 工程实现细节

本节把第 1–17 章的产品方案，落到 `claudecodeui` 真实代码上，明确**装什么 / 改什么 / 删什么**。所有路径相对仓库根。

### 18.1 当前技术栈与依赖盘点

来自 `claudecodeui/package.json` 与 `tailwind.config.js`：

- **运行时**：React 18.2、Vite 7、TypeScript 5.9、`react-router-dom` 6.8（目前**只有** `/` 与 `/session/:sessionId`）
- **样式**：Tailwind 3.4 + `@tailwindcss/typography`；`src/index.css` 已用 shadcn 的 HSL 变量，亮暗主题已支持
- **shadcn 三件套已装齐**：`class-variance-authority` ^0.7、`clsx` ^2.1、`tailwind-merge` ^3.3
- **图标**：`lucide-react` ^0.515（全站使用）
- **重型依赖**：`@codemirror/*`、`@xterm/*`、`react-markdown` + remark/rehype 全套、`fuse.js`、`i18next` + `react-i18next`、`react-dropzone`
- **WebSocket**：`ws`，前端通过 `App.tsx` 顶层 `ws + sendMessage + latestMessage` 三件套向下传
- **多 provider 后端**：`server/routes/{cursor,codex,gemini}.js` + 对应 cli 文件
- **本次需要新增**：
  - **Radix UI** primitives（由 shadcn `add` 自动装）
  - **`@fontsource-variable/inter`**
  - 可选：**`cmdk`**（⌘K）

> 结论：本次是**叠加 + 收纳**，不是“换技术栈”。新增依赖体量小（Inter 字体 + 按需 Radix + 可选 cmdk），合计 < 200KB gz。

### 18.2 顶层骨架改造

**改造目标**：从 `App.tsx` 现状（`/` + `/session/:id` 两个路由 + `MainContent` 单页 tab 切换）升级到三段式 + 多路由。

**新增路由表**（在现有 `App.tsx` 基础上扩展，不破坏 `/session/:id`）：

| 路径 | 用途 | 备注 |
| - | - | - |
| `/` | Home（首页） | 现有 `/` 改造 |
| `/new-chat` | General Chat 空态 | 新增 |
| `/chat/:sessionId` | General Chat | 新增 |
| `/p/:projectName` | Project Landing | 新增 |
| `/p/:projectName/c/:sessionId` | Project Chat | 新增 |
| `/memory[/<:projectName>]` | Memory 全屏视图 | 新增；当前是 tab |
| `/always-on/:projectName` | Always-On | 新增 |
| `/tasks/:projectName` | TaskMaster | 新增；条件可见 |
| `/dashboard` | Routing Dashboard | 新增 |
| `/settings/*` | 设置抽屉/页 | 现有 `Settings` 复用 |
| `/session/:sessionId` | 老链接重定向 | **保留**，做 lazy 解析后跳 `/p/:name/c/:id` 或 `/chat/:id` |

**新组件清单**（统一落 `src/components/`）：

```
src/components/
  ui/                              # shadcn 生成
    button.tsx
    input.tsx
    textarea.tsx
    dialog.tsx
    sheet.tsx
    dropdown-menu.tsx
    tooltip.tsx
    tabs.tsx
    scroll-area.tsx
    separator.tsx
    switch.tsx
    avatar.tsx
    badge.tsx
    command.tsx                    # 可选 ⌘K
  app-shell/
    AppShell.tsx                   # 新顶层容器：Sidebar + Main + RightPanel + 全屏工具切换
    useAppShellLayout.ts           # 三栏宽度、折叠、面板状态
  home/
    HomeView.tsx                   # / 路由的首页
    RecentProjectsGrid.tsx
    RecentChatsList.tsx
  general-chat/
    GeneralChatView.tsx            # 复用 ChatInterface，project=null
    NewChatLanding.tsx             # /new-chat 空态
  project-landing/
    ProjectLanding.tsx
    ProjectInstructionsCard.tsx
    ProjectKnowledgeCard.tsx       # v2 再上
    RecentProjectChats.tsx
  right-panel/
    RightPanel.tsx                 # 头部 tab + 内容容器 + 拖拽把手
    RightPanelFilesTab.tsx         # 包 FileTree
    RightPanelShellTab.tsx         # 包 StandaloneShell
    RightPanelGitTab.tsx           # 包 GitPanel
    useRightPanelState.ts
  fullscreen-tool/
    FullscreenToolLayout.tsx       # Memory / Always-On / Tasks / Dashboard 共用 header + 内容
```

### 18.3 现有组件如何映射（保留 / 重构 / 替换）

| 现有文件 | 处理方式 | 说明 |
| - | - | - |
| `src/App.tsx` | **改造** | 增加新路由表；`MainContent` 不再直接挂在 `/`，由 `AppShell` 控制 |
| `src/components/main-content/view/MainContent.tsx` | **拆分 + 瘦身** | 把 8 个 `activeTab === 'xxx'` 分支拆走：`chat` 留下变成 ChatView；其他迁到对应路由组件；保留 `discoveryExecution` 逻辑（重要业务，移到自定义 hook 复用） |
| `src/components/main-content/view/subcomponents/MainContentTabSwitcher.tsx` | **删除使用 / 保留常量** | tab 数据数组抽成 `useAppTabs()` 给 Sidebar / mobile bottom nav 使用 |
| `src/components/main-content/view/subcomponents/MainContentHeader.tsx` | **简化** | 去掉 PillBar，保留面包屑（project / chat title） |
| `src/components/sidebar/view/Sidebar.tsx` | **重构** | 5 段式（Header → New chat → 全局工具 → Projects → Chats → Footer） |
| `src/components/sidebar/view/subcomponents/SidebarProjectItem.tsx` | **简化** | 去掉展开 sessions 的能力，点击直接跳 `/p/:name` |
| `src/components/sidebar/view/subcomponents/SidebarProjectSessions.tsx` | **改用途** | 改为扁平 `SidebarChatsList`（按时间排，不按 project 嵌套） |
| `src/components/chat/view/ChatInterface.tsx` | **抽取 composer** | 把输入区抽成 `<ChatComposer>`，给 ProjectLanding 与 ChatView 复用 |
| `src/components/chat/view/ChatInputArea.tsx`（如存在） | **换皮** | 用 shadcn `<Textarea>` 替换原生 `<textarea>`，发送按钮用 `<Button size="icon">` |
| `src/components/file-tree/view/FileTree.tsx` | **复用** | 在 `RightPanelFilesTab` 里包一层；点击文件默认动作改为往 composer 插 `@path` chip |
| `src/components/standalone-shell/view/StandaloneShell.tsx` | **复用** | 包进 `RightPanelShellTab`；保留懒启动；`isActive` 改为受 RightPanel 当前 tab 控制 |
| `src/components/git-panel/view/GitPanel.tsx` | **复用** | 包进 `RightPanelGitTab` |
| `src/components/main-content/view/memory/MemoryPanel.tsx` | **复用** | 挂在 `/memory[/...]` 路由下，外面套 `FullscreenToolLayout` |
| `src/components/always-on/view/AlwaysOnPanel.tsx` | **复用** | 挂在 `/always-on/:name`；现有 discovery / cron 逻辑不动 |
| `src/components/task-master/*` | **复用 + 条件渲染** | 挂在 `/tasks/:name`；继续受 `useTasksSettings` 控制 |
| `src/components/routing-dashboard/RoutingDashboard.tsx` | **复用** | 挂在 `/dashboard` |
| `src/components/code-editor/view/EditorSidebar.tsx` + `useEditorSidebar` | **重要冲突点** | 与新 RightPanel 的位置冲突，详见 §19.4 |
| `src/components/plugins/view/PluginTabContent.tsx` + `PluginsContext` | **保留 + 收纳** | 不再进 sidebar，改为 `/p/:name/plugin/:pluginName` 或 Settings → Plugins 内打开 |
| `src/components/settings/*` + `SettingsMainTab` | **保留** | 入口仍在 footer；Plugins 子页继续工作 |
| `src/components/sidebar/view/subcomponents/SidebarFooter.tsx` | **保留** | Settings + User + Version 不动 |
| `src/components/main-content/view/subcomponents/MobileMenuButton.tsx` | **改造** | bottom nav 仅留 Chat / Project / Tools 抽屉 |

### 18.4 状态与数据流

**保留现有 WebSocket 中枢**：`App.tsx` 顶层的 `ws / sendMessage / latestMessage / processingSessions / onSessionActive / onSessionInactive / onSessionProcessing / externalMessageUpdate` 全套继续向下传。

**新增本地 UI 状态**（统一到 `useUiPreferences`，已存在的 hook 扩展即可）：

```ts
type UiPreferences = {
  // 现有
  autoExpandTools: boolean;
  showRawParameters: boolean;
  showThinking: boolean;
  autoScrollToBottom: boolean;
  sendByCtrlEnter: boolean;

  // 新增
  sidebarCollapsed: boolean;
  sidebarSearchQuery?: string;
  rightPanelByProject: Record<string, {
    open: boolean;
    tab: 'files' | 'shell' | 'git';
    width: number;
  }>;
  lastChatRoute: string;          // 退出全屏工具时回到哪
  generalChatCwd?: string;        // 默认 $HOME
};
```

**Discovery 执行追踪**（`MainContent.tsx` 现有约 200 行的 `pendingDiscoveryExecutionsRef + discoveryExecutionsBySessionRef + autoLaunchInFlightRef` 逻辑）：

- 抽成 `src/hooks/useDiscoveryExecutionTracker.ts`
- 在 `AppShell` 顶层挂载，跨路由保活（避免用户切到 Memory 时正在执行的 plan 状态丢失）
- 现有自动 poll（15s）保留

### 18.5 后端改动（最小集）

> 本次以前端 IA 重构为主，后端**尽量不动**。仅在以下场景引入新 endpoint：

**必需**：
- `GET /api/sessions/:id/resolve` — 给 `/session/:id` 老链接重定向用，返回 `{ projectName | null }`。可由现有 `server/projects.js` session-index 复用实现。

**Provider 收窄（可选，建议同步做）**：
- `server/routes/cursor.js` / `codex.js` / `gemini.js` 全部改为 `res.status(501)`，由 `CLAUDE_ONLY=true`（默认）feature flag 短路
- 保留文件，commit message 标 "hidden, will be removed in v2"

**v2 才做**（非本次 PRD 必须）：
- Project metadata 扩展（description / color / instructions / knowledge）
- Knowledge 上传/删除
- Session → project 映射表

> 这部分原 `prd.md` §6 已写得比较细，本 PRD 维持"v1 不引入"的取舍，避免一次改太多。

### 18.6 视觉与 token 改造

**Inter 字体**（≈ 0.1 天）：
```bash
cd claudecodeui
npm i @fontsource-variable/inter
```
`src/main.tsx` 顶部加：
```ts
import '@fontsource-variable/inter';
```
`tailwind.config.js`：
```js
theme: {
  extend: {
    fontFamily: {
      sans: ['"InterVariable"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
    },
  },
}
```
然后从 `src/index.css` 的 `body` 里删除 `font-family: -apple-system, ...` 系统栈。

**shadcn 初始化**（≈ 0.4 天）：
```bash
cd claudecodeui
npx shadcn@latest init
# 选择：style: new-york / baseColor: zinc / cssVariables: true
# aliases 指到 src/components/ui、src/lib/utils
npx shadcn@latest add button input textarea dialog dropdown-menu \
  scroll-area separator tooltip tabs sheet switch avatar badge
```

**HSL 变量收敛**：当前 `src/index.css` 已是 HSL 变量；按 zinc/new-york 默认值核对一遍 `--primary / --ring / --radius`，不需要重写。

### 18.7 路由层落地

`src/App.tsx` 内 `Routes` 草图（仅示意）：

```tsx
<Routes>
  <Route element={<AppShell />}>
    <Route path="/" element={<HomeView />} />
    <Route path="/new-chat" element={<NewChatLanding />} />
    <Route path="/chat/:sessionId" element={<GeneralChatView />} />
    <Route path="/p/:projectName" element={<ProjectLanding />} />
    <Route path="/p/:projectName/c/:sessionId" element={<ProjectChatView />} />
    <Route path="/memory" element={<FullscreenToolLayout title="Memory"><MemoryPanel /></FullscreenToolLayout>} />
    <Route path="/memory/:projectName" element={<FullscreenToolLayout title="Memory"><MemoryPanel /></FullscreenToolLayout>} />
    <Route path="/always-on/:projectName" element={<FullscreenToolLayout title="Always-On"><AlwaysOnPanel /></FullscreenToolLayout>} />
    <Route path="/tasks/:projectName" element={<FullscreenToolLayout title="Tasks"><TaskMasterPanel /></FullscreenToolLayout>} />
    <Route path="/dashboard" element={<FullscreenToolLayout title="Dashboard"><RoutingDashboard /></FullscreenToolLayout>} />
    <Route path="/session/:sessionId" element={<LegacySessionRedirect />} />
  </Route>
</Routes>
```

`AppShell` 自己决定何时显示 `RightPanel`（路由匹配 `chat/project*` 时显示，全屏工具时隐藏，Home 隐藏）。

### 18.8 拆 PR 与时间盒（更新版）

延续原 `prd.md` §8，根据本次"工程实现细节"的扩展，建议拆为 9 个 PR：

| # | 范围 | 估时 | 依赖 |
| - | - | - | - |
| **PR-0** | Inter + shadcn init + 基础 ui 组件 add | 0.5d | — |
| **PR-1** | `useAppTabs()` 抽出 + tab 常量化（不改 UI） | 0.5d | PR-0 |
| **PR-2** | `AppShell` + 新路由骨架（旧 `/` 暂时仍渲染 `MainContent`） | 1d | PR-1 |
| **PR-3** | 新 Sidebar（5 段式 / 不展开 sessions） | 1.5d | PR-2 |
| **PR-4** | `RightPanel`（Files / Shell / Git tab） | 2d | PR-3 |
| **PR-5** | `HomeView` + `NewChatLanding` + `GeneralChatView` | 1.5d | PR-3 |
| **PR-6** | `ProjectLanding` + `ProjectChatView` | 1.5d | PR-4 |
| **PR-7** | 全屏工具路由（Memory / Always-On / Tasks / Dashboard） + `Back to chat` 记忆 | 1d | PR-2 |
| **PR-8** | Provider 收窄 (`CLAUDE_ONLY` flag + 501 化) + `LegacySessionRedirect` + e2e | 1.5d | PR-5, PR-6 |

**合计：≈ 11 人日**（含联调缓冲）

### 18.9 Feature flag 与灰度

- 引入 `VITE_UI_V2=true`（默认 false 直到 PR-8 合并）
- `App.tsx` 顶部根据 flag 决定挂老 `MainContent` 还是新 `AppShell`
- 新老路由前缀**互不冲突**（`/` 在两者都存在，但内部组件不同）
- 上线策略：内部 dogfood 1 周 → 默认开 → 1 个版本后删除老路径

### 18.10 测试与验收

**新增测试**（`vitest` 已在 devDeps）：
- `useAppTabs.test.ts` — tabs 数组生成（有 / 无 tasks / 含 plugin tabs）
- `useDiscoveryExecutionTracker.test.ts` — 抽出后的执行追踪逻辑回归
- `useRightPanelState.test.ts` — 按 project 记忆 open/tab/width
- `LegacySessionRedirect.test.tsx` — 老 URL 命中 / 不命中两条分支
- `AppShell.layout.test.tsx` — 路由 → 是否渲染 RightPanel / 是否进入全屏视图

**手动 e2e 清单**：
1. 打开 `/` → 看到 New chat + Projects grid
2. 点 New chat → `/new-chat` → 发消息 → 跳 `/chat/:id`
3. 进 Project → `/p/:name` 不展开 sessions → 右侧面板 Files 默认打开
4. 切到 Shell → 不卸载 Files state → 切回 Files 状态保持
5. 进 Memory → 显示全屏工具，sidebar 仍在 → `Back to chat` 回到上一个 chat
6. 老链接 `/session/:id` → 正确分流
7. `CLAUDE_ONLY=true` 后，composer 无 provider 选择器，sidebar 无 provider badge

---

## 19. 重构注意事项

这一节专门记录"基于 edgeclaw 当前代码现状"的容易踩坑点，建议每个 PR 开工前回看一次。

### 19.1 多 provider 代码耦合非常深

- `SessionProvider = 'claude' | 'cursor' | 'codex' | 'gemini'` 类型在前后端共用
- `useProjectsState.ts`、`useSidebarController.ts`、`useChatProviderState.ts` 大量 `provider === 'cursor'` 等判断
- `Project` 类型上有 `cursorSessions / codexSessions / geminiSessions` 三个并列字段
- 后端 `server/projects.js` 里 Cursor 用 MD5 hash 推 project 名

**对策**：
- **PR-0 / PR-1 不动 provider 类型**，先做 UI 收纳（隐藏选择器、隐藏 badge）
- 通过 `CLAUDE_ONLY` feature flag 短路
- 保留所有非 claude 字段为可选，序列化时保留，**不主动清空**（避免老 jsonl 元数据被破坏）
- v2 单独一个 PR 删类型时，全局搜 `cursor|codex|gemini` 至少跑两遍

### 19.2 `MainContent.tsx` 是当前最复杂的组件

它承担了：tab 切换 + chat 渲染 + 6 个其它工具渲染 + EditorSidebar 协同 + Always-On discovery 执行追踪 + WebSocket message 路由 + auto-poll plans。

**注意**：
- 不要在 PR-2 就把它一次性拆光，应**先抽 hook、再拆视图**
- `pendingDiscoveryExecutionsRef` / `discoveryExecutionsBySessionRef` / `autoLaunchInFlightRef` 三个 ref 串成的状态机**必须保活**到 `AppShell` 顶层，否则切到 Memory 时丢数据
- `latestMessage` 副作用 useEffect 跨多个 ref 操作 — 抽到 hook 时小心 ref 引用闭包问题
- `pollAutoExecutablePlans` 15 秒 timer 抽走时记得 cleanup

### 19.3 WebSocket 单例 + 跨路由保活

- `ws / sendMessage / latestMessage` 在 `App.tsx` 顶层创建，是全局单例
- 路由切换时**不要**重连
- 把这三件套放在 `AppShell` 顶层 / Context 里下发给所有 chat 与工具视图
- 不要在 `ChatView` 内部新建 WebSocket
- 老的 `MainContentProps` 长达 18 个字段，过 Context 比 props drilling 更合适

### 19.4 EditorSidebar 与 RightPanel 的位置冲突 ⚠️

**这是最大的潜在冲突**：
- `useEditorSidebar` + `EditorSidebar` 当前已经占据 `MainContent` 右侧（CodeMirror 编辑文件时弹出）
- 本 PRD 的 RightPanel 也在右侧

**两种处理方案**：

| 方案 | 描述 | 评价 |
| - | - | - |
| **A** | EditorSidebar 升级成 modal / overlay（覆盖中间 + 右侧），不再占右侧位置 | 简单；但失去“边看代码边聊”的能力 |
| **B**（推荐） | RightPanel 增加第 4 个 tab `Editor`，把 EditorSidebar 内容内嵌；点击 FileTree 文件时若按 `Open in editor`，自动切到 Editor tab | 保留现有体验；多了一个 tab，但 file → editor 流程更连续 |

**决策时机**：PR-4 开始前必须定，否则 RightPanel 实现完后再回头改成本翻倍。

**额外坑**：`useEditorSidebar` 的拖拽 `editorWidth` 与 RightPanel 的 `rightPanelWidth` 是两套独立状态；统一到 `useUiPreferences.rightPanelByProject` 之前，先用桥接逻辑共享。

### 19.5 Plugin tabs 的处理

- `PluginsContext` 当前会动态往 `BASE_TABS` 后追加 `plugin:<name>` tab
- 新 IA 中 sidebar 已无插件入口；插件 tab 不能凭空消失
- **建议方案**：plugin tabs 移到 `/p/:name/plugin/:pluginName` 子路由，由 ProjectLanding 提供"已启用插件"卡片入口
- 兼容期：`useAppTabs()` 仍返回 plugin tabs 数组，但 sidebar 只渲染前 4 个全局工具，plugins 数组传给 ProjectLanding 用

### 19.6 平台模式与本地认证差异

- `ProtectedRoute.tsx` 根据 `IS_PLATFORM` / `DISABLE_LOCAL_AUTH` 走不同分支
- 新 IA 不能假设有"用户名 / 头像"，footer 里 `User` 区在 platform 模式下需要降级显示
- 默认 `cwd` 在 platform 模式下是 `/workspace`；General Chat 的 `generalChatCwd` 默认值要根据平台模式取，而不是硬写 `$HOME`

### 19.7 Tasks 的条件可见

- `useTasksSettings.tasksEnabled && isTaskMasterInstalled` 才显示 Tasks
- 新 IA 中：Sidebar 全局工具区按这个条件**条件渲染** Tasks 项；且 `/tasks/:name` 路由在不满足条件时应 redirect 到 `/p/:name`
- `MainContent.tsx` 现有副作用 `if (!shouldShowTasksTab && activeTab === 'tasks') setActiveTab('chat')` 在新结构里不再需要，但要在路由层等价实现

### 19.8 i18n 全程在线

- `react-i18next` + 多语言文案文件已铺到全站（`tabs.chat / tabs.alwaysOn / tabs.shell ...`）
- 所有新组件**必须**走 `useTranslation` 而不是硬编码字符串
- 新增 key 时要同步更新 zh / en / ja / ko / de / ru 6 套
- Sidebar 新文案（"PROJECTS / CHATS / New chat"）要新增 i18n key

### 19.9 移动端

- 现有 `MobileMenuButton` 把 sidebar 当抽屉用
- 新 IA 在移动端：
  - 三栏退化为单栏
  - RightPanel 改为 bottom sheet 或全屏覆盖
  - 全屏工具视图直接全屏
- shadcn `Sheet` 组件可以替代当前自写抽屉

### 19.10 性能

- `xterm` + `CodeMirror` 都很重；RightPanel 切 tab 用 **CSS hide** 不要 unmount（参考现有 `MainContent.tsx` `activeTab === 'shell' ? block : hidden`）
- StandaloneShell **懒启动**：用户首次切到 Shell tab 才连 PTY；现有 `isActive` prop 已支持
- Sidebar Chats 列表 30 条以上要虚拟列表（v2，先用分页加载）

### 19.11 老 URL 与书签兼容

- `/session/:sessionId` 是当前唯一 deep link，外部可能已被分享 / 收藏
- `LegacySessionRedirect` 必须**幂等**且不闪烁：建议先 `useEffect` 调 `/api/sessions/:id/resolve`，命中后 `navigate(replace: true)`
- 失败时回退到 `/`，不要 404

### 19.12 持久化与迁移

- 现有 localStorage key（`claude-permission-mode / claude-settings / ui-preferences / general-chat-cwd`）继续用
- `ui-preferences` 新加字段时**不要**整体重写：用 `{ ...old, sidebarCollapsed: false, rightPanelByProject: {} }` 合并
- 写一个 `migrateUiPreferences(v1 → v2)` 单元测试，覆盖 missing field 默认值
- 不要清空老用户的 `activeTab`（即使 v2 不再用），保留至少 1 个 minor 版本

### 19.13 Discovery / Always-On 业务逻辑保护

- Always-On 是**自动执行**类型功能，回归错误的代价最高
- `MainContent.tsx` 的 4 个 `useEffect` + 3 个 ref + WebSocket message handler 全部要保活
- 测试场景必须包含：
  - 用户点 Discover → 创建 plan → 切到 Memory → 切回 → 看到 plan
  - Auto plan 在执行中 → 切到 Dashboard → session 完成 → 状态正确更新
- 抽 `useDiscoveryExecutionTracker` 时**先写测试再重构**

### 19.14 Memory iframe 的特殊性

- `MemoryPanel` 是 iframe，里面是独立 React 应用
- 新路由 `/memory[/:projectName]` 时，需要把 project / theme / locale / token 拼到 iframe URL（`buildMemoryDashboardUrl`）
- 主题切换时通过 `postMessage` 通知 iframe；新结构不要丢这个通信
- 全屏工具视图切换时不要重建 iframe（保活），否则 memory 内部状态会丢

### 19.15 文档与 Onboarding 同步

- 重构期 README 里的截图会失效，至少 PR-8 合并前后各更新一版
- `docs/plans/2026-04-23-ui-refactor/prototype/shadcn.html` 是设计基准，开发以它为准；如果设计调整，先改原型再改代码
- 第一次跑 v2 时，老用户应该看到一次 **What's new** 弹窗（指向新 IA、Sidebar 5 段式、右侧面板用法）

### 19.16 回滚预案

- 每个 PR 都保证**单独可回滚**
- 关键 cutover（PR-2 引入 AppShell、PR-8 默认开 v2）必须能用单 commit revert
- localStorage 在版本回退后要兼容（旧版只读老字段，忽略未知字段）
- 后端 501 化是**双向兼容**的（旧 UI 不走这些路径），不需要回滚

### 19.17 不要做的事（明确边界）

为防止 scope creep，本次 PRD 期间**不**做：
- 不重写 chat streaming
- 不改 session jsonl 存储
- 不动 Memory schema
- 不引入 React Server Components
- 不引入新的全局状态库（Redux / Zustand / Jotai 都不要加，现有 Context + hooks 够用）
- 不做"Promote general chat to project"（v2 评估）
- 不做 knowledge 上传（v2）

---
