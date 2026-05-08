import { expect, test } from 'bun:test'
import {
  buildCcrConfigFromEdgeClawConfig,
  buildRuntimeEnvFromConfig,
} from './edgeclaw-config.js'

test('buildRuntimeEnvFromConfig exports rag settings', () => {
  const env = buildRuntimeEnvFromConfig({
    rag: {
      enabled: true,
      localKnowledge: {
        baseUrl: 'https://local.example.com/',
        databaseUrl: 'http://milvus.example.com:19530',
        apiKey: 'local-secret',
        modelName: 'qwen-embedding',
        defaultTopK: 5,
      },
      glmWebSearch: {
        baseUrl: 'https://web.example.com/',
        apiKey: 'web-secret',
        defaultTopK: 6,
      },
    },
  })

  expect(env.EDGECLAW_RAG_ENABLED).toBe('1')
  expect(env.EDGECLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS).toBe('1')
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL).toBe(
    'https://local.example.com',
  )
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL).toBe(
    'http://milvus.example.com:19530',
  )
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI).toBe(
    'http://milvus.example.com:19530',
  )
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY).toBe('local-secret')
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME).toBe('qwen-embedding')
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K).toBe('5')
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL).toBe(
    'https://web.example.com',
  )
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY).toBe('web-secret')
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K).toBe('6')
})

test('buildCcrConfigFromEdgeClawConfig fills router defaults and zero-cost local pricing', () => {
  const ccr = buildCcrConfigFromEdgeClawConfig({
    models: {
      providers: {
        edgeclaw: {
          type: 'openai-chat',
          baseUrl: 'http://local.example.com/v1',
          apiKey: 'local-secret',
        },
      },
      entries: {
        default: { provider: 'edgeclaw', name: 'qwen3.5-35b' },
      },
    },
    agents: { main: { model: 'default' } },
    router: {
      enabled: true,
      tokenSaver: { enabled: true },
      autoOrchestrate: { enabled: true },
    } as any,
  })

  expect(ccr.Router.tokenSaver.defaultTier).toBe('MEDIUM')
  expect(ccr.Router.tokenSaver.tiers.SIMPLE.model).toBe('edgeclaw,qwen3.5-35b')
  expect(ccr.Router.autoOrchestrate.allowedTools).toContain('Agent')
  expect(ccr.Router.autoOrchestrate.subagentMaxTokens).toBe(48000)
  expect(ccr.tokenStats.modelPricing['edgeclaw,qwen3.5-35b']).toEqual({
    inputPer1M: 0,
    outputPer1M: 0,
  })
})
