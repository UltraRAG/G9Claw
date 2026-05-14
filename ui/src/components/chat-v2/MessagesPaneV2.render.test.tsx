import React from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import type { ChatMessage, ChatRunMode } from '../chat/types/types';
import MessagesPaneV2 from './MessagesPaneV2';

beforeAll(() => {
  class ResizeObserverMock {
    observe() {}
    disconnect() {}
  }

  vi.stubGlobal('ResizeObserver', ResizeObserverMock);
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
    return window.setTimeout(() => callback(performance.now()), 0);
  });
  vi.stubGlobal('cancelAnimationFrame', (id: number) => window.clearTimeout(id));
});

afterEach(() => {
  cleanup();
});

function makeMessage(index: number): ChatMessage {
  return {
    id: `m-${index}`,
    type: index % 2 === 0 ? 'user' : 'assistant',
    content: `Message ${index}`,
    timestamp: `2026-05-13T09:${String(index % 60).padStart(2, '0')}:00.000Z`,
  };
}

function renderPane({
  messages,
  activityMessages = [],
  isAssistantWorking = false,
  runMode = 'agent',
}: {
  messages: ChatMessage[];
  activityMessages?: ChatMessage[];
  isAssistantWorking?: boolean;
  runMode?: ChatRunMode;
}) {
  const scrollContainerRef = React.createRef<HTMLDivElement>();

  return render(
    <MessagesPaneV2
      scrollContainerRef={scrollContainerRef}
      onWheel={() => {}}
      onTouchMove={() => {}}
      isLoadingSessionMessages={false}
      chatMessages={messages}
      activityMessages={activityMessages}
      visibleMessages={messages}
      visibleMessageCount={messages.length}
      isLoadingMoreMessages={false}
      hasMoreMessages={false}
      totalMessages={messages.length}
      loadEarlierMessages={() => {}}
      loadAllMessages={() => {}}
      allMessagesLoaded
      isLoadingAllMessages={false}
      provider="claude"
      selectedProject={null}
      selectedSession={null}
      createDiff={() => []}
      setInput={() => {}}
      isAssistantWorking={isAssistantWorking}
      runMode={runMode}
    />,
  );
}

describe('MessagesPaneV2 virtualization', () => {
  it('renders only the viewport window for large conversations', () => {
    const messages = Array.from({ length: 220 }, (_, index) => makeMessage(index));

    renderPane({ messages });

    const container = screen.getByText('Message 0').closest('[data-total-message-count]');
    expect(container?.getAttribute('data-virtualized-messages')).toBe('true');
    expect(container?.getAttribute('data-total-message-count')).toBe('220');
    expect(Number(container?.getAttribute('data-rendered-message-count'))).toBeLessThan(220);
  });

  it('renders live processing time above the active assistant turn without controlling a collapse panel', () => {
    const messages = [
      {
        id: 'u-1',
        type: 'user',
        content: '继续优化',
        timestamp: new Date().toISOString(),
      },
      {
        id: 'a-1',
        type: 'assistant',
        content: 'I will inspect the current UI.',
        timestamp: new Date().toISOString(),
      },
    ];
    const activityMessages: ChatMessage[] = [
      {
        id: 'activity-1',
        type: 'system',
        content: 'Searching files',
        timestamp: new Date().toISOString(),
        isAgentActivity: true,
        activityId: 'activity-1',
        phase: 'rag',
        state: 'running',
        title: 'Searching files',
        detail: 'MessagesPaneV2.tsx',
        startedAt: new Date(Date.now() - 2000).toISOString(),
      },
    ];

    renderPane({ messages, activityMessages, isAssistantWorking: true });

    const statuses = screen.getAllByRole('status');
    const headerStatus = statuses[0];
    const liveStatus = statuses[1];
    const userText = screen.getByText('继续优化');
    const assistantText = screen.getByText('I will inspect the current UI.');
    expect(statuses).toHaveLength(2);
    expect(headerStatus.textContent).toContain('Processed');
    expect(headerStatus.textContent).not.toContain('Searching files');
    expect(headerStatus.querySelector('button')).toBeNull();
    expect(headerStatus.className).toContain('mb-4');
    expect(userText.closest('.chat-message')?.className).toContain('pb-3');
    expect(liveStatus.textContent).toContain('Searching files');
    expect(liveStatus.querySelector('button')).toBeNull();
    expect(liveStatus.querySelector('.rounded-xl')).toBeNull();
    expect(Boolean(headerStatus.compareDocumentPosition(assistantText) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
    expect(Boolean(assistantText.compareDocumentPosition(liveStatus) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
  });

  it('keeps live tool calls collapsed but lets the running status expand their details', () => {
    const now = new Date().toISOString();
    const messages: ChatMessage[] = [
      {
        id: 'u-1',
        type: 'user',
        content: '检查文件',
        timestamp: now,
      },
      {
        id: 'a-1',
        type: 'assistant',
        content: 'I will inspect the current file.',
        timestamp: now,
      },
      {
        id: 'tool-read-1',
        type: 'assistant',
        content: '',
        timestamp: now,
        isToolUse: true,
        toolName: 'Read',
        toolId: 'tool-read-1',
        toolInput: '{"file_path":"src/HiddenTool.tsx"}',
      },
    ];
    const activityMessages: ChatMessage[] = [
      {
        id: 'activity-1',
        type: 'system',
        content: 'Reading file',
        timestamp: now,
        isAgentActivity: true,
        activityId: 'activity-1',
        phase: 'tool',
        state: 'running',
        title: 'Reading file',
        startedAt: now,
      },
    ];

    renderPane({ messages, activityMessages, isAssistantWorking: true });

    expect(screen.queryByText('HiddenTool.tsx')).toBeNull();

    const liveStatus = screen.getByText('Reading file').closest('[role="status"]');
    expect(liveStatus).not.toBeNull();
    if (!liveStatus) throw new Error('Expected live status container');
    const expandButton = liveStatus.querySelector('button');
    expect(expandButton).not.toBeNull();
    expect(expandButton?.getAttribute('aria-expanded')).toBe('false');

    fireEvent.click(expandButton as HTMLButtonElement);

    expect(expandButton?.getAttribute('aria-expanded')).toBe('true');
    expect(screen.getByText('HiddenTool.tsx')).toBeTruthy();
  });

  it('keeps separated live process rows at the positions where they happened', () => {
    const now = new Date().toISOString();
    const messages: ChatMessage[] = [
      {
        id: 'u-1',
        type: 'user',
        content: '继续检查',
        timestamp: now,
      },
      {
        id: 'a-1',
        type: 'assistant',
        content: 'I will inspect files first.',
        timestamp: now,
      },
      {
        id: 'tool-read-1',
        type: 'assistant',
        content: '',
        timestamp: now,
        isToolUse: true,
        toolName: 'Read',
        toolId: 'tool-read-1',
        toolInput: '{"file_path":"src/FirstHidden.tsx"}',
        toolResult: { content: 'ok', isError: false },
      },
      {
        id: 'a-2',
        type: 'assistant',
        content: 'Now I will verify the build.',
        timestamp: now,
      },
      {
        id: 'tool-bash-1',
        type: 'assistant',
        content: '',
        timestamp: now,
        isToolUse: true,
        toolName: 'Bash',
        toolId: 'tool-bash-1',
        toolInput: '{"command":"npm run build"}',
      },
    ];

    renderPane({ messages, isAssistantWorking: true });

    const firstAssistant = screen.getByText('I will inspect files first.');
    const firstStatus = screen.getByText('Explored 1 file');
    const secondAssistant = screen.getByText('Now I will verify the build.');
    const runningStatus = screen.getByText('Running npm run build');

    expect(Boolean(firstAssistant.compareDocumentPosition(firstStatus) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
    expect(Boolean(firstStatus.compareDocumentPosition(secondAssistant) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);
    expect(Boolean(secondAssistant.compareDocumentPosition(runningStatus) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true);

    expect(screen.queryByText('FirstHidden.tsx')).toBeNull();
    const firstStatusContainer = firstStatus.closest('[role="status"]');
    expect(firstStatusContainer).not.toBeNull();
    if (!firstStatusContainer) throw new Error('Expected first inline status container');
    const expandButton = firstStatusContainer.querySelector('button');
    expect(expandButton).not.toBeNull();

    fireEvent.click(expandButton as HTMLButtonElement);

    expect(screen.getByText('FirstHidden.tsx')).toBeTruthy();
    expect(firstAssistant.closest('.chat-message')?.className).toContain('pb-3');
  });

  it('does not render a completed compact boundary as a plan-mode process row', () => {
    const now = new Date().toISOString();
    const messages: ChatMessage[] = [
      {
        id: 'u-1',
        type: 'user',
        content: '先规划一下',
        timestamp: now,
      },
      {
        id: 'compact-1',
        type: 'system',
        content: 'Context compacted',
        timestamp: now,
        isCompactBoundary: true,
      },
      {
        id: 'a-1',
        type: 'assistant',
        content: 'I will make a plan first.',
        timestamp: now,
      },
    ];

    renderPane({ messages, isAssistantWorking: true, runMode: 'plan' });

    expect(screen.getByText('I will make a plan first.')).toBeTruthy();
    expect(screen.queryByText('Compacted context')).toBeNull();
  });
});
