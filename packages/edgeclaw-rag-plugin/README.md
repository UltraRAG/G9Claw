# 9gclaw-rag-plugin

Lightweight Claude Code plugin for 9GClaw RAG v1.

This plugin does not start MCP servers. It ships prompt skills and Python scripts
that call the RAG HTTP APIs configured through `~/.edgeclaw/config.yaml`.

## Skills

These entries are Claude Code skills. Invoke them through the built-in `Skill`
tool; do not call `9gclaw-rag:*` as direct tool names.

| Skill ID | Purpose |
| --- | --- |
| `9gclaw-rag:local-knowledge` | Search the deployed local knowledge API. |
| `9gclaw-rag:glm-web-search` | Search the configured GLM web search API. |
| `9gclaw-rag:rag-research` | Combine local knowledge and web search evidence. |

Correct tool call shape:

```json
{
  "tool": "Skill",
  "input": {
    "skill": "9gclaw-rag:glm-web-search",
    "args": "today weather in Shenyang"
  }
}
```

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
