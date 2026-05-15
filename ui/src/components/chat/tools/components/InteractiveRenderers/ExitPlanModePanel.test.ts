import { describe, expect, it } from 'vitest';
import { extractPlanMarkdown } from './ExitPlanModePanel';

describe('extractPlanMarkdown', () => {
  it('reads the plan field and normalizes escaped newlines', () => {
    expect(extractPlanMarkdown({ plan: '1. Inspect\\n2. Patch\\n3. Test' })).toBe(
      '1. Inspect\n2. Patch\n3. Test',
    );
  });

  it('falls back to common nested plan content fields', () => {
    expect(extractPlanMarkdown({ content: [{ text: 'Use Agent mode after approval.' }] })).toBe(
      'Use Agent mode after approval.',
    );
  });

  it('does not render ExitPlanModeV2 permission hints as the plan body', () => {
    expect(extractPlanMarkdown({
      allowedPrompts: [{ tool: 'Bash', prompt: 'Create files' }],
    })).toBe('计划正文正在同步，请确认是否执行。');
  });

  it('does not render an empty ExitPlanModeV2 input as raw JSON', () => {
    expect(extractPlanMarkdown({})).toBe('计划正文正在同步，请确认是否执行。');
  });

  it('stringifies unknown inputs for debugging instead of returning empty content', () => {
    expect(extractPlanMarkdown({ requestId: 'plan-1' })).toContain('"requestId": "plan-1"');
  });
});
