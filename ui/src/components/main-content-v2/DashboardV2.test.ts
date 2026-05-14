import { describe, expect, it } from 'vitest';
import { getSortedTierEntries } from './DashboardV2';

describe('getSortedTierEntries', () => {
  it('uses the fixed router tier display order', () => {
    const entries = getSortedTierEntries({
      COMPLEX: { estimatedCost: 3 },
      SIMPLE: { estimatedCost: 1 },
      RECORDED: { estimatedCost: 9 },
      MEDIUM: { estimatedCost: 2 },
      REASONING: { estimatedCost: 4 },
    });

    expect(entries.map(([tier]) => tier)).toEqual([
      'SIMPLE',
      'MEDIUM',
      'COMPLEX',
      'REASONING',
      'RECORDED',
    ]);
  });
});
