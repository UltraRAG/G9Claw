import assert from 'node:assert/strict';
import { test } from 'node:test';

import { normalizeMessage } from './adapter.js';

test('normalizeMessage preserves background cron trigger meta prompts', () => {
  const messages = normalizeMessage(
    {
      uuid: 'cron-trigger',
      type: 'user',
      isMeta: true,
      timestamp: '2026-04-29T12:00:00.000Z',
      message: {
        role: 'user',
        content: '提醒用户：该站起来活动一下了！',
      },
    },
    'background-session',
    { sessionKind: 'background_task' }
  );

  assert.equal(messages.length, 1);
  assert.equal(messages[0].kind, 'text');
  assert.equal(messages[0].role, 'user');
  assert.equal(messages[0].content, '提醒用户：该站起来活动一下了！');
});

test('normalizeMessage still hides non-background meta prompts', () => {
  const messages = normalizeMessage(
    {
      uuid: 'meta-main-chat',
      type: 'user',
      isMeta: true,
      message: {
        role: 'user',
        content: 'internal setup prompt',
      },
    },
    'regular-session'
  );

  assert.deepEqual(messages, []);
});

test('normalizeMessage converts background api_error system events to errors', () => {
  const messages = normalizeMessage(
    {
      uuid: 'api-error',
      type: 'system',
      subtype: 'api_error',
      timestamp: '2026-04-29T12:00:01.000Z',
      cause: {
        code: 'ConnectionRefused',
        path: 'http://ccr.local/v1/messages?beta=true',
      },
      retryAttempt: 2,
      maxRetries: 10,
    },
    'background-session',
    { sessionKind: 'background_task' }
  );

  assert.equal(messages.length, 1);
  assert.equal(messages[0].kind, 'error');
  assert.match(messages[0].content, /ConnectionRefused/);
  assert.match(messages[0].content, /Retry 2\/10/);
});

test('normalizeMessage converts compacting status system events', () => {
  const messages = normalizeMessage(
    {
      uuid: 'status-compacting',
      type: 'system',
      subtype: 'status',
      status: 'compacting',
      compact_progress: {
        level: 3,
        stage: 'summary',
        label: 'Summary compaction',
        state: 'running',
        pre_tokens: 123456,
      },
      timestamp: '2026-04-29T12:00:01.000Z',
    },
    'regular-session'
  );

  assert.equal(messages.length, 1);
  assert.equal(messages[0].kind, 'status');
  assert.equal(messages[0].text, 'compacting');
  assert.equal(messages[0].canInterrupt, true);
  assert.deepEqual(messages[0].compactProgress, {
    level: 3,
    stage: 'summary',
    label: 'Summary compaction',
    state: 'running',
    pre_tokens: 123456,
  });
});

test('normalizeMessage accepts camelCase compact progress fields', () => {
  const messages = normalizeMessage(
    {
      uuid: 'status-compacting-camel',
      type: 'system',
      subtype: 'status',
      status: 'compacting',
      compactProgress: {
        level: 5,
        stage: 'overflow_recovery',
        stageLabel: 'Overflow recovery compaction',
        state: 'started',
        preTokens: 200000,
      },
      timestamp: '2026-04-29T12:00:01.000Z',
    },
    'regular-session'
  );

  assert.equal(messages.length, 1);
  assert.deepEqual(messages[0].compactProgress, {
    level: 5,
    stage: 'overflow_recovery',
    label: 'Overflow recovery compaction',
    state: 'started',
    pre_tokens: 200000,
  });
});

test('normalizeMessage converts compact boundary system events', () => {
  const messages = normalizeMessage(
    {
      uuid: 'compact-boundary',
      type: 'system',
      subtype: 'compact_boundary',
      timestamp: '2026-04-29T12:00:01.000Z',
      compact_metadata: {
        trigger: 'auto',
        pre_tokens: 123456,
        level: 5,
        stage: 'overflow_recovery',
        stage_label: 'Overflow recovery compaction',
      },
    },
    'regular-session'
  );

  assert.equal(messages.length, 1);
  assert.equal(messages[0].kind, 'compact_boundary');
  assert.equal(messages[0].trigger, 'auto');
  assert.equal(messages[0].preTokens, 123456);
  assert.equal(messages[0].compactLevel, 5);
  assert.equal(messages[0].compactStage, 'overflow_recovery');
  assert.equal(messages[0].compactStageLabel, 'Overflow recovery compaction');
});

test('normalizeMessage keeps synthetic assistant API errors as errors', () => {
  const messages = normalizeMessage(
    {
      uuid: 'synthetic-api-error',
      type: 'assistant',
      isApiErrorMessage: true,
      timestamp: '2026-04-29T12:00:02.000Z',
      message: {
        role: 'assistant',
        model: '<synthetic>',
        content: [
          {
            type: 'text',
            text: 'API Error: Unable to connect to API (ConnectionRefused)',
          },
        ],
      },
    },
    'background-session',
    { sessionKind: 'background_task' }
  );

  assert.equal(messages.length, 1);
  assert.equal(messages[0].kind, 'error');
  assert.equal(messages[0].content, 'API Error: Unable to connect to API (ConnectionRefused)');
});
