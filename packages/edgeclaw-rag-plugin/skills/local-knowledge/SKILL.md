---
name: 9gclaw-local-knowledge
description: Search 9GClaw's configured local knowledge base for durable domain evidence and internal context.
when_to_use: "Use when the task needs domain facts, military/intelligence background, local/private knowledge, or citations from the configured knowledge base."
allowed-tools:
  - "Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py:*)"
---

# 9GClaw Local Knowledge Search

Use this skill to retrieve context from the deployed local knowledge API.
If `rag.localKnowledge.modelName` or `rag.localKnowledge.databaseUrl` are
configured, the script passes them to the retriever service as `modelName` and
`databaseUrl`.

This is a skill loaded through the built-in `Skill` tool. Do not call
`9gclaw-rag:local-knowledge` as a direct tool name.

If explicitly invoking this skill, use:

```json
{"skill":"9gclaw-rag:local-knowledge","args":"<query>"}
```

## Command

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query "<query>"
```

Do not pass `--top-k` by default. The script uses
`EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K`, which is exported from
`rag.localKnowledge.defaultTopK` in `~/.edgeclaw/config.yaml`.

Optional filters must be a JSON object:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query "<query>" --filters-json '{"domain":"military"}'
```

Only pass `--top-k <n>` when the user explicitly asks for a result count that
should override the configured default.

## How To Use Results

- Treat `context` as retrieved evidence for the current task.
- Preserve `citations[].id` and `citations[].source` when using the evidence.
- If `ok` is false, report the configuration or API error instead of inventing facts.
- Use local knowledge for internal, durable, or specialized background; use GLM web search for current public information.
