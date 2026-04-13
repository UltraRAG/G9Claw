# edgeclaw-opc 使用说明

本仓库中的 **`claude-code-main`** 是本地运行的 Claude Code（Bun + 源码树），通过 **`proxy.ts`** 把 Anthropic协议转成上游的 **OpenAI 兼容**接口。**`claudecodeui`**（CloudCLI UI）提供 Web 前后端，可与同一套代理和模型配合使用。

## 目录关系

| 路径 | 作用 |
|------|------|
| `claude-code-main/` | Bun CLI、`proxy.ts`、`start.sh`、`.env` |
| `claudecodeui/` | Node 后端 + Vite 前端（`npm run dev`） |

Agent 子进程会继承 Node 进程里的 **`ANTHROPIC_*`**。在 `claudecodeui` 与 `claude-code-main` 的 `.env` 中填同一套上游配置最省事。若存在同级目录 `claude-code-main`，UI 后端会优先用其中的 `cli.tsx` 与 `preload.ts`（见 `claudecodeui/server/claude-code-main-path.js`）。

## 前置条件

- **Bun**：运行 CLI 与 `proxy.ts`，见 [bun.sh](https://bun.sh)
- **Node.js 22+** 与 **npm**：运行 `claudecodeui`
- 一条可用的 **OpenAI 兼容 API**（示例为 OpenRouter，可换成你的网关）

## Clone 之后：被 Git 忽略内容的「再生」

根目录 `.gitignore` 里不提交的东西，在本机可以这样恢复：

| 忽略项 | 如何再生 |
|--------|----------|
| **`node_modules/`** | `claude-code-main`：`cd claude-code-main && bun install`（使用仓库内 `bun.lock`）。`claudecodeui`：`cd claudecodeui && npm install`。 |
| **`.env`** | 两处各执行：`cp .env.example .env`，再按下文填写密钥与模型。 |
| **`dist/`、`build/`** | 仅在你需要生产构建时：`cd claudecodeui && npm run build`（开发模式 `npm run dev` 不依赖已存在的 `dist/`）。 |
| **`.cache/`** | 工具缓存（如 Vite）；一般不用管。若前端异常可删 `claudecodeui/node_modules/.vite` 后重新 `npm run dev`。 |
| **`*.log`、`.proxy.log`** | 运行日志；可删。下次 `./start.sh` 后台起代理时会再生成 `.proxy.log`。 |

CloudCLI 的本地数据库（默认 `~/.cloudcli/auth.db`等）也不在仓库里；首次启动后端会自动建库，无需从 Git 恢复。

## 第一步：配置 `claude-code-main/.env`

```bash
cd claude-code-main
bun install
cp .env.example .env
```

编辑 `.env`，至少设置：

- **`OPENAI_BASE_URL`** — 上游根地址。**不要**带末尾的 `/v1`：本仓库的 `proxy.ts` 会自行拼接 `/v1/chat/completions`（与 OpenRouter 的 `https://openrouter.ai/api` 一类写法一致）。
- **`OPENAI_API_KEY`** — 上游 API Key
- **`ANTHROPIC_API_KEY`** — 可与 `OPENAI_API_KEY` 相同（请求经本地代理再转发上游）
- **`ANTHROPIC_MODEL`** — 上游实际提供的模型 id

可选：`PROXY_PORT`（默认 `18080`）、`ANTHROPIC_BASE_URL`（不设时 `start.sh` 使用 `http://127.0.0.1:$PROXY_PORT`）、`DISABLE_TELEMETRY`。

勿将真实密钥提交到 Git；`claude-code-main/.gitignore` 已忽略 `.env`。

## 第二步：启动终端 CLI（可选）

在**真实终端**（需要 TTY）中：

```bash
cd claude-code-main
chmod +x start.sh   # 首次
./start.sh
```

非交互示例：`./start.sh -p "你好" --bare`。若本地代理未在运行，`start.sh` 会在后台启动 `proxy.ts`，日志写入 `.proxy.log`。

## 第三步：启动 Web UI（前后端）

```bash
cd claudecodeui
npm install
cp .env.example .env   # 若尚未创建
```

在 **`claudecodeui/.env`** 中写入与代理一致的 **`ANTHROPIC_API_KEY`**、**`ANTHROPIC_BASE_URL`**（例如 `http://127.0.0.1:18080`）、**`ANTHROPIC_MODEL`**。建议先保证 `claude-code-main` 侧代理已可访问，再启动 UI。

```bash
npm run dev
```

- 前端：一般为 `http://localhost:5173`（以 Vite 终端输出为准）
- API / WebSocket：由 Vite 代理到后端 **`SERVER_PORT`**（默认 `3001`）

## UI 里为什么可能没有 Project？

项目列表来自 **`~/.claude/projects/`** 以及 **`~/.claude/project-config.json`** 中的手动条目，**不会**扫描整台机器上的所有仓库。若目录为空，可先在某个目录里用 Claude Code 跑几次产生会话，或在 UI 里添加项目路径。

## 恢复 Web UI 登录（可选）

默认关闭本地账号。若要用户名与密码，在 **`claudecodeui/.env`** 中设置：

```bash
CLOUDCLI_DISABLE_LOCAL_AUTH=0
```

保存后重启 `npm run dev`。

## 环境变量速查

| 位置 | 变量 | 说明 |
|------|------|------|
| `claude-code-main/.env` | `OPENAI_BASE_URL`, `OPENAI_API_KEY` | 上游；供 `proxy.ts` |
| | `PROXY_PORT` | 本地代理端口 |
| | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL` | CLI 使用 |
| `claudecodeui/.env` | 同上 `ANTHROPIC_*` | Agent SDK 子进程继承 |
| | `SERVER_PORT`, `VITE_PORT`, `HOST` | 后端 / 前端端口 |
| | `CLOUDCLI_DISABLE_LOCAL_AUTH` | 设为 `0` 则要求登录 |

更多 CloudCLI 变量见 **`claudecodeui/.env.example`**。
