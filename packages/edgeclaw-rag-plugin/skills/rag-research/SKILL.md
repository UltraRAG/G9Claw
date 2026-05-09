---
name: 9gclaw-rag-research
description: Combine 9GClaw local knowledge and GLM web search evidence for research, intelligence, and source-grounded generation tasks.
when_to_use: "Use for source-grounded research, military intelligence pages, reports, briefs, HTML pages, or any task needing both local knowledge and current web evidence."
allowed-tools:
  - "Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py:*)"
  - "Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py:*)"
---

# 9GClaw RAG Research

Use this skill when a task benefits from both the local knowledge base and
current public web evidence.

This is a skill loaded through the built-in `Skill` tool. Do not call
`9gclaw-rag:rag-research` as a direct tool name.

If explicitly invoking this skill, use:

```json
{"skill":"9gclaw-rag:rag-research","args":"<research query>"}
```

Do not use built-in `WebFetch` or `WebSearch` for search. Use the scripts below
so all retrieval goes through 9GClaw-controlled APIs and citations.

## Retrieval Flow

1. Search local knowledge first for stable domain context:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query "<query>"
   ```

2. Identify gaps that require current public evidence, then search GLM web:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/glm_web_search.py --query "<gap query>"
   ```

3. Merge the evidence:
   - Keep local knowledge citations as `local_knowledge:<id>`.
   - Keep web citations as Markdown links using the returned URLs.
   - Deduplicate repeated claims.
   - Mark conflicts explicitly instead of silently choosing one source.

Do not pass `--top-k` during the default retrieval flow. Each script reads the
configured default from `EDGECLAW_RAG_*_TOP_K`, which is exported from
`~/.edgeclaw/config.yaml`. Only pass `--top-k <n>` when the user explicitly asks
to override the configured result count.

## HTML / Intelligence Page Output

When producing an HTML page, include a visible `Sources` or `References` section.
Use local knowledge IDs for internal evidence and URLs for web evidence. Do not
hide citations only in comments or metadata.

## Failure Handling

If either script returns `ok: false`, continue with the other source only when
the task can still be completed responsibly. Otherwise report the missing source
or configuration problem.
