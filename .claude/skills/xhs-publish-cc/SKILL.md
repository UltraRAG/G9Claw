---
name: xhs-publish-cc
description: >-
  小红书图文发布（Claude Code 版）。上传图片、填写标题正文，停在发布按钮前。
  工具语法详见 xhs-browser-use。绝不自动点击发布。
allowed-tools:
  - "mcp__browser-use__*"
---

# 小红书图文发布（CC 版）

上传图片 → 填标题 → 填正文 → **停在发布按钮前**。工具格式参考 `xhs-browser-use/SKILL.md`（与本文件同级目录）。

**绝对不点击「发布」按钮。**

**禁止用 Read 读取 PNG/图片文件**（会生成巨大 base64，浪费 token）。用 `ls -la` 确认文件存在即可。

## 输入

| 参数 | 必填 | 说明 |
|------|------|------|
| 图片路径 | 是 | 本地图片文件路径（支持多张） |
| 标题 | 是 | ≤20 字 |
| 正文 | 是 | 含话题标签 `#话题` |

## 流程

### Step 1: 打开发布页

先检查当前页面是否已在发布页（避免重复 navigate 导致状态丢失）：

```
mcp__browser-use__evaluate({
  "expression": "(() => location.href)()"
})
```

如果 URL 已包含 `publish/publish`，跳过 navigate 直接进 Step 2。否则：

```
mcp__browser-use__navigate({ "url": "https://creator.xiaohongshu.com/publish/publish" })
mcp__browser-use__sleep({ "ms": 3000 })
mcp__browser-use__snapshot({})
```

看到"上传"相关内容 → 已登录，继续。看到"登录"/二维码 → 终止，需先登录。

### Step 2: 切换到图文 + 上传图片

点击"上传图文"标签：

```
mcp__browser-use__evaluate({
  "expression": "(() => { const tabs = document.querySelectorAll('span, div, a'); for(const t of tabs){ if(t.textContent.trim() === '上传图文' && t.offsetParent !== null){ t.click(); return 'clicked'; } } return 'tab not found'; })()"
})
```

等待 DOM 更新，让隐藏的 file input 可见：

```
mcp__browser-use__sleep({ "ms": 3000 })
mcp__browser-use__evaluate({
  "expression": "(() => { const inputs = document.querySelectorAll('input[type=file]'); inputs.forEach(input => { input.style.cssText = 'opacity:1!important;width:200px!important;height:50px!important;position:relative!important;z-index:99999!important;display:block!important;visibility:visible!important'; }); return 'found ' + inputs.length + ' file inputs'; })()"
})
```

上传图片：

```
mcp__browser-use__upload({
  "selector": "input[type=file]",
  "paths": ["/tmp/work/output.png"]
})
```

等待上传完成并验证：

```
mcp__browser-use__sleep({ "ms": 5000 })
mcp__browser-use__snapshot({})
```

确认 snapshot 中出现图片缩略图后继续。

### Step 3: 填写标题

用 evaluate + React native setter（最可靠）：

```
mcp__browser-use__evaluate({
  "expression": "(() => { const el = document.querySelector('#publisherInput input, input[placeholder*=\"标题\"], .c-input_inner input'); if(!el) return 'title input not found'; const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set; nativeSet.call(el, '你的标题'); el.dispatchEvent(new Event('input', {bubbles:true})); return 'title set'; })()"
})
```

备用: `mcp__browser-use__fill({ "selector": "#publisherInput input", "value": "你的标题" })`

### Step 4: 填写正文

点击正文区聚焦：

```
mcp__browser-use__click({ "selector": ".ql-editor, [contenteditable=true].ProseMirror, div[contenteditable='true']" })
```

用 evaluate + execCommand 插入（ProseMirror 不响应标准 fill）：

```
mcp__browser-use__evaluate({
  "expression": "(() => { const el = document.querySelector('.ql-editor, [contenteditable=true].ProseMirror, div[contenteditable=\"true\"]'); if(!el){ return 'editor not found'; } el.focus(); document.execCommand('insertText', false, '你的正文内容\\n\\n#话题1 #话题2'); return 'body text inserted'; })()"
})
```

备用: click 聚焦 → `press Meta+a` 全选 → `type` 输入。

### Step 5: 验证并停手

```
mcp__browser-use__snapshot({})
```

确认：图片缩略图可见、标题已填、正文已填、发布按钮可见。

输出：

```
图文准备完成，已停在发布按钮前
- 封面: 已上传 N 张图片
- 标题: {标题}
- 正文: {前30字}...

未点击发布。请在浏览器中确认后手动点击「发布」。
```

## 故障处理

| 故障 | 处理 |
|------|------|
| 图片路径不存在 | 终止，提示检查路径 |
| upload 失败 | 重试 1 次，仍失败 snapshot 截图汇报 |
| 标题超 20 字 | 提示用户缩短 |
| 未登录 | 终止，引导先登录 |
| fill/type 不生效 | 切备用方案（click → Meta+a → type） |
