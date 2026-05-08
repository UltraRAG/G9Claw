# 9gclaw-rag-plugin

Lightweight Claude Code plugin for 9GClaw RAG v1.

This plugin does not start MCP servers. It ships prompt skills and Python scripts
that call the RAG HTTP APIs configured through `~/.edgeclaw/config.yaml`.

## Skills

| Skill | Purpose |
| --- | --- |
| `9gclaw-local-knowledge` | Search the deployed local knowledge API. |
| `9gclaw-glm-web-search` | Search the configured GLM web search API. |
| `9gclaw-rag-research` | Combine local knowledge and web search evidence. |

## Required Config

```yaml
rag:
  enabled: true
  disableBuiltInWebTools: true
  localKnowledge:
    # Embedding / model service URL.
    baseUrl: "https://local-knowledge.example.com"
    apiKey: "..."
    modelName: "retriever-v1"
    # Local knowledge search endpoint.
    databaseUrl: "http://127.0.0.1:52008/search"
    defaultTopK: 8
  glmWebSearch:
    baseUrl: "https://api.z.ai/api/paas/v4/web_search"
    apiKey: "..."
    defaultTopK: 8
```

For Z.AI Web Search, put the full `/api/paas/v4/web_search` endpoint in
`rag.glmWebSearch.baseUrl`. For a self-hosted compatible web-search service,
you may still put only the service root; the script will call `POST /search`.

The 9GClaw runtime exports these values as `EDGECLAW_RAG_*` environment
variables. The Python scripts only read environment variables and use the Python
standard library.

Skills should omit `--top-k` in their default commands. Passing `--top-k`
explicitly overrides `rag.*.defaultTopK`; use it only when the user asks for a
different result count.

## Loading

`claude-code-main/start.sh` loads this bundled plugin by default alongside the
turnkey plugin. For direct CLI testing, pass it explicitly:

```bash
bun run src/entrypoints/cli.tsx --plugin-dir ../packages/edgeclaw-rag-plugin
```
