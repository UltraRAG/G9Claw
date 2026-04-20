---
name: xhs-orchestrator-cc
description: >-
  小红书全链路编排（Claude Code 版）。定义 pipeline 步骤和 Agent() prompt 模板，
  供 CCR 主 agent 读取后按步骤 spawn 子 agent 执行。涉及"帮我做/发小红书"、
  "笔记"、"头图"等意图时自动激活。
---

# 小红书全链路编排（CC 版）

主 agent 读此文件后，按 pipeline 顺序 spawn Agent()，每步传入自包含的 prompt。

## 重要：解析项目根目录

CWD 可能不是项目根目录。在读取任何 skill 之前先执行：

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
echo "PROJECT_ROOT=$PROJECT_ROOT"
```

下文所有 `$PROJECT_ROOT` 都指这个值。在 Agent() prompt 中**必须替换为实际绝对路径**。

## 子 Skill 清单

| ID | 路径 | 职责 |
|----|------|------|
| `xhs-header-cc` | `$PROJECT_ROOT/.claude/skills/xhs-header-cc/SKILL.md` | Brief → 头图 PNG |
| `xhs-login-cc` | `$PROJECT_ROOT/.claude/skills/xhs-login-cc/SKILL.md` | 登录 / 会话验证 |
| `xhs-publish-cc` | `$PROJECT_ROOT/.claude/skills/xhs-publish-cc/SKILL.md` | 上传图片 + 填写（停在发布前） |
| `xhs-audit-cc` | `$PROJECT_ROOT/.claude/skills/xhs-audit-cc/SKILL.md` | 发布前合规审核 |
| `xhs-browser-use` | `$PROJECT_ROOT/.claude/skills/xhs-browser-use/SKILL.md` | 浏览器工具手册（共享） |

## Pipeline

```
Step 1: 抓取素材  → /tmp/work/tweets.md + /tmp/work/assets/
Step 2: 生成头图  → /tmp/work/output.png
Step 3: 撰写文案  → /tmp/work/copy.md (标题 + 正文 + 话题)
Step 4: 登录验证  → 确认已登录
Step 5: 上传发布  → 停在发布按钮前
Step 6: 审核(可选) → 审核报告
```

用户只要头图时执行 Step 1-2；要发布时执行全部。根据用户意图裁剪。

## Agent() Prompt 模板

### Step 1: 抓取素材

```
mkdir -p /tmp/work/assets

用 Bash 执行以下命令抓取 {username} 的推文：

curl -s -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  "https://xcancel.com/{username}" > /tmp/work/page.html

然后用 python3 解析 /tmp/work/page.html，提取：
- div.tweet-content.media-body → 推文正文
- span.tweet-date a[title] → 日期
- span.tweet-stat → 评论/转发/点赞/浏览
- img.avatar src → 头像 URL（替换 _bigger 为 _400x400）
- 跳过带 retweet-header 的转推

将结果写入 /tmp/work/tweets.md，格式：
## Tweet 1
正文: ...
日期: ...
评论: N | 转发: N | 点赞: N | 浏览: N

同时下载头像：
curl -s -o /tmp/work/assets/avatar.jpg "<avatar_url>"

如果 xcancel 被 block，用 WebSearch 搜索 "{username} latest tweets" 获取替代素材。
```

### Step 2: 生成头图

```
先用 Read 读取 $PROJECT_ROOT/.claude/skills/xhs-header-cc/SKILL.md，按其中的流程执行。

输入素材在 /tmp/work/tweets.md 和 /tmp/work/assets/。
话题: {topic}
风格偏好: {style_hint}（如无则自由选择）

输出: /tmp/work/output.png（1242x1660）

完成后用 Bash 验证:
ls -la /tmp/work/output.png
python3 -c "from PIL import Image; img=Image.open('/tmp/work/output.png'); print(f'size: {img.size}')"
```

### Step 3: 撰写文案

```
基于 /tmp/work/tweets.md 中的素材，为小红书撰写：

标题（2 个备选，每个 ≤20 字）:
- A: 争议/好奇型
- B: 干货/信息型

正文（200-500 字）:
- 开头钩子（1 句话引发好奇）
- 亮点列表（3-5 条，emoji 编号）
- 观点总结
- 互动提问（引导评论）
- 末尾 5-8 个 #话题标签

将结果写入 /tmp/work/copy.md
```

### Step 4: 登录验证

```
先用 Read 读取 $PROJECT_ROOT/.claude/skills/xhs-login-cc/SKILL.md，按其中的流程执行。
浏览器工具语法参考 $PROJECT_ROOT/.claude/skills/xhs-browser-use/SKILL.md。

目标: 确认小红书创作者中心已登录。如未登录，引导用户扫码。
```

### Step 5: 上传发布

```
先用 Read 读取 $PROJECT_ROOT/.claude/skills/xhs-publish-cc/SKILL.md，按其中的流程执行。
浏览器工具语法参考 $PROJECT_ROOT/.claude/skills/xhs-browser-use/SKILL.md。

图片路径: /tmp/work/output.png
标题: {从 /tmp/work/copy.md 读取用户选定的标题}
正文: {从 /tmp/work/copy.md 读取正文}

绝对不点击发布按钮。
```

### Step 6: 审核（可选）

```
先用 Read 读取 $PROJECT_ROOT/.claude/skills/xhs-audit-cc/SKILL.md，按其中的流程执行。
浏览器工具语法参考 $PROJECT_ROOT/.claude/skills/xhs-browser-use/SKILL.md。

假设浏览器已在发布编辑页。提取内容并审核，输出报告。
绝对不点击发布按钮。
```

## 反模式规则

| 禁止 | 替代方案 |
|------|---------|
| 用 Read 读 PNG/图片文件 | `ls -la` 验证存在 + `python3 PIL` 检查尺寸 |
| 用 WebFetch 抓 x.com/twitter.com | curl xcancel.com（x.com 返回 402/403） |
| Agent() prompt 里说"参考 skill" 但不给路径 | 写明完整路径 `$PROJECT_ROOT/.claude/skills/xxx/SKILL.md` |
| 一个 Agent() 做多件事 | 拆分：抓取/生成/上传 分开 |
| 子 agent 里再 spawn Agent() | 子 agent 直接执行，不嵌套 |

## 完成汇报格式

```
═══════════════════════════════════════
  全链路完成（停在发布前）
═══════════════════════════════════════

头图: /tmp/work/output.png
标题: {标题}
正文: {前 50 字}...
话题: {N} 个
审核: 通过 / 跳过

未点击发布。请在浏览器中确认后手动点击「发布」。
═══════════════════════════════════════
```
