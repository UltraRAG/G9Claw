---
name: xhs-header-cc
description: >-
  小红书头图生成（Claude Code 版）。从素材生成 HTML 布局，Chrome headless 渲染为 PNG。
  精简版，不含 Figma 推送。用于被 Agent() spawn 的子 agent。
---

# 小红书头图生成（CC 版）

从素材（推文/网页截图）生成 1242x1660 的小红书头图 PNG。

## Pipeline

```
1. 准备素材（上游已完成，或本步骤自行抓取）
2. 设计 HTML 布局
3. Chrome headless 渲染 → PNG
4. 验证尺寸
```

## Step 1: 准备素材

### 方法 A: 结构化抓取（X/Twitter 个人页）

```bash
mkdir -p /tmp/work/assets
curl -s -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
  "https://xcancel.com/<username>" > /tmp/work/page.html
```

用 Python 从 HTML 提取：
- `div.tweet-content.media-body` → 推文正文
- `span.tweet-stat` → 评论/转发/点赞/浏览
- `img.avatar` → 头像 URL（替换 `_bigger` 为 `_400x400`）
- 跳过 `retweet-header`（转推）

下载头像: `curl -s -o /tmp/work/assets/avatar.jpg "<url>"`

### 方法 B: Chrome Headless 截图（通用网页）

```bash
mkdir -p /tmp/work/assets
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --screenshot=/tmp/work/assets/source.png \
  --window-size=1000,800 --disable-gpu --force-device-scale-factor=2 \
  "<URL>"
```

### 方法 C: WebSearch（话题搜索）

用 WebSearch 搜索话题 → 取前 3 条结果的关键信息 → 对最佳 URL 用方法 B 截图。

## Step 2: 设计 HTML

**工作目录**: `/tmp/work/`，HTML 文件 `/tmp/work/header.html`，资源引用相对路径 `assets/`。

### 尺寸

| 平台 | 宽 x 高 | 比例 |
|------|---------|------|
| 小红书(默认) | 1242 x 1660 | 3:4 |
| 小红书方图 | 1242 x 1242 | 1:1 |

### 设计原则（10 条）

1. **纯色背景** — `#000`、`#fff`、`#e63930`，禁止渐变
2. **大字标题** — 56-90px，beauty 靠字号和留白
3. **1 个强调色** — 关键词用不同平色（如 `#f0b8b8`），可加 `wavy underline`
4. **扁平标签** — 白底/浅色底圆角 pill，无阴影无透明
5. **原始截图** — 直接贴，不加边框不加浏览器 chrome
6. **大留白** — 让元素呼吸
7. **Emoji 点缀** — 用 HTML entities（`&#128293;`），不用 raw emoji
8. **中文字体** — `'Noto Sans SC', 'PingFang SC', sans-serif`（Google Fonts import）
9. **object-fit: contain** — 截图不裁切
10. **overflow: hidden** — body 设置，防溢出

### 禁止（看起来像 AI 生成）

- `radial-gradient` / `linear-gradient` 背景
- `filter: blur()` / `backdrop-filter` / 毛玻璃
- 渐变文字 (`-webkit-background-clip: text`)
- 霓虹发光 (`box-shadow` 亮色模糊)
- 半透明 `rgba()` 背景
- 装饰网格线/点阵

### Recipe 速查（3 种常用）

**Recipe 1: 黑底大字 + 散落标签**
纯黑背景。居中超大白字标题（1 个关键词用 `#f0b8b8` + wavy underline）。下方散落圆角 pill 标签（白底/浅粉底）。顶部小的描边分类角标。适合：AI/科技公告。

**Recipe 2: 大色块 + 截图**
上 35% 纯色块（红/蓝/绿），白色大字。下 65% 全宽截图。交界处叠一个 120px 圆角 Logo。适合：IPO/商业新闻。

**Recipe 3: 截图全铺 + 粗描边大字**
截图填满画布。中央叠 60-80px 中文大字，白填充 + 4px 黑描边（`-webkit-text-stroke`）。适合：meme 风/热点快评。

不限于这 3 种——可自由创作，但必须遵守设计原则。

### HTML 写入方式

用 Bash + python3 写文件（heredoc 可能超时）：

```bash
python3 << 'PYEOF'
html = '''<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+SC:wght@400;700;900&display=swap" rel="stylesheet">
<style>
body { width: 1242px; height: 1660px; margin: 0; overflow: hidden;
       font-family: 'Noto Sans SC', sans-serif; background: #000; color: #fff; }
</style>
</head>
<body>
<!-- 布局内容 -->
</body></html>'''

with open('/tmp/work/header.html', 'w') as f:
    f.write(html)
print('written')
PYEOF
```

### HTML Checklist

- `<!DOCTYPE html>` + `<meta charset="utf-8">`
- Google Fonts import (Noto Sans SC)
- body: 固定 width/height + overflow: hidden
- 图片用相对路径 `assets/xxx.png`
- Emoji 用 HTML entities

## Step 3: 渲染 PNG

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new \
  --screenshot=/tmp/work/output.png \
  --window-size=1242,1660 \
  --disable-gpu \
  --force-device-scale-factor=1 \
  "file:///tmp/work/header.html"
```

## Step 4: 验证

```bash
ls -la /tmp/work/output.png
python3 -c "from PIL import Image; img=Image.open('/tmp/work/output.png'); print(f'size: {img.size}')"
```

如果尺寸不对或布局有问题，修改 HTML 重新渲染。

**禁止用 Read 读取 PNG 文件**（会生成巨大 base64，浪费 token）。用 `ls -la` 确认文件存在 + PIL 检查尺寸即可。
