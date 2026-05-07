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
