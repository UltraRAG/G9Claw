import React from 'react';
import { render, screen } from '@testing-library/react';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '../chat/types/types';
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

function makeMessage(index: number): ChatMessage {
  return {
    id: `m-${index}`,
    type: index % 2 === 0 ? 'user' : 'assistant',
    content: `Message ${index}`,
    timestamp: `2026-05-13T09:${String(index % 60).padStart(2, '0')}:00.000Z`,
  };
}

describe('MessagesPaneV2 virtualization', () => {
  it('renders only the viewport window for large conversations', () => {
    const messages = Array.from({ length: 220 }, (_, index) => makeMessage(index));
    const scrollContainerRef = React.createRef<HTMLDivElement>();

    render(
      <MessagesPaneV2
        scrollContainerRef={scrollContainerRef}
        onWheel={() => {}}
        onTouchMove={() => {}}
        isLoadingSessionMessages={false}
        chatMessages={messages}
        activityMessages={[]}
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
      />,
    );

    const container = screen.getByText('Message 0').closest('[data-total-message-count]');
    expect(container?.getAttribute('data-virtualized-messages')).toBe('true');
    expect(container?.getAttribute('data-total-message-count')).toBe('220');
    expect(Number(container?.getAttribute('data-rendered-message-count'))).toBeLessThan(220);
  });
});
