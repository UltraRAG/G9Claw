import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '../types/types';
import { mergePendingUserMessage } from './useChatSessionState';

const at = (seconds: number) => `2026-05-14T10:00:${String(seconds).padStart(2, '0')}.000Z`;

function user(id: string, content: string, seconds: number): ChatMessage {
  return {
    id,
    type: 'user',
    content,
    timestamp: at(seconds),
  };
}

function assistant(id: string, content: string, seconds: number): ChatMessage {
  return {
    id,
    type: 'assistant',
    content,
    timestamp: at(seconds),
  };
}

describe('mergePendingUserMessage', () => {
  it('keeps the pending user turn visible when assistant messages arrive first', () => {
    const pending = user('pending-user', '帮我做一个钟离的个人网站', 1);
    const merged = mergePendingUserMessage([
      assistant('a-1', '我来先了解一下项目。', 2),
    ], pending);

    expect(merged.map((message) => message.id)).toEqual(['pending-user', 'a-1']);
  });

  it('does not duplicate the pending user turn once the server has replayed it', () => {
    const pending = user('pending-user', '帮我做一个钟离的个人网站', 1);
    const merged = mergePendingUserMessage([
      user('server-user', '帮我做一个钟离的个人网站', 2),
      assistant('a-1', '已经完成。', 3),
    ], pending);

    expect(merged.map((message) => message.id)).toEqual(['server-user', 'a-1']);
  });
});
