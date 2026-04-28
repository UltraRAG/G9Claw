---
name: xhs-audit-cc
description: >-
  小红书发布前审核（Claude Code 版）。提取发布页内容，逐项检查标题/正文/图片/话题
  的合规与限流风险，输出审核报告，有问题直接修改。绝不点击发布。
allowed-tools:
  - "mcp__browser-use__*"
---

# 小红书发布前审核（CC 版）

提取发布页内容 → 审核 → 输出报告 → 有问题就改。工具格式参考 `xhs-browser-use/SKILL.md`（与本文件同级目录）。

**绝对不点击「发布」按钮。**

## 流程

### Step 1: 提取发布页内容

假设浏览器已在发布编辑页。用一条 evaluate 提取全部：

```
mcp__browser-use__evaluate({
  "expression": "(() => { const title = (document.querySelector('#publisherInput input, input[placeholder*=\"标题\"], .c-input_inner input') || {}).value || ''; const bodyEl = document.querySelector('.ql-editor, [contenteditable=true].ProseMirror, div[contenteditable=\"true\"]'); const body = bodyEl ? bodyEl.innerText : ''; const imgs = document.querySelectorAll('.img-container img, .upload-item img, [class*=upload] img, [class*=cover] img').length; return JSON.stringify({title, body, imgs}); })()"
})
```

返回空时做 snapshot 手动读取。

### Step 2: 文本审核

根据提取内容，用 LLM 推理逐项检查（无需 tool call）：

**标题检查**
- 长度 ≤20 字（超限 → 🔴）
- 绝对化用语："最好"、"第一"、"100%" → 🟡 广告法风险
- 敏感词：政治/色情/赌博 → 🔴
- 引流信号：微信号/QQ/"私我"/"链接在评论区" → 🔴

**正文检查**
- 外部引流：微信/淘宝口令/抖音号 → 🔴
- 未报备商业信号："下单"/"优惠"/未标注合作 → 🟡
- 未证实功效："治愈"/"根治" → 🔴 医疗违规
- 极端表达：人身攻击/地域歧视 → 🔴
- 平台调性：营销腔/公文腔 → 🟡
- 长度：<50 字 🟡 / >1500 字 🟡

**话题检查**
- `#话题` 数量 3-8 个
- 蹭流量话题 → 🟡
- 遗漏核心话题 → 🟡 建议补充

### Step 3: 图片审核

```
mcp__browser-use__snapshot({})
```

观察缩略图检查：
- 🔴 二维码、其他平台水印（抖音/快手/微博）
- 🔴 违禁元素（烟草/酒精/管制器具）
- 🟡 模糊/低分辨率、图文不符

### Step 4: 输出审核报告

```
发布前审核报告
━━━━━━━━━━━━━━━━━━━━

标题：{标题内容}
图片：{N} 张

── 文本审核 ──
标题长度：{N}/20 字 {🟢/🔴}
敏感词：{结果}
引流信号：{结果}
广告法用语：{结果}
功效声明：{结果}
正文长度：{N} 字 {🟢/🟡}
话题数量：{N} 个 {🟢/🟡}

── 图片审核 ──
图1：{🟢/🔴 具体问题}

━━━━━━━━━━━━━━━━━━━━
结论：{可发布 / 建议修改 / 必须修改}
```

### Step 5: 自动修改（存在问题时）

🔴 必须改，🟡 自动优化。

**修改标题**（evaluate + React native setter）：

```
mcp__browser-use__evaluate({
  "expression": "(() => { const el = document.querySelector('#publisherInput input, input[placeholder*=\"标题\"], .c-input_inner input'); if(!el) return 'not found'; const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set; nativeSet.call(el, '修改后的标题'); el.dispatchEvent(new Event('input', {bubbles:true})); return 'title updated'; })()"
})
```

**修改正文**（全选再输入）：

```
mcp__browser-use__click({ "selector": ".ql-editor, [contenteditable=true].ProseMirror, div[contenteditable='true']" })
mcp__browser-use__press({ "key": "Meta+a" })
mcp__browser-use__evaluate({
  "expression": "(() => { document.execCommand('insertText', false, '修改后的正文'); return 'body updated'; })()"
})
```

修改后回到 Step 1 重新提取验证，直到所有 🔴 清除。

### Step 6: 最终确认

```
审核通过，内容可以发布
- 标题: {标题}
- 正文: {前30字}...
- 图片: {N} 张

未点击发布。请手动点击「发布」。
```

## 快速审核模式

用户只给文本（标题+正文），未在发布页时：跳过 Step 1 页面提取和 Step 3 图片审核，只做 Step 2 文本审核。

## 故障处理

| 故障 | 处理 |
|------|------|
| 提取失败 | snapshot 截图，从中手动读取 |
| 不在发布页 | navigate 到发布页 |
| 修改未生效 | 用 click → Meta+a → type 备用方案 |
