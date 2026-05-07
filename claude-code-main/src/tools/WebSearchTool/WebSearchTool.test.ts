import { expect, test } from 'bun:test'
import { CLAUDE_CODE_GUIDE_AGENT } from '../AgentTool/built-in/claudeCodeGuideAgent.js'
import { getToolsForDefaultPreset } from '../../tools.js'
import { WebSearchTool } from './WebSearchTool.js'

test('WebSearchTool is globally disabled in EdgeClaw', () => {
  expect(WebSearchTool.isEnabled()).toBe(false)
})

test('default tool preset does not expose WebSearch', () => {
  expect(getToolsForDefaultPreset()).not.toContain(WebSearchTool.name)
})

test('built-in guide agent does not expose WebSearch', () => {
  expect(CLAUDE_CODE_GUIDE_AGENT.tools).not.toContain(WebSearchTool.name)
})
