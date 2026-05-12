import { describe, expect, it } from 'vitest';
import type { NormalizedMessage } from '../../../stores/useSessionStore';
import { normalizedToChatMessages } from './useChatMessages';

const baseMessage = {
  provider: 'claude',
  sessionId: 'session-1',
  timestamp: '2026-05-12T08:00:00.000Z',
} as const;

describe('normalizedToChatMessages activity events', () => {
  it('converts live agent activity into non-transcript system messages', () => {
    const messages = normalizedToChatMessages([
      {
        ...baseMessage,
        id: 'activity-1',
        kind: 'agent_activity',
        runId: 'run-1',
        activityId: 'run-1:tool:1',
        phase: 'tool',
        state: 'running',
        title: '正在执行命令',
        detail: 'npm run build',
        toolName: 'Bash',
        toolId: 'tool-1',
        startedAt: '2026-05-12T08:00:00.000Z',
        endedAt: null,
        durationMs: null,
        severity: 'info',
      } satisfies NormalizedMessage,
    ]);

    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({
      isAgentActivity: true,
      runId: 'run-1',
      activityId: 'run-1:tool:1',
      title: '正在执行命令',
      detail: 'npm run build',
      toolName: 'Bash',
    });
  });

  it('converts activity summaries with process counters', () => {
    const messages = normalizedToChatMessages([
      {
        ...baseMessage,
        id: 'activity-summary-1',
        kind: 'agent_activity_summary',
        runId: 'run-1',
        startedAt: '2026-05-12T08:00:00.000Z',
        endedAt: '2026-05-12T08:01:05.000Z',
        durationMs: 65000,
        status: 'completed',
        toolCallCount: 4,
        toolErrorCount: 1,
        ragSearchCount: 2,
        compactCount: 0,
        keySteps: [{ title: '正在检索资料', state: 'completed' }],
      } satisfies NormalizedMessage,
    ]);

    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({
      isAgentActivitySummary: true,
      runId: 'run-1',
      state: 'completed',
      toolCallCount: 4,
      toolErrorCount: 1,
      ragSearchCount: 2,
    });
  });
});
