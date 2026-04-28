# edgeclaw-opc 使用说明

本仓库把 `claude-code-main`、`ui`、memory、router 和 gateway 收敛到一套统一配置。
唯一用户配置入口是 `~/.edgeclaw/config.yaml`。UI、CLI、memory、router 和 gateway 都从这份 YAML 派生运行配置。

## 目录关系

| 路径 | 作用 |
|------|------|
| `~/.edgeclaw/config.yaml` | 唯一用户配置入口 |
| `claude-code-main/` | Bun CLI、本地 Anthropic -> OpenAI 代理、`start.sh` |
| `ui/` | Web UI 前后端 |
| `edgeclaw-memory-core/` | 记忆检索 / 索引核心 |

## 前置条件

- Bun
- Node.js 22+
- npm
- 一条可用的 OpenAI 兼容 API

## 第一步：创建统一 YAML 配置

启动 Web UI 后，进入 `Settings -> Config` 直接编辑 `~/.edgeclaw/config.yaml`。如果文件不存在，点击 `Reveal File` 会创建完整模板。

最小必填配置位于 YAML 的：

- `models.providers.<provider>.baseUrl`
- `models.providers.<provider>.apiKey`
- `models.entries.<model>.name`
- `agents.main.model`

注意：

- OpenAI 兼容 provider 的 `baseUrl` 推荐写到 `/v1`
- Anthropic provider 的 `baseUrl` 写域名根路径
- `agent`、`memory`、`router` 都引用 `models.entries` 里的模型 id，不重复配置 key/url
- UI 返回配置时会 mask secret，保存 masked secret 会保留旧值

## 第二步：安装依赖

```bash
cd claude-code-main
bun install

cd ../ui
npm install
```

## 第三步：启动 Claude Code 链路

```bash
cd claude-code-main
chmod +x start.sh
./start.sh
```

`start.sh` 会读取 `~/.edgeclaw/config.yaml`，派生内部 `OPENAI_*` / `ANTHROPIC_*` 变量，并在需要时自动拉起本地代理。

如果要只运行消息网关，不启动 CLI：

```bash
cd claude-code-main
./start.sh --gateway
```

如果要在正常启动 CLI 的同时后台拉起 gateway，把 YAML 中的 `gateway.enabled` 设为 `true`。

## 第四步：启动 Web UI

```bash
cd ui
npm run dev
```

默认地址：

- Web UI: `http://localhost:5173`
- API Server: `http://localhost:3001`

前端和服务端都会读取 `~/.edgeclaw/config.yaml`；不需要创建任何 `.env` 文件。

## Gateway 配置

gateway 也统一读取 `~/.edgeclaw/config.yaml`，保存后 UI 会重新生成 gateway runtime YAML。

常见入口字段：

- `gateway.enabled`
- `gateway.allowAllUsers`
- `gateway.allowedUsers`
- `gateway.channels.<channel>.enabled`

支持的 channel 在默认 YAML 中都会展示：

- Telegram
- Discord
- Slack
- Feishu / Lark
- WeCom / DingTalk
- Matrix / Signal / Mattermost
- Email / SMS / Home Assistant
- API Server / Webhook / Weixin / WhatsApp

## Memory 配置

memory 默认开启。只有显式设置以下值时才会关闭：

```yaml
memory:
  enabled: false
```

默认情况下，memory 继承主模型：

```yaml
memory:
  model: inherit
```

如果 memory 要独立走另一套模型，先在 `models.providers` / `models.entries` 中定义，再把 `memory.model` 指向该模型 id。

## 常见命令

查看当前配置入口和状态：

```bash
cd ui
node server/cli.js status
```

或：

```bash
cd ui
cloudcli status
```

## 安全说明

- 用户密钥只放在 `~/.edgeclaw/config.yaml`
- 不要把密钥写进任何 `VITE_*` 变量
- API 返回给 UI 的 secret 会被 mask；保存 masked secret 会保留原值
