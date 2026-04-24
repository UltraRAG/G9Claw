# edgeclaw UI 三种模式：开源方案 + 迁移调研

> 基于 `docs/plans/2026-04-23-ui-refactor/prototype/{shadcn,aceternity,linear}.html` 三版原型，针对现有 `claudecodeui` 代码库的迁移调研。
> 三版信息架构一致（top-right tabs → sidebar），只有视觉语言不同。

---

## 背景：当前 UI 技术栈现状

在进入三种模式之前，先盘点 `claudecodeui` 当前的前端栈（`package.json` + `tailwind.config.js` + `src/index.css`）：

- **框架**：React 18 + Vite 7 + TypeScript 5.9
- **样式**：Tailwind CSS 3.4 + `@tailwindcss/typography`
- **主题体系**：已经是 shadcn 风格的 **HSL CSS variables**（`--background` / `--foreground` / `--primary` / `--muted` / `--border` …），已支持 `.dark` class 切换
- **shadcn 基础依赖**：`class-variance-authority` ^0.7、`clsx` ^2.1、`tailwind-merge` ^3.3（**shadcn 的三件套已装齐，但 `src/components/ui/*` 还没落地**）
- **图标**：`lucide-react` ^0.515（全站在用）
- **其它重型依赖**：`@codemirror/*`、`@xterm/*`、`react-markdown` + `remark-gfm` + `remark-math` + `rehype-katex`、`react-router-dom` ^6、`i18next`
- **缺的关键库**：Radix UI、`framer-motion`、Inter 字体、`cmdk`（⌘K 命令菜单）

> 结论：**当前栈本质已经是半成品的 shadcn 方案**——Tailwind 主题 token、CVA/clsx/tailwind-merge、Lucide 图标全都齐了，差的只是 Radix + `src/components/ui` 这一层组件实现。所以三种模式的迁移成本差异，本质上取决于：
> 1. 要不要在现有 shadcn 语义上再塞新库（motion / backdrop / cmdk）；
> 2. 要不要替换字体、圆角、字号、色彩系统这些 token；
> 3. tab 结构从 `PillBar` 移到 sidebar 的共通工程量（三种模式都一样，约 1 PR）。

下面分三节分别写。

---

## Mode 1：仿 OpenAI 模式（shadcn / ChatGPT 风）

对应原型：`prototype/shadcn.html`

### 视觉语言

- ChatGPT-style 对话气泡（用户轻灰、助手无底）
- `zinc` 为主、单色 accent（`zinc-900` / `zinc-50`），圆角 `--radius: 0.5rem` 左右
- 亮色 + 暗色双主题
- Inter 字体，`cv11`/`ss01` 字体特性
- 非常克制的 border 和 shadow，几乎无动画

### 用的开源方案

| 层 | 方案 | 说明 |
| - | - | - |
| 组件库 | **[shadcn/ui](https://ui.shadcn.com)**（MIT） | 非 npm 包，通过 `npx shadcn@latest add <comp>` 复制源码到 `src/components/ui/` |
| 底层原语 | **[Radix UI](https://www.radix-ui.com)**（MIT） | shadcn 每个组件背后的无样式 headless 基础（Dialog / Popover / Dropdown / Tabs / Tooltip / ScrollArea …） |
| 样式 | Tailwind + CVA + `clsx` + `tailwind-merge` | **当前仓库已全部具备** |
| 图标 | `lucide-react` | **当前仓库已具备** |
| 字体 | [Inter](https://rsms.me/inter/)（OFL） | 自托管或 `@fontsource/inter` |
| 可选 | [`cmdk`](https://github.com/pacocoursey/cmdk)（MIT） | ChatGPT 的 ⌘K 快速切换 |
| 参考实现 | [openai/openai-cookbook 里的 examples](https://github.com/openai/openai-cookbook) 不直接用；真正可抄的是 [Vercel AI Chatbot](https://github.com/vercel/ai-chatbot)（MIT） | shadcn + Tailwind 的开源 ChatGPT 克隆，可以直接参考 layout、组件拆分、streaming 处理 |

> Vercel 自家还有 **[Geist Design System](https://vercel.com/geist)** 和 **[@vercel/geist-ui](https://github.com/vercel/geist-ui)**，但 Geist 组件库迭代较慢；生态主流依然是 shadcn。建议采用 shadcn + 借鉴 Vercel AI Chatbot 的 layout。

### 迁移到现有代码要做的事

**PR A：装齐 shadcn 基础**（约 0.5 天）

1. 初始化 shadcn：
   ```bash
   cd claudecodeui
   npx shadcn@latest init
   ```
   `components.json` 选择：`style: new-york`，`baseColor: zinc`，`cssVariables: true`，`aliases` 指向现有路径。
2. 装必需 Radix primitive（shadcn init 后按需加）：
   ```bash
   npx shadcn@latest add button input textarea dialog dropdown-menu \
     scroll-area separator tooltip tabs sheet switch avatar badge
   ```
3. 加 Inter 字体：`npm i @fontsource-variable/inter` → 在 `src/main.tsx` `import '@fontsource-variable/inter'`，在 `tailwind.config.js` 的 `theme.extend.fontFamily.sans` 加 `InterVariable`。
4. 把 `src/index.css` 里 `--background` / `--foreground` 等 token 改成 shadcn `new-york/zinc` 默认值（与现有 `222.2 84% 4.9%` 基本一致，只需调 `--primary` 从蓝 `221.2 83.2% 53.3%` 改为 `zinc-900` 的 `240 5.9% 10%`）。

**PR B：tab 从 `PillBar` 迁到 sidebar**（约 1 天，三模式共用）

1. 删除 `src/components/main-content/view/subcomponents/MainContentTabSwitcher.tsx` 的 `<PillBar>` 调用渲染位置（保留 tabs 定义数组，导出常量）。
2. `src/components/sidebar/view/Sidebar.tsx` 中新增 “Tools” 一段，消费同一个 tabs 数组，渲染为 vertical list；激活态沿用 `<Pill>` 或替换为 shadcn `<Button variant="ghost" className="justify-start">` + `data-[state=active]` 样式。
3. `MainContentHeader` 保留面包屑（project / tab label），去掉中间的 `<MainContentTabSwitcher>`。
4. 更新移动端 `MobileMenuButton`：bottom nav 只留 4 个高频（Chat / Shell / Files / More），其余进抽屉。

**PR C：聊天气泡 + 输入框换皮**（约 1 天）

1. 用 shadcn `<Textarea>` 替换 `ChatInputArea` 里自写的 `<textarea>`（保留自动扩容逻辑）。
2. 发送按钮换成 shadcn `<Button size="icon" />` + lucide `ArrowUp`（解决之前"图标不居中"问题）。
3. 气泡：用户侧 `bg-muted rounded-2xl px-4 py-2.5`，助手侧无底、左侧 1px border-l accent 或纯文本。
4. `react-markdown` 的 prose 套 `@tailwindcss/typography`（已装）的 `prose prose-zinc dark:prose-invert`。

**PR D：可选——加 ⌘K 命令菜单**（约 0.5 天）

- `npm i cmdk`
- `npx shadcn@latest add command`
- 新 `<CommandPalette>` 挂全局，`⌘K` 打开，列 sessions / tools / projects / 最近文件。

**总成本：≈ 3 人日**
**风险**：低——栈本身已经是半个 shadcn，主要是把缺的 Radix primitive 补上 + 视觉 token 收敛。

**不会动的**：CodeMirror、xterm、WebSocket 层、server 侧全部不动。

---

## Mode 2：Aceternity 模式

对应原型：`prototype/aceternity.html`

### 视觉语言

- Dark-only，基础色 `#05050a`
- 三颗模糊的 aurora 渐变球（violet / pink / cyan）在背景慢飘
- 毛玻璃（glassmorphism）：`backdrop-blur-xl` + `bg-white/[0.03]` + `border-white/[0.07]`
- 渐变描边激活态（violet→pink），输入框 focus 光晕
- 流星 CSS 动画、渐变文字标题
- 标题用较大字号（24px+），整体更"秀"

### 用的开源方案

| 层 | 方案 | 说明 |
| - | - | - |
| 组件库 | **[Aceternity UI](https://ui.aceternity.com)**（**MIT + 部分 Pro 付费**） | 和 shadcn 同样的 copy-paste 模式，但所有组件假设你**已经装好 shadcn**，Aceternity 只加"花里胡哨"的视觉层 |
| 底层原语 | **Radix UI** | 仍依赖 shadcn 那套；Aceternity 不重复造 headless |
| 动效 | **[`framer-motion`](https://motion.dev)** v12+（MIT） | **几乎所有 Aceternity 组件都依赖 framer-motion**，这是和 shadcn 的主要增量 |
| 样式 | Tailwind + [`tailwindcss-animate`](https://github.com/jamiebuilds/tailwindcss-animate)（MIT） | 现有 tailwind.config.js 需要加这个 plugin |
| 色彩 | 通常沿用 Tailwind 默认 palette + 自定义 `--chart-*` | 不改 shadcn 的 HSL token |
| 图标 | Lucide | **已具备** |
| 字体 | Inter | 同上 |
| 参考仓库 | [`aceternity-ui/components`](https://github.com/aceternity-ui) 组件源码；或 [`aceternity-ui/landing-page`](https://ui.aceternity.com/components) 示例 | 可直接 `npx shadcn@latest add "https://ui.aceternity.com/registry/<name>.json"`（它提供 shadcn-compatible registry） |

> 关键认知：**Aceternity 不是替代 shadcn，是 shadcn 的扩展皮肤**。迁移成本 = shadcn 所有改动 + `framer-motion` + 一堆 Aceternity 的特效组件（`AuroraBackground` / `BackgroundBeams` / `Spotlight` / `Meteors` / `GlowingStarsBackground` / `CardHoverEffect` / `Sparkles` / `MovingBorder` 等）。

### 迁移到现有代码要做的事

**前置：先做 Mode 1 的 PR A + PR B + PR C**（shadcn 基础 + tab 迁移 + 气泡换皮）

**PR E：装 framer-motion + tailwindcss-animate**（约 0.3 天）

```bash
npm i framer-motion tailwindcss-animate
```

`tailwind.config.js`：
```js
plugins: [require('@tailwindcss/typography'), require('tailwindcss-animate')]
```

**PR F：引入 Aceternity 特效组件**（约 1.5 天）

1. 按 Aceternity registry 引入几个核心组件到 `src/components/ui/aceternity/`：
   - `AuroraBackground`（背景极光层）
   - `BackgroundBeams` 或 `Meteors`（流星）
   - `Spotlight`（鼠标跟随光斑，可选）
   - `MovingBorder`（新 chat 按钮的渐变流光边）
   - `BentoGrid`（Dashboard 卡片用）
   - `CardHoverEffect`（Memory 列表卡片 hover 上浮）
2. 改 `src/components/app/view/AppShell.tsx`（或最外层 Layout）：在 `<main>` 外套 `<AuroraBackground>`，注意 `z-index` 层级（sidebar / 模态框要在极光之上）。
3. 替换关键 CTA 按钮（新 chat、Commit、New task）为 `MovingBorder` 或渐变背景 button variant。

**PR G：色彩 + token 重调**（约 0.5 天）

1. `src/index.css` 新增 `.theme-aceternity` scope，覆盖：
   - `--background: 240 10% 3%`（近黑带蓝）
   - `--primary: 270 80% 60%`（violet）
   - `--accent`、`--ring` 换渐变用的 CSS 变量
   - 新增 `--glass-bg`、`--glass-border`、`--aurora-1` / `--aurora-2` / `--aurora-3`
2. 现有的 `--nav-glass-bg` 可以复用，思路基本一致。
3. **放弃亮色**（或亮色简单做到：aurora 关掉，玻璃变白——不推荐，违背风格）。

**PR H：字重 + 渐变字标题**（约 0.3 天）

- 页面 H1/H2 用 Tailwind `bg-gradient-to-r from-white via-violet-200 to-pink-200 bg-clip-text text-transparent`。
- 定义 `<GradientHeading>` 组件复用。

**总成本：≈ 5.5 人日（含 Mode 1 的 3 人日基底）**

**风险 / 顾虑**：
- **包体积**：framer-motion ≈ 75KB gz，aurora / beams 组件常含 `<canvas>` 或多层 blur 元素，低端机、长时间开着会发热。需要 `prefers-reduced-motion` 全局兜底。
- **可访问性**：毛玻璃 + 渐变容易让对比度不达 WCAG AA，需要用 a11y 工具回扫。
- **Aceternity Pro 组件**（一些高级效果）是付费的，需要确认只用 MIT 免费那部分。
- **长会话性能**：xterm 和 CodeMirror 同屏 + 背景持续动效，iPad / 老 MacBook 会掉帧。建议背景动画在 tab 非 chat 时降级为静态图。
- 和现有 `.nav-glass` / `--nav-tab-glow` 等 token 已有轻度毛玻璃风格，其实**改造成本被低估地很合理**——已经打好底了，只是加浓。

**不会动的**：业务逻辑层、CodeMirror、xterm、i18n、WS、server 侧。

---

## Mode 3：Linear.app 模式

对应原型：`prototype/linear.html`

### 视觉语言

- Dark-first（亮色可做但一般 Linear 用户都在暗色）
- 基础色 `#08090a`（Linear 的 "Slightly warm black"），表面色 `#101113`
- 单一 accent：Linear 紫 `#5E6AD2`
- 超紧凑排版：base 12–13.5px，行高 1.4
- 圆角 4–6px，几乎无阴影
- 键盘优先：所有 list 带 `kbd` 快捷键，`⌘K` 是主导航入口，1/2/3/4 数字切 tab
- 无动画、无毛玻璃、无渐变

### 用的开源方案

Linear.app 本身**闭源**，没有官方开源实现。复刻其视觉语言有几条可选路径：

| 路径 | 方案 | 说明 |
| - | - | - |
| A（推荐） | **shadcn/ui** + 自定义 token + `cmdk` | Linear 风 ≈ "shadcn 调紧 + 换 Linear 紫 + 键盘优先"，几乎不需要额外组件库 |
| B | **[`@tremor/react`](https://github.com/tremorlabs/tremor)**（Apache-2.0） | 做 Dashboard 图表时可替代——Tremor 本身也 shadcn 风，适合 Linear 的 Insights 页面 |
| C | **[`nextui`](https://nextui.org)** / **[`hero-ui`](https://github.com/heroui-inc/heroui)** | 同样基于 Tailwind + Radix，但整体比 shadcn 更"胶囊化"，**不太贴 Linear 的硬朗** |
| D | 参考仓库 | [`calcom/cal.com`](https://github.com/calcom/cal.com)（Cal.com 是 Linear 粉丝的典型 UI，shadcn + 单色 + 密排版）；[`dub-main/dub`](https://github.com/dub/dub) 也是类似密度 |

| 层 | 方案 | 说明 |
| - | - | - |
| 组件库 | **shadcn/ui** | 如上 |
| 命令菜单 | **[`cmdk`](https://github.com/pacocoursey/cmdk)**（MIT） | Linear 的 ⌘K 就是用它做的（`cmdk` 作者 Paco 曾在 Linear 团队） |
| 图标 | **Lucide**（当前） 或 **[`@radix-ui/react-icons`](https://icons.radix-ui.com)**（MIT） | Radix icons 风格更接近 Linear 原生，但只有 Lucide 一半多的图标，建议**主用 Lucide，个别细节图标换 Radix icons** |
| 字体 | **Inter**（Linear 自己在用）| 同上 |
| 动效 | ❌ 不加 framer-motion | Linear 几乎无动画，CSS transition 够用 |

### 迁移到现有代码要做的事

**前置：先做 Mode 1 的 PR A + PR B**（shadcn 基础 + tab 迁移）

**PR I：Linear token 覆盖**（约 0.5 天）

新建 `.theme-linear` scope 或直接覆盖默认值（`src/index.css`）：

```css
.theme-linear, .theme-linear.dark {
  --background: 240 5% 4%;        /* #08090a */
  --card: 240 5% 6%;              /* #0b0c0d */
  --muted: 240 5% 7%;             /* #101113 */
  --border: 240 3% 13%;           /* #1f2023 */
  --foreground: 240 10% 91%;      /* #e9e9eb */
  --muted-foreground: 240 4% 57%; /* #8a8f98 */
  --primary: 231 59% 60%;         /* #5e6ad2 */
  --primary-foreground: 0 0% 100%;
  --ring: 231 59% 60%;
  --radius: 0.3125rem;            /* 5px */
}
```

同时调 Tailwind 默认：`tailwind.config.js` 里把 `fontSize.base = '13px'`（或单独一个 `linear` 字号体系）。

**PR J：排版密度下调**（约 0.5 天）

- sidebar 宽度从默认 288px 收到 **232px**
- sidebar item `h-7 px-2 text-[13px]`，代替现在的 `h-9 px-3`
- tab header 从 48px 降到 40px
- table row `py-2.5` 代替 `py-4`
- 全局 `gap` 从 `4` 调到 `3`
- 按钮 `h-7 text-[12.5px]` 替代默认 `h-9`

**PR K：⌘K 命令菜单（核心交互）**（约 1 天）

1. `npm i cmdk`
2. `npx shadcn@latest add command dialog`
3. 新 `<CommandPalette>` 全局挂载：
   - 列 `actions`：`New chat (C)`, `New task (⌘T)`, `Switch project`, `Go to settings`…
   - 列 `tools`：8 个 tab
   - 列 `recent chats`：最近 10 个
   - 列 `files`：基于当前项目的文件 fuzzy search（`fuse.js` **已在依赖里**）
4. 绑定快捷键：`⌘K` 全局；`1/2/3/4` 切主要 tab；`C` 新 chat；`⌘T` 新 task。
5. sidebar 顶部的"搜索 / jump to"按钮点击也调起 palette。

**PR L：shortcut hint 铺开**（约 0.4 天）

- 新增 `<Kbd>` 组件（shadcn 没有原生，自己写）：
  ```tsx
  // src/components/ui/kbd.tsx
  export const Kbd: React.FC<Props> = ({ children, className }) => (
    <kbd className={cn("inline-flex h-[18px] items-center rounded border border-border bg-muted px-1.5 text-[10.5px] text-muted-foreground", className)}>
      {children}
    </kbd>
  );
  ```
- 在所有 sidebar 条目、按钮旁边显示快捷键。

**PR M：图标细节替换（可选）**（约 0.3 天）

- 保留 Lucide 为主
- 个别 UI 图标（`ChevronDown` / `ChevronRight` / `Check` / `Cross`）换 Radix Icons（`@radix-ui/react-icons`）以贴近 Linear 原生质感
- `strokeWidth` 统一调到 **1.65-1.75**（当前随意）

**总成本：≈ 5 人日（含 Mode 1 的 3 人日基底）**

**风险 / 顾虑**：
- **字号降到 13px 后移动端会炸**。需要保留一套"mobile override"把 base 拉回 14-15px，或者干脆**Linear 模式只在 ≥md 桌面端启用，移动端回退到 shadcn 模式**。
- **密度高 ≠ 信息好读**：Memory、Dashboard 列表要谨慎，图表 label 字号要单独放大。
- 键盘快捷键要和浏览器自带（`⌘1`…）冲突一轮检查，否则数字键 1/2/3/4 会被 Chrome 切 tab 拦走——当前原型用裸 `1-4`（无修饰键）规避，真实产品可能需要 `g 1` / `g 2` Vim 风（Linear 正是这么做的）。
- Linear 的图表是**自己画的 SVG**，如果 Dashboard 用 Tremor/Recharts 还是会有差距，接受即可。

**不会动的**：业务逻辑、CodeMirror、xterm、i18n、WS、server 侧。

---

## 共通部分（三种模式都要做的）

这部分工作量无论选哪个模式都得做，单独拎出来方便拆 PR：

1. **Tab 搬家**（≈ 1 天）
   - 把 `MainContentTabSwitcher` 的数据源抽成 `useAppTabs()`，渲染层让 sidebar 和旧 pillbar 都能消费
   - 删除旧 `PillBar` 调用，sidebar 新增 `<SidebarTools>` section
   - tab 激活态与路由的绑定保持不变（`activeTab` 仍存 Context / URL）

2. **Inter 字体**（≈ 0.1 天）
   - `npm i @fontsource-variable/inter`
   - 改 `tailwind.config.js` `fontFamily.sans`
   - 删除 `src/index.css` `body` 里的 `font-family: -apple-system, ...` 系统栈

3. **shadcn/ui 初始化**（≈ 0.5 天）
   - `npx shadcn@latest init` + 按需 `add`
   - 所有新建 UI 组件都落到 `src/components/ui/`

三项合计 **1.6 人日**，作为底层 PR 先合，再叠加对应模式的专属 PR。

---

## 建议落地顺序

无论最终选哪个模式，都建议这样推进：

1. **PR-0 共通基建**（1.6 人日）——tab 搬家 + Inter + shadcn init
2. **PR-1 换皮到 Mode 1（shadcn/ChatGPT）**（1.5 人日）——先把"能用的最克制版本"合上线，作为默认主题
3. 再并行做：
   - **PR-2a Mode 2 (Aceternity)**：作为可选的 `data-theme="aceternity"` 切换（2.5 人日）
   - **PR-2b Mode 3 (Linear)**：作为可选的 `data-theme="linear"` 切换（2 人日）
4. 在 Settings 里加"Theme variant"三选一，默认 shadcn，让 power user 自己切——这样三种模式可以并存，不需要二选一。

---

## 附：开源许可汇总

| 库 | 许可 | 风险 |
| - | - | - |
| shadcn/ui | MIT | 无 |
| Radix UI | MIT | 无 |
| framer-motion | MIT | 无 |
| cmdk | MIT | 无 |
| tailwindcss-animate | MIT | 无 |
| Aceternity UI (free components) | MIT | 无；Pro 组件需付费，避免使用 |
| Tremor | Apache-2.0 | 无 |
| @fontsource-variable/inter | OFL-1.1 | 无（字体开源） |
| @radix-ui/react-icons | MIT | 无 |
| lucide-react | ISC | 无 |

整体许可无冲突，项目 AGPL-3.0 可继续使用。
