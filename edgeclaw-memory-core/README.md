# edgeclaw-memory-core

`edgeclaw-memory-core` 是 EdgeClaw 的记忆核心库，提供：

- 记忆索引与检索能力
- `EdgeClawMemoryService` 服务封装
- Memory Dashboard 的静态前端资源（`ui-source/`）

它本身不是独立 Web 服务，没有单独的 `start` 命令。通常由上层宿主项目加载：

- `claude-code-main`
- `claudecodeui`

## 安装

在当前目录安装依赖：

```bash
cd edgeclaw-memory-core
npm install
```

## 构建

把 TypeScript 编译到 `lib/`：

```bash
cd edgeclaw-memory-core
npm run build
```

只做类型检查：

```bash
cd edgeclaw-memory-core
npm run typecheck
```

## 启动方式

这个包没有独立启动脚本。要真正“跑起来”，需要启动引用它的宿主项目。

### 方式 1：随 `claude-code-main` 启动

```bash
cd claude-code-main
./start.sh
```

`claude-code-main` 会从 `edgeclaw-memory-core/lib/` 导入 `EdgeClawMemoryService`，在对话链路里使用记忆能力。

### 方式 2：随 `claudecodeui` 启动

```bash
cd claudecodeui
npm run dev
```

`claudecodeui` 会：

- 导入 `edgeclaw-memory-core/lib/`
- 挂载 memory API
- 使用 `edgeclaw-memory-core/ui-source/` 提供 Memory Dashboard 页面

## 常见目录

- `src/`：TypeScript 源码
- `lib/`：编译产物
- `ui-source/`：Memory Dashboard 静态资源

## 典型开发流程

如果你修改了这个包的源码，通常顺序是：

```bash
cd edgeclaw-memory-core
npm run build

cd ../claudecodeui
npm run dev
```

或者：

```bash
cd edgeclaw-memory-core
npm run build

cd ../claude-code-main
./start.sh
```
