---
name: 9gclaw-glm-web-search
description: Search the configured GLM web search API for current public-source information.
when_to_use: "Use when the task needs recent facts, public webpages, current events, source URLs, or web evidence."
allowed-tools:
  - "Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py:*)"
---

# 9GClaw GLM Web Search

Use this skill to search the configured Z.AI / GLM web search service. This
replaces the built-in Claude Code `WebFetch` and `WebSearch` tools for search
tasks in 9GClaw.

The recommended endpoint is:

```text
https://api.z.ai/api/paas/v4/web_search
```

## Command

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py --query "<query>"
```

Do not pass `--top-k` by default. The script uses
`EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K`, which is exported from
`rag.glmWebSearch.defaultTopK` in `~/.edgeclaw/config.yaml`.

Optional freshness and domain constraints:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py --query "<query>" --freshness-days 30
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py --query "<query>" --allowed-domain example.com
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py --query "<query>" --blocked-domain example.com
```

Only pass `--top-k <n>` when the user explicitly asks for a result count that
should override the configured default.

## How To Use Results

- Cite `citations[].url` for every web fact used in the final answer.
- Prefer recent results when the user asks for current status, latest events, prices, policies, or active conflicts.
- When using the Z.AI endpoint, `--freshness-days` is mapped to Z.AI recency filters and `--allowed-domain` is passed as `search_domain_filter`.
- If local knowledge and web results conflict, say which source says what and avoid overclaiming.
- If `ok` is false, report the configuration or API error instead of falling back to unsupported built-in WebFetch/WebSearch.
