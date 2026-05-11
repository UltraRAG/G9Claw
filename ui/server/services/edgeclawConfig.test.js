import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildRuntimeEnv, normalizeEdgeClawConfig } from './edgeclawConfig.js';

test('normalizeEdgeClawConfig exposes default top-level alwaysOn config', () => {
  const config = normalizeEdgeClawConfig({});

  assert.equal(config.alwaysOn.discovery.trigger.enabled, false);
  assert.equal(config.alwaysOn.discovery.trigger.tickIntervalMinutes, 5);
  assert.deepEqual(config.alwaysOn.discovery.projects, {});
  assert.equal(config.agents.alwaysOn, undefined);
});

test('normalizeEdgeClawConfig migrates legacy agents.alwaysOn trigger when top-level config is absent', () => {
  const config = normalizeEdgeClawConfig({
    agents: {
      alwaysOn: {
        discovery: {
          trigger: {
            enabled: true,
            tickIntervalMinutes: 15,
          },
        },
      },
    },
  });

  assert.equal(config.alwaysOn.discovery.trigger.enabled, true);
  assert.equal(config.alwaysOn.discovery.trigger.tickIntervalMinutes, 15);
  assert.equal(config.agents.alwaysOn, undefined);
});

test('normalizeEdgeClawConfig prefers top-level alwaysOn over legacy agents.alwaysOn', () => {
  const config = normalizeEdgeClawConfig({
    agents: {
      alwaysOn: {
        discovery: {
          trigger: {
            enabled: true,
            tickIntervalMinutes: 15,
          },
        },
      },
    },
    alwaysOn: {
      discovery: {
        trigger: {
          enabled: false,
          tickIntervalMinutes: 3,
        },
        projects: {
          '/workspace/a': { enabled: true },
        },
      },
    },
  });

  assert.equal(config.alwaysOn.discovery.trigger.enabled, false);
  assert.equal(config.alwaysOn.discovery.trigger.tickIntervalMinutes, 3);
  assert.equal(config.alwaysOn.discovery.projects['/workspace/a'].enabled, true);
});

test('normalizeEdgeClawConfig exposes default rag config', () => {
  const config = normalizeEdgeClawConfig({});

  assert.equal(config.rag.enabled, false);
  assert.equal(config.rag.disableBuiltInWebTools, true);
  assert.equal(config.rag.localKnowledge.baseUrl, '');
  assert.equal(config.rag.localKnowledge.milvusUri, undefined);
  assert.equal(config.rag.localKnowledge.apiKey, '');
  assert.equal(config.rag.localKnowledge.modelName, '');
  assert.equal(config.rag.localKnowledge.databaseUrl, '');
  assert.equal(config.rag.localKnowledge.defaultTopK, 8);
  assert.equal(config.rag.glmWebSearch.baseUrl, '');
  assert.equal(config.rag.glmWebSearch.apiKey, '');
  assert.equal(config.rag.glmWebSearch.defaultTopK, 8);
});

test('buildRuntimeEnv exports rag settings', () => {
  const env = buildRuntimeEnv({
    rag: {
      enabled: true,
      localKnowledge: {
        baseUrl: 'https://local.example.com/',
        apiKey: 'local-secret',
        modelName: 'retriever-v1',
        databaseUrl: 'milvus://milvus.example.com:19530',
        defaultTopK: 5,
      },
      glmWebSearch: {
        baseUrl: 'https://web.example.com/',
        apiKey: 'web-secret',
        defaultTopK: 6,
      },
    },
  });

  assert.equal(env.EDGECLAW_RAG_ENABLED, '1');
  assert.equal(env.EDGECLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS, '1');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL, 'https://local.example.com');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY, 'local-secret');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME, 'retriever-v1');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL, 'milvus://milvus.example.com:19530');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI, 'milvus://milvus.example.com:19530');
  assert.equal(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K, '5');
  assert.equal(env.EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL, 'https://web.example.com');
  assert.equal(env.EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY, 'web-secret');
  assert.equal(env.EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K, '6');
});

test('buildRuntimeEnv prefers active main model context window over runtime fallback', () => {
  const env = buildRuntimeEnv({
    runtime: {
      contextWindow: 160000,
    },
    models: {
      providers: {
        edgeclaw: {
          type: 'openai-chat',
          baseUrl: 'http://model.example.com/v1',
          apiKey: 'secret',
        },
      },
      entries: {
        default: {
          provider: 'edgeclaw',
          name: 'main-model',
          contextWindow: 262144,
        },
      },
    },
    agents: {
      main: {
        model: 'default',
      },
    },
  });

  assert.equal(env.CONTEXT_WINDOW, '262144');
  assert.equal(env.VITE_CONTEXT_WINDOW, '262144');
  assert.equal(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '262144');
});

test('buildRuntimeEnv falls back to runtime context window when main model entry omits it', () => {
  const env = buildRuntimeEnv({
    runtime: {
      contextWindow: 131072,
    },
    models: {
      providers: {
        edgeclaw: {
          type: 'openai-chat',
          baseUrl: 'http://model.example.com/v1',
          apiKey: 'secret',
        },
      },
      entries: {
        default: {
          provider: 'edgeclaw',
          name: 'main-model',
        },
      },
    },
    agents: {
      main: {
        model: 'default',
      },
    },
  });

  assert.equal(env.CONTEXT_WINDOW, '131072');
  assert.equal(env.VITE_CONTEXT_WINDOW, '131072');
  assert.equal(env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, '131072');
});

test('normalizeEdgeClawConfig migrates legacy local knowledge milvusUri to databaseUrl', () => {
  const config = normalizeEdgeClawConfig({
    rag: {
      localKnowledge: {
        milvusUri: 'http://legacy-milvus.example.com:19530',
      },
    },
  });

  assert.equal(config.rag.localKnowledge.databaseUrl, 'http://legacy-milvus.example.com:19530');
  assert.equal(config.rag.localKnowledge.milvusUri, undefined);
});

test('buildCcrConfig applies built-in pricing to first-party 9GClaw models', async () => {
  const { buildCcrConfig } = await import('./edgeclawConfig.js');
  const ccr = buildCcrConfig({
    models: {
      providers: {
        edgeclaw: {
          type: 'openai-chat',
          baseUrl: 'http://local.example.com/v1',
          apiKey: 'local-secret',
        },
        openrouter: {
          type: 'openai-chat',
          baseUrl: 'https://openrouter.ai/api/v1',
          apiKey: 'paid-secret',
        },
      },
      entries: {
        router_small: { provider: 'edgeclaw', name: 'qwen3.6-27b' },
        default: { provider: 'openrouter', name: 'deepseek/deepseek-v4-pro' },
      },
    },
  });

  assert.deepEqual(ccr.tokenStats.modelPricing['qwen3.6-27b'], {
    inputPer1M: 0.4,
    outputPer1M: 3.2,
  });
  assert.deepEqual(ccr.tokenStats.modelPricing['minimax-m2.7'], {
    inputPer1M: 0.8,
    outputPer1M: 6,
  });
  assert.deepEqual(ccr.tokenStats.modelPricing['gpt-5.4-mini'], {
    inputPer1M: 0.75,
    outputPer1M: 4.5,
  });
  assert.deepEqual(ccr.tokenStats.modelPricing['claude-sonnet-4.5'], {
    inputPer1M: 3,
    outputPer1M: 15,
  });
  assert.deepEqual(ccr.tokenStats.modelPricing['gemini-2.5-flash'], {
    inputPer1M: 0.3,
    outputPer1M: 2.5,
  });
  assert.deepEqual(ccr.tokenStats.modelPricing['deepseek-reasoner'], {
    inputPer1M: 0.55,
    outputPer1M: 2.19,
  });
  assert.equal(ccr.tokenStats.savingsBaselineModel, 'openrouter,deepseek/deepseek-v4-pro');
  assert.equal(ccr.tokenStats.modelPricing['openrouter,deepseek/deepseek-v4-pro'], undefined);
});

test('buildCcrConfig accepts provider base URLs that already include chat completions', async () => {
  const { buildCcrConfig } = await import('./edgeclawConfig.js');
  const ccr = buildCcrConfig({
    models: {
      providers: {
        openrouter: {
          type: 'openai-chat',
          baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
          apiKey: 'paid-secret',
        },
      },
      entries: {
        default: { provider: 'openrouter', name: 'deepseek/deepseek-v4-pro' },
      },
    },
  });

  assert.equal(
    ccr.Providers.find((provider) => provider.name === 'openrouter')?.api_base_url,
    'https://openrouter.ai/api/v1/chat/completions',
  );
});
