import { expect, test } from 'bun:test'
import { buildRuntimeEnvFromConfig } from './edgeclaw-config.js'

test('buildRuntimeEnvFromConfig exports rag settings', () => {
  const env = buildRuntimeEnvFromConfig({
    rag: {
      enabled: true,
      localKnowledge: {
        baseUrl: 'https://local.example.com/',
        milvusUri: 'http://milvus.example.com:19530',
        apiKey: 'local-secret',
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
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL).toBe(
    'https://local.example.com',
  )
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI).toBe(
    'http://milvus.example.com:19530',
  )
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY).toBe('local-secret')
  expect(env.EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K).toBe('5')
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL).toBe(
    'https://web.example.com',
  )
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY).toBe('web-secret')
  expect(env.EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K).toBe('6')
})
