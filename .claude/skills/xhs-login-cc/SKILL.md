---
name: xhs-login-cc
description: >-
  小红书登录与会话验证（Claude Code 版）。通过 browser-use MCP 打开创作者中心，
  检测登录状态，未登录时引导扫码。工具语法详见 xhs-browser-use。
allowed-tools:
  - "mcp__browser-use__*"
---

# 小红书登录（CC 版）

检测小红书登录状态，未登录时引导用户扫码。工具调用格式参考 `xhs-browser-use/SKILL.md`（与本文件同级目录）。

## 流程

### Step 1: 打开创作者中心

先检查当前页面是否已在小红书（避免重复 navigate）：

```
mcp__browser-use__evaluate({
  "expression": "(() => location.href)()"
})
```

如果 URL 已包含 `creator.xiaohongshu.com`，跳过 navigate 直接进 Step 2。否则：

```
mcp__browser-use__navigate({ "url": "https://creator.xiaohongshu.com" })
mcp__browser-use__sleep({ "ms": 3000 })
```

### Step 2: 检测登录态

```
mcp__browser-use__evaluate({
  "expression": "(() => { const nav = document.querySelector('.menu-list, .creator-nav, [class*=sidebar]'); const login = document.querySelector('[class*=login], [class*=qrcode]'); return JSON.stringify({ loggedIn: !!nav && !login, url: location.href, title: document.title }); })()"
})
```

- `loggedIn: true` → 已登录，跳到 Step 3
- `loggedIn: false` → 未登录，跳到 Step 4

### Step 3: 已登录 — 提取账号信息

```
mcp__browser-use__evaluate({
  "expression": "(() => { const getText = s => { const el = document.querySelector(s); return el ? el.textContent.trim() : ''; }; return JSON.stringify({ nickname: getText('.user-name, .nickname, [class*=user-name]'), title: document.title }); })()"
})
```

做一次 snapshot 确认：

```
mcp__browser-use__snapshot({})
```

输出：`登录状态正常 — 昵称: xxx`

### Step 4: 未登录 — 引导扫码

截图给用户看二维码：

```
mcp__browser-use__screenshot({})
```

告知用户：**"请用小红书 App 扫描屏幕上的二维码完成登录"**

轮询检测（每 10 秒，最多 120 秒）：

```
mcp__browser-use__sleep({ "ms": 10000 })
mcp__browser-use__evaluate({
  "expression": "(() => { const nav = document.querySelector('.menu-list, .creator-nav, [class*=sidebar]'); return JSON.stringify({ loggedIn: !!nav }); })()"
})
```

登录成功 → 按 Step 3 提取信息。超时 → 告知用户"扫码超时，请重新触发"。

## 会话验证（快速检查）

不执行完整登录流程，只检测：

1. navigate 到 `creator.xiaohongshu.com`
2. evaluate 检测 `loggedIn`
3. true → `会话有效` / false → `会话已过期，需要重新登录`

## 故障处理

| 故障 | 处理 |
|------|------|
| 页面加载超时 | sleep 5s 后重试一次 |
| 二维码不显示 | screenshot 截图给用户，建议刷新 |
| evaluate 返回异常 | snapshot 查看页面实际状态 |
