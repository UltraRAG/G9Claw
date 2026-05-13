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

  it('stringifies unknown inputs for debugging instead of returning empty content', () => {
    expect(extractPlanMarkdown({ requestId: 'plan-1' })).toContain('"requestId": "plan-1"');
  });
});
