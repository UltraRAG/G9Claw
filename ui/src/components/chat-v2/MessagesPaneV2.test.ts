import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '../chat/types/types';
import {
  buildRenderableMessageItems,
  getLiveProcessDetailMessages,
  getLiveProcessGroups,
  getVirtualMessageWindow,
} from './MessagesPaneV2';

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

function userVisibleTool(id: string, seconds: number, toolName = 'ExitPlanMode'): ChatMessage {
  return message(id, 'assistant', '', seconds, {
    isToolUse: true,
    toolName,
    toolInput: '{"plan":"Ship the validated plan"}',
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
  it('keeps assistant prose visible but hides live tool calls while the assistant is still working', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1']);
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

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a2', 'u2', 'a3']);
    expect(items[1].processDetailMessages?.map((item) => item.id)).toEqual(['a1', 't1']);
    expect(items[3].processSummary).toBeNull();
  });

  it('keeps active assistant prose visible but hides live process messages when an intermediate summary has arrived', () => {
    const items = buildRenderableMessageItems([
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'Let me inspect the page.', 2),
      tool('t1', 3, 'Read'),
      message('a2', 'assistant', '页面已刷新。这次优化主要做了以下改进。', 4),
      summary('run-1', 1, 5),
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 'a2']);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('hides an active subagent task while keeping assistant prose visible', () => {
    const messages = [
      message('u1', 'user', '你可以调用subagent', 1),
      message('a1', 'assistant', 'I will delegate this.', 2),
      subagent('task-1', 3),
      summary('run-1', 1, 4),
      message('a2', 'assistant', 'The subagent is still working on it.', 5),
    ];
    const items = buildRenderableMessageItems(messages, { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 'a2']);
    expect(getLiveProcessDetailMessages(messages)).toEqual([]);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('keeps plan-mode user interaction tools visible while hiding ordinary live tools', () => {
    const messages = [
      message('u1', 'user', '先规划一下', 1),
      message('a1', 'assistant', 'I will inspect first.', 2),
      tool('t1', 3, 'Read'),
      userVisibleTool('plan-1', 4, 'ExitPlanMode'),
    ];
    const items = buildRenderableMessageItems([
      ...messages,
    ], { isAssistantWorking: true });

    expect(items.map((item) => item.message.id)).toEqual(['u1', 'a1', 'plan-1']);
    expect(getLiveProcessDetailMessages(messages).map((item) => item.id)).toEqual(['t1']);
    expect(items.some((item) => item.processSummary)).toBe(false);
  });

  it('groups non-continuous live process messages by their transcript position', () => {
    const messages = [
      message('u1', 'user', '继续优化', 1),
      message('a1', 'assistant', 'I will inspect first.', 2),
      tool('read-1', 3, 'Read'),
      tool('read-2', 4, 'Grep'),
      message('a2', 'assistant', 'Now I will edit.', 5),
      tool('edit-1', 6, 'Edit'),
      message('a3', 'assistant', 'Now I will verify.', 7),
      tool('bash-1', 8, 'Bash'),
    ];

    const groups = getLiveProcessGroups(messages, { isAssistantWorking: true });

    expect(groups).toHaveLength(3);
    expect(groups.map((group) => group.afterOriginalIndex)).toEqual([1, 4, 6]);
    expect(groups.map((group) => group.messages.map((item) => item.id))).toEqual([
      ['read-1', 'read-2'],
      ['edit-1'],
      ['bash-1'],
    ]);
    expect(groups.map((group) => group.isRunning)).toEqual([false, false, true]);
    expect(groups[0].detailMessages.map((item) => item.id)).toEqual(['read-1', 'read-2']);
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

describe('getVirtualMessageWindow', () => {
  it('renders only the overscanned viewport range', () => {
    const window = getVirtualMessageWindow([100, 100, 100, 100, 100, 100], 250, 200, 1);

    expect(window.startIndex).toBe(1);
    expect(window.endIndex).toBe(6);
    expect(window.topPadding).toBe(100);
    expect(window.bottomPadding).toBe(0);
    expect(window.totalHeight).toBe(600);
  });

  it('keeps a valid one-item window for tiny viewports', () => {
    const window = getVirtualMessageWindow([120, 140, 160], 0, 1, 0);

    expect(window.startIndex).toBe(0);
    expect(window.endIndex).toBe(1);
    expect(window.topPadding).toBe(0);
    expect(window.bottomPadding).toBe(300);
    expect(window.totalHeight).toBe(420);
  });
});
