# g9claw-rag-plugin

Lightweight G9Claw plugin for G9Claw RAG v1.

This plugin does not start MCP servers. It ships prompt skills and Python scripts
that call the RAG HTTP APIs configured through `~/.g9claw/config.yaml`.

## Skills

These entries are G9Claw skills. Invoke them through the built-in `Skill`
tool; do not call `g9claw-rag:*` as direct tool names.

| Skill ID | Purpose |
| --- | --- |
| `g9claw-rag:local-knowledge` | Search the deployed local knowledge API. |
| `g9claw-rag:glm-web-search` | Search the configured GLM web search API. |
| `g9claw-rag:rag-research` | Combine local knowledge and web search evidence. |

Correct tool call shape:

```json
{
  "tool": "Skill",
  "input": {
    "skill": "g9claw-rag:glm-web-search",
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

The G9Claw runtime exports these values as `G9CLAW_RAG_*` environment
variables. The Python scripts only read environment variables and use the Python
standard library.

Skills should omit `--top-k` in their default commands. Passing `--top-k`
explicitly overrides `rag.*.defaultTopK`; use it only when the user asks for a
different result count.

## Loading

The G9Claw macOS app loads this bundled plugin from its app resources. During
development, the source copy lives at
`apps/macos-native/G9Claw/Assets/g9claw-rag-plugin`.
