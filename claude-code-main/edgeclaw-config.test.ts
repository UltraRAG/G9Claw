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

test('buildCcrConfigFromEdgeClawConfig fills router defaults and built-in model pricing', () => {
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
        default: { provider: 'edgeclaw', name: 'qwen3.6-27b' },
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
  expect(ccr.Router.tokenSaver.tiers.SIMPLE.model).toBe('edgeclaw,qwen3.6-27b')
  expect(ccr.Router.tokenSaver.rules.join('\n')).not.toContain('RAG')
  expect(ccr.Router.tokenSaver.rules.join('\n')).not.toContain('DARPA')
  expect(ccr.Router.autoOrchestrate.allowedTools).toContain('Agent')
  expect(ccr.Router.autoOrchestrate.subagentMaxTokens).toBe(48000)
  expect(ccr.tokenStats.savingsBaselineModel).toBe('edgeclaw,qwen3.6-27b')
  expect(ccr.tokenStats.modelPricing['qwen3.6-27b']).toEqual({
    inputPer1M: 0.4,
    outputPer1M: 3.2,
  })
  expect(ccr.tokenStats.modelPricing['minimax-m2.7']).toEqual({
    inputPer1M: 0.8,
    outputPer1M: 6,
  })
  expect(ccr.tokenStats.modelPricing['gpt-5.4-mini']).toEqual({
    inputPer1M: 0.75,
    outputPer1M: 4.5,
  })
  expect(ccr.tokenStats.modelPricing['claude-sonnet-4.5']).toEqual({
    inputPer1M: 3,
    outputPer1M: 15,
  })
  expect(ccr.tokenStats.modelPricing['gemini-2.5-flash']).toEqual({
    inputPer1M: 0.3,
    outputPer1M: 2.5,
  })
  expect(ccr.tokenStats.modelPricing['deepseek-reasoner']).toEqual({
    inputPer1M: 0.55,
    outputPer1M: 2.19,
  })
})
