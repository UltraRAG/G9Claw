import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '../chat/types/types';
import { buildRenderableMessageItems } from './MessagesPaneV2';

const at = (seconds: number) => `2026-05-13T09:00:${String(seconds).padStart(2, '0')}.000Z`;

function message(
  id: string,
  type: ChatMessage['type'],
  content: string,
  seconds: number,
  extra: Partial<ChatMessage> = {},
): ChatMessage {
  return {
    id,
    type,
    content,
    timestamp: at(seconds),
    ...extra,
  };
}

function tool(id: string, seconds: number, toolName = 'Edit'): ChatMessage {
  return message(id, 'assistant', '', seconds, {
    isToolUse: true,
    toolName,
    toolInput: '{}',
    toolId: id,
  });
}

function subagent(id: string, seconds: number): ChatMessage {
  return message(id, 'assistant', '', seconds, {
    isToolUse: true,
    isSubagentContainer: true,
    toolName: 'Task',
    toolInput: '{"description":"Polish page"}',
    toolId: id,
    subagentState: {
      childTools: [],
      currentToolIndex: -1,
      isComplete: false,
    },
  });
}

function summary(id: string, startedAtSeconds: number, endedAtSeconds: number): ChatMessage {
  return message(id, 'system', 'Process summary', endedAtSeconds, {
    isAgentActivitySummary: true,
    runId: id,
    startedAt: at(startedAtSeconds),
    endedAt: at(endedAtSeconds),
    durationMs: (endedAtSeconds - startedAtSeconds) * 1000,
    state: 'completed',
    toolCallCount: 1,
  });
}

describe('buildRenderableMessageItems', () => {
  it('keeps the active latest turn expanded while the assistant is still working', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 't1']);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('collapses a completed turn even when no persisted process summary exists yet', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
      message('a2', 'assistant', '页面已刷新。这次优化主要做了以下改进。', 4),
    ], { isAssistantWorking: false });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a2']);
    expect(items[1].processSummary?.id).toBe('process_summary_a2');
    expect(items[1].processDetailMessages?.map((item) => item.id)).toEqual(['a1', 't1']);
  });

  it('does not reopen a completed previous turn when a new turn is active', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
      message('a2', 'assistant', '页面已刷新。这次优化主要做了以下改进。', 4),
      message('u2', 'user', '再调一下按钮', 5),
      message('a3', 'assistant', 'I will check the button styles.', 6),
      tool('t2', 7, 'Read'),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a2', 'u2', 'a3', 't2']);
    expect(items[1].processDetailMessages?.map((item) => item.id)).toEqual(['a1', 't1']);
    expect(items[3].processSummary).toBeNull();
  });

  it('keeps the active latest turn expanded even if an intermediate summary has arrived', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
      message('a2', 'assistant', '页面已刷新。这次优化主要做了以下改进。', 4),
      summary('run-1', 1, 5),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 't1', 'a2']);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('keeps an active latest turn expanded while a subagent task is still running', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '你可以调用subagent', 1),
      message('a1', 'assistant', 'I will delegate this.', 2),
      subagent('task-1', 3),
      summary('run-1', 1, 4),
      message('a2', 'assistant', 'The subagent is still working on it.', 5),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 'task-1', 'a2']);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('collapses the latest turn once the overall task is no longer running', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
      message('a2', 'assistant', '页面已刷新。这次优化主要做了以下改进。', 4),
      summary('run-1', 1, 5),
    ], { isAssistantWorking: false });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a2']);
    expect(items[1].processSummary?.id).toBe('run-1');
    expect(items[1].processDetailMessages?.map((item) => item.id)).toEqual(['a1', 't1']);
  });
});
