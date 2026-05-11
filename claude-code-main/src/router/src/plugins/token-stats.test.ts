import { expect, test } from 'bun:test'
import { lookupPricing, setModelPricing } from './token-stats'

test('lookupPricing prefers the longest generic model match', () => {
  setModelPricing({
    'gpt-5.4': { inputPer1M: 2.5, outputPer1M: 15 },
    'gpt-5.4-mini': { inputPer1M: 0.75, outputPer1M: 4.5 },
  })

  expect(lookupPricing('openai/gpt-5.4-mini')).toEqual({
    inputPer1M: 0.75,
    outputPer1M: 4.5,
  })
})
