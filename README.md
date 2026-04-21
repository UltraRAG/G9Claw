# edgeclaw-opc 使用说明

本仓库把 `claude-code-main` 和 `claudecodeui` 收敛到一套统一配置。  
用户只需要维护仓库根目录一份 `.env`，不再编辑 `claudecodeui/.env` 或 `claude-code-main/.env`。

## 目录关系

| 路径 | 作用 |
|------|------|
| `./.env` | 唯一用户配置入口 |
| `claude-code-main/` | Bun CLI、本地 Anthropic -> OpenAI 代理、`start.sh` |
| `claudecodeui/` | Web UI 前后端 |
| `edgeclaw-memory-core/` | 记忆检索 / 索引核心 |

## 前置条件

- Bun
- Node.js 22+
- npm
- 一条可用的 OpenAI 兼容 API

## 第一步：创建根目录 `.env`

```bash
cp .env.example .env
```

至少填写这三个必填项：

- `EDGECLAW_API_BASE_URL`
- `EDGECLAW_API_KEY`
- `EDGECLAW_MODEL`

常用可选项：

- `EDGECLAW_PROXY_PORT=18080`
- `SERVER_PORT=3001`
- `VITE_PORT=5173`
- `HOST=0.0.0.0`
- `CONTEXT_WINDOW=160000`
- `EDGECLAW_MEMORY_ENABLED=1`

注意：

- `EDGECLAW_API_BASE_URL` 不要带末尾 `/v1`
- 根 `.env` 只在服务端读取，不会被前端静态暴露
- 根 `.gitignore` 已忽略 `.env`

## 第二步：安装依赖

```bash
cd claude-code-main
bun install

cd ../claudecodeui
npm install
```

## 第三步：启动 Claude Code 链路

```bash
cd claude-code-main
chmod +x start.sh
./start.sh
```

`start.sh` 会读取仓库根目录 `.env`，派生内部 `OPENAI_*` / `ANTHROPIC_*` 变量，并在需要时自动拉起本地代理。

## 第四步：启动 Web UI

```bash
cd claudecodeui
npm run dev
```

默认地址：

- Web UI: `http://localhost:5173`
- API Server: `http://localhost:3001`

前端和服务端都会从仓库根目录 `.env` 读取配置；不需要再创建子目录 `.env`。

## Memory 配置

memory 默认开启。只有显式设置以下值时才会关闭：

```bash
EDGECLAW_MEMORY_ENABLED=0
```

默认情况下，memory 继承主配置：

- `EDGECLAW_API_BASE_URL`
- `EDGECLAW_API_KEY`
- `EDGECLAW_MODEL`

如果只想切换记忆模型，但继续复用同一套网关和密钥：

```bash
EDGECLAW_MEMORY_MODEL=your-memory-model
```

如果 memory 要独立走另一套模型服务，再填写完整覆盖项：

```bash
EDGECLAW_MEMORY_MODEL=
EDGECLAW_MEMORY_BASE_URL=
EDGECLAW_MEMORY_API_KEY=
EDGECLAW_MEMORY_API_TYPE=openai-responses
EDGECLAW_MEMORY_PROVIDER=edgeclaw_memory
```

默认规则：

- 不设置任何 `EDGECLAW_MEMORY_*` 时，memory 继承主配置
- 只设置 `EDGECLAW_MEMORY_MODEL` 时，仅切换记忆模型
- 设置完整 `EDGECLAW_MEMORY_*` 时，memory 使用独立服务

## 常见命令

查看当前配置入口和状态：

```bash
cd claudecodeui
node server/cli.js status
```

或：

```bash
cd claudecodeui
cloudcli status
```

## 安全说明

- 用户密钥只放在仓库根目录 `.env`
- 不要把密钥写进任何 `VITE_*` 变量
- `claudecodeui/.env.example` 和 `claude-code-main/.env.example` 现在只是提示文件，不再作为实际配置入口
