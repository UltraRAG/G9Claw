---
name: edgeclaw-opc-setup
description: >-
  Onboards edgeclaw-opc after git clone: install Bun/Node deps, create .env from
  examples, run claude-code-main proxy/CLI and claudecodeui dev stack. Use when
  the user clones edgeclaw-opc, asks how to configure or run the repo, first-time
  setup, 拉下来怎么跑, 环境配置, or Mingwwww/edgeclaw-opc setup.
---

# edgeclaw-opc 克隆后跑起来

单仓库 monorepo：`claude-code-main`（Bun +代理 + CLI）与 `claudecodeui`（CloudCLI UI）。详细说明见仓库根目录 **`README.md`**；本 skill 给可执行检查清单。

## 前置条件

- [Bun](https://bun.sh)（`claude-code-main`）
- **Node.js 22+** 与 **npm**（`claudecodeui`）
- 一条 **OpenAI 兼容 API**（如 OpenRouter）

## 必做步骤（顺序）

1. **依赖（可再生，未进 Git）**
   ```bash
   cd claude-code-main && bun install
   cd ../claudecodeui && npm install
   ```

2. **环境变量（从模板复制，勿提交真实密钥）**
   ```bash
   cp claude-code-main/.env.example claude-code-main/.env
   cp claudecodeui/.env.example claudecodeui/.env
   ```
   - **`claude-code-main/.env`**：至少填 `OPENAI_BASE_URL`（不要末尾 `/v1`，与 `proxy.ts` 拼接一致）、`OPENAI_API_KEY`、`ANTHROPIC_API_KEY`（可与上游相同）、`ANTHROPIC_MODEL`。可选 `PROXY_PORT`（默认 `18080`）。
   - **`claudecodeui/.env`**：`ANTHROPIC_API_KEY`、`ANTHROPIC_BASE_URL`（例如 `http://127.0.0.1:18080`）、`ANTHROPIC_MODEL` 与上面一致；可选 `SERVER_PORT` / `VITE_PORT`。

3. **终端 CLI（可选）** — 需真实 TTY：
   ```bash
   cd claude-code-main && chmod +x start.sh && ./start.sh
   ```
   `start.sh` 会在需要时后台起 `proxy.ts`；日志 `.proxy.log`（可删可再生）。

4. **Web UI**
   ```bash
   cd claudecodeui && npm run dev
   ```
   浏览器打开 Vite 输出的地址（常见 `http://localhost:5173`）；API 经代理到后端（默认 `3001`）。**先保证代理可达再开 UI**，否则 Agent 请求会失败。

## Agent 行为（本仓库约定）

- 若存在同级目录 `claude-code-main`，`claudecodeui` 后端会优先用其中 `cli.tsx` + `preload.ts` 作为子进程（见 `server/claude-code-main-path.js`）。无需额外配置即可用源码树；若要改用 npm 内置 CLI，设 `CLOUDCLI_USE_BUNDLED_CLAUDE_CODE=1`。
- 默认 **关闭 Web UI 本地账号**（`CLOUDCLI_DISABLE_LOCAL_AUTH`未设为 `0` 时）。若要用户名密码登录，在 `claudecodeui/.env` 写 `CLOUDCLI_DISABLE_LOCAL_AUTH=0` 并重启 `npm run dev`。

## 常见问题

| 现象 | 处理 |
|------|------|
| UI 里 **No project** | 项目来自 `~/.claude/projects/` 与手动配置，不是全盘扫描。用 CLI 在工程里跑几次或在 UI 里添加项目路径。 |
| **401** / WebSocket 失败 | 确认后端已用当前代码启动；`CLOUDCLI_DISABLE_LOCAL_AUTH` 与 `server`/`vite` 一致；WebSocket 需与 HTTP 同一套免登录逻辑（见仓库内 `server/index.js` `verifyClient`）。 |
| 代理连不上 | 检查 `OPENAI_BASE_URL` / Key；`curl http://127.0.0.1:18080/health`（端口以 `.env` 为准）。 |

## 不要做的事

- 不要把填好的 **`.env`** 或 **`node_modules/`** 提交进 Git（已被 `.gitignore` 忽略）。
- 不要把 **API Key** 写进 `start.sh` 或文档示例以外的真实提交。

执行完整流程后仍失败时，让用户贴 **后端终端日志** 与 **`curl` health** 结果再排查。
