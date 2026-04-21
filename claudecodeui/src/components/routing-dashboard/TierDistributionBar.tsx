import type { TokenBucket } from '../../hooks/useRouterSettings';
import { Tooltip } from '../../shared/view/ui';

const TIER_COLORS: Record<string, string> = {
  SIMPLE: 'bg-green-500',
  MEDIUM: 'bg-blue-500',
  COMPLEX: 'bg-orange-500',
  REASONING: 'bg-purple-500',
};

const TIER_ORDER = ['SIMPLE', 'MEDIUM', 'COMPLEX', 'REASONING'];

function sortTiers(tiers: [string, TokenBucket][]): [string, TokenBucket][] {
  return tiers.sort((a, b) => {
    const ai = TIER_ORDER.indexOf(a[0]);
    const bi = TIER_ORDER.indexOf(b[0]);
    return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
  });
}

type TierDistributionBarProps = {
  byTier: Record<string, TokenBucket>;
  height?: string;
};

export default function TierDistributionBar({ byTier, height = 'h-2.5' }: TierDistributionBarProps) {
  const entries = sortTiers(Object.entries(byTier));
  const totalRequests = entries.reduce((sum, [, b]) => sum + (b.requestCount || 0), 0);

  if (totalRequests === 0) {
    return <div className={`${height} w-full rounded-full bg-muted`} />;
  }

  return (
    <div className={`flex ${height} w-full overflow-hidden rounded-full bg-muted`}>
      {entries.map(([tier, bucket]) => {
        const pct = (bucket.requestCount / totalRequests) * 100;
        if (pct < 0.5) return null;
        const color = TIER_COLORS[tier] || 'bg-gray-400';
        return (
          <Tooltip
            key={tier}
            content={`${tier}: ${bucket.requestCount} req (${pct.toFixed(1)}%) — ${bucket.totalTokens.toLocaleString()} tokens`}
            position="top"
          >
            <div
              className={`${color} transition-all duration-300`}
              style={{ width: `${pct}%` }}
            />
          </Tooltip>
        );
      })}
    </div>
  );
}
