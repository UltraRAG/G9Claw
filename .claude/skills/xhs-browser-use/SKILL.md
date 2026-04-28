---
name: xhs-browser-use
description: >-
  小红书浏览器操作技能。使用 browser-use MCP (Playwright) 完成小红书登录验证、
  图片上传、标题/正文填写、发布前审核。所有操作通过 mcp__browser-use__* 工具完成，
  元素定位使用 CSS selector。
allowed-tools:
  - "mcp__browser-use__*"
---

# XHS Browser-Use 操作手册

使用 edgeclaw-opc 内置的 browser-use MCP Server（基于 Playwright）完成小红书全链路浏览器操作。

## 工具速查表（15 tools）

所有工具名以 `mcp__browser-use__` 为前缀。元素定位统一使用 **CSS selector**。

### 导航与页面

| 工具 | 参数 | 说明 |
|------|------|------|
| `mcp__browser-use__navigate` | `{ url, waitUntil? }` | 跳转 URL。waitUntil: `load` / `domcontentloaded` / `networkidle` / `commit` |
| `mcp__browser-use__screenshot` | `{ selector?, fullPage? }` | 截图，返回 base64 PNG |
| `mcp__browser-use__snapshot` | `{ selector? }` | 无障碍树快照（aria snapshot），用于理解页面结构 |
| `mcp__browser-use__evaluate` | `{ expression }` | 在页面上下文执行 JS，返回序列化结果 |

### 元素交互

| 工具 | 参数 | 说明 |
|------|------|------|
| `mcp__browser-use__click` | `{ selector, button?, doubleClick?, position? }` | 点击元素 |
| `mcp__browser-use__type` | `{ selector?, text, clear?, submit? }` | 输入文字。clear=true 先清空再填写 |
| `mcp__browser-use__fill` | `{ selector, value }` | 清空并填入新值（等效 Playwright fill） |
| `mcp__browser-use__press` | `{ key }` | 按键/组合键，如 `Enter`、`Control+a`、`Meta+c` |
| `mcp__browser-use__hover` | `{ selector }` | 悬停 |
| `mcp__browser-use__select` | `{ selector, values }` | 选择 `<select>` 下拉项 |

### 文件上传

| 工具 | 参数 | 说明 |
|------|------|------|
| `mcp__browser-use__upload` | `{ selector, paths }` | 上传文件到 `<input type="file">`。paths 是绝对路径数组 |

### 等待

| 工具 | 参数 | 说明 |
|------|------|------|
| `mcp__browser-use__wait` | `{ selector?, text?, url?, loadState?, timeoutMs? }` | 等待条件满足（至少传一个条件） |
| `mcp__browser-use__sleep` | `{ ms? }` | 纯时间等待，默认 1000ms |

### 滚动与标签页

| 工具 | 参数 | 说明 |
|------|------|------|
| `mcp__browser-use__scroll` | `{ selector?, direction?, amount? }` | 滚动页面或元素 |
| `mcp__browser-use__tabs` | `{ action, url?, index? }` | 标签页管理：list / open / close / focus |

## 元素定位：CSS selector

browser-use 使用 **CSS selector** 定位元素，不是 OpenClaw 的 `ref: "e12"` 编号。

常用定位策略：

```
// 精确 ID
#publisherInput input

// 属性选择器
input[type="file"]
input[placeholder*="标题"]

// Class
.ql-editor
.ProseMirror[contenteditable="true"]

// 组合选择器
div[contenteditable="true"].ProseMirror

// 文字匹配（需要 evaluate 辅助）
// 用 evaluate 找到元素再操作，见下方"ProseMirror 处理"
```

如果不确定 selector，先用 `snapshot` 查看页面结构，或用 `evaluate` 执行 `document.querySelector` 测试。

## 浏览器会话与 Cookie

- 本地启动时使用 **persistent context**，cookie/localStorage 保存在 `~/.claude/browser-use-profile/`
- 进程重启后 cookie 仍然有效（无需每次重新登录）
- 设置 `CDP_URL` 环境变量可连接远程浏览器（cookie 由远程浏览器管理）

## 小红书登录检查流程

### Step 1: 打开创作者中心

```json
mcp__browser-use__navigate({ "url": "https://creator.xiaohongshu.com" })
```

### Step 2: 等待页面加载

```json
mcp__browser-use__sleep({ "ms": 3000 })
```

### Step 3: 检测登录状态

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const nav = document.querySelector('.menu-list, .creator-nav, [class*=sidebar]'); const login = document.querySelector('[class*=login], [class*=qrcode]'); return JSON.stringify({ loggedIn: !!nav && !login, url: location.href, title: document.title }); })()"
})
```

- `loggedIn: true` → 已登录，继续操作
- `loggedIn: false` → 需要扫码登录，截图给用户

### Step 4: 未登录时截图二维码

```json
mcp__browser-use__screenshot({})
```

告知用户："请用小红书 App 扫描屏幕上的二维码完成登录"。

然后轮询检测登录状态（每 10 秒 evaluate 一次，最多 120 秒）。

## 图片上传流程

### Step 1: 打开发布页

```json
mcp__browser-use__navigate({ "url": "https://creator.xiaohongshu.com/publish/publish" })
```

```json
mcp__browser-use__sleep({ "ms": 3000 })
```

### Step 2: 切换到"上传图文"标签

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const tabs = document.querySelectorAll('span, div, a'); for(const t of tabs){ if(t.textContent.trim() === '上传图文' && t.offsetParent !== null){ t.click(); return 'clicked'; } } return 'tab not found'; })()"
})
```

### Step 3: 让隐藏的 file input 可见

```json
mcp__browser-use__sleep({ "ms": 3000 })
```

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const inputs = document.querySelectorAll('input[type=file]'); inputs.forEach(input => { input.style.cssText = 'opacity:1!important;width:200px!important;height:50px!important;position:relative!important;z-index:99999!important;display:block!important;visibility:visible!important'; }); return 'found ' + inputs.length + ' file inputs'; })()"
})
```

### Step 4: 上传图片

```json
mcp__browser-use__upload({
  "selector": "input[type=file]",
  "paths": ["/path/to/image1.png", "/path/to/image2.png"]
})
```

### Step 5: 等待上传完成并验证

```json
mcp__browser-use__sleep({ "ms": 5000 })
```

```json
mcp__browser-use__snapshot({})
```

确认 snapshot 中出现图片缩略图后继续。

## 标题/正文填写（ProseMirror 处理）

小红书编辑器使用 ProseMirror（contenteditable div），标准 `fill` 可能不生效。

### 填写标题

标题是标准 `<input>` 元素，用 `evaluate` 配合 React native setter 最可靠：

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const el = document.querySelector('#publisherInput input, input[placeholder*=\"标题\"], .c-input_inner input'); if(!el) return 'title input not found'; const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set; nativeSet.call(el, '你的标题'); el.dispatchEvent(new Event('input', {bubbles:true})); return 'title set'; })()"
})
```

备用方案：

```json
mcp__browser-use__fill({
  "selector": "#publisherInput input",
  "value": "你的标题"
})
```

### 填写正文

正文区是 ProseMirror contenteditable div，需用 `execCommand` 插入：

1. 先点击正文区聚焦：

```json
mcp__browser-use__click({ "selector": ".ql-editor, [contenteditable=true].ProseMirror, div[contenteditable='true']" })
```

2. 全选已有内容（如需覆盖）：

```json
mcp__browser-use__press({ "key": "Meta+a" })
```

3. 用 evaluate 插入文字：

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const el = document.querySelector('.ql-editor, [contenteditable=true].ProseMirror, div[contenteditable=\"true\"]'); if(!el){ return 'editor not found'; } el.focus(); document.execCommand('insertText', false, '你的正文内容\\n\\n#话题1 #话题2'); return 'body text inserted'; })()"
})
```

4. 验证填写结果：

```json
mcp__browser-use__snapshot({})
```

**备用方案**（execCommand 不生效时）：click 聚焦 → press `Meta+a` 全选 → type 输入。

## 发布前审核

### 提取页面内容

```json
mcp__browser-use__evaluate({
  "expression": "(() => { const title = (document.querySelector('#publisherInput input, input[placeholder*=\"标题\"], .c-input_inner input') || {}).value || ''; const bodyEl = document.querySelector('.ql-editor, [contenteditable=true].ProseMirror, div[contenteditable=\"true\"]'); const body = bodyEl ? bodyEl.innerText : ''; const imgs = document.querySelectorAll('.img-container img, .upload-item img, [class*=upload] img, [class*=cover] img').length; return JSON.stringify({title, body, imgs}); })()"
})
```

### 审核检查项

**标题**：长度 <= 20 字、无绝对化用语、无敏感词、无引流信号

**正文**：无外部引流、无未证实功效声明、长度合理（50-1500 字）、话题标签 3-8 个

**图片**：用 screenshot 检查是否有水印、二维码、违禁元素

### 修改操作

修改标题（evaluate + React native setter）和修改正文（click → Meta+a → evaluate insertText）的方法同上"标题/正文填写"章节。

修改后**必须重新 evaluate 验证修改是否生效**。

## evaluate 语法规则

`expression` 参数接受裸 JS 表达式，Playwright 会用 `page.evaluate()` 执行。

```
// 简单表达式
"expression": "document.title"

// IIFE（推荐用于多语句）
"expression": "(() => { const el = document.querySelector('.x'); return el ? el.textContent : 'not found'; })()"

// 箭头函数也行（Playwright 自动调用）
"expression": "() => document.title"
```

注意与 OpenClaw 的区别：OpenClaw 要求 `"fn": "() => ..."`（强制箭头函数），browser-use 的 `expression` 更灵活，裸表达式和 IIFE 都可以。推荐使用 IIFE `(() => { ... })()` 确保多语句安全。

## 常见错误与解决方案

| 错误 | 原因 | 解决 |
|------|------|------|
| `Timeout exceeded` on click | selector 不匹配或元素不可见 | 先 snapshot 确认结构，或用 evaluate 检查元素是否存在 |
| upload 失败 | file input 是隐藏的 | 先用 evaluate 让 file input 可见（设置 style），再 upload |
| fill 对 contenteditable 不生效 | ProseMirror 不响应标准 fill | 用 evaluate + `execCommand('insertText')` 替代 |
| evaluate 返回 undefined | 表达式无返回值 | 确保表达式有 return（用 IIFE 包裹） |
| navigate 后 snapshot 为空 | 页面未完全加载 | 在 navigate 和 snapshot 之间加 sleep 3000 |
| 登录态丢失 | 小红书 session 过期（24-48h） | 重新扫码登录；persistent context 保留 cookie |

## 核心约束

1. **绝对不点击「发布」按钮** — 所有流程停在发布按钮前
2. **每步真实 tool call** — 禁止在文本中假装已完成操作
3. **每步之后验证** — snapshot 或 evaluate 确认操作生效
4. **单步执行** — 每次只执行一个操作，等返回后再下一步
