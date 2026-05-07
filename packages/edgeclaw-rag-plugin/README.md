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
  localKnowledge:
    baseUrl: "https://local-knowledge.example.com"
    milvusUri: "http://127.0.0.1:19530"
    apiKey: "..."
    defaultTopK: 8
  glmWebSearch:
    baseUrl: "https://glm-web-search.example.com"
    apiKey: "..."
    defaultTopK: 8
```

The 9GClaw runtime exports these values as `EDGECLAW_RAG_*` environment
variables. The Python scripts only read environment variables and use the Python
standard library.

## Loading

`claude-code-main/start.sh` loads this bundled plugin by default alongside the
turnkey plugin. For direct CLI testing, pass it explicitly:

```bash
bun run src/entrypoints/cli.tsx --plugin-dir ../packages/edgeclaw-rag-plugin
```
