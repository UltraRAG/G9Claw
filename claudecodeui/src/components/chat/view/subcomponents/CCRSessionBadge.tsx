import { useCCRSessionStats } from '../../../../hooks/useCCRSessionStats';

const TIER_STYLES: Record<string, string> = {
  SIMPLE: 'bg-green-500/15 text-green-700 dark:text-green-400 border-green-500/20',
  MEDIUM: 'bg-blue-500/15 text-blue-700 dark:text-blue-400 border-blue-500/20',
  COMPLEX: 'bg-orange-500/15 text-orange-700 dark:text-orange-400 border-orange-500/20',
  REASONING: 'bg-purple-500/15 text-purple-700 dark:text-purple-400 border-purple-500/20',
};

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatCost(n: number): string {
  if (n === 0) return '';
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(3)}`;
}

type CCRSessionBadgeProps = {
  sessionId: string | null | undefined;
};

export default function CCRSessionBadge({ sessionId }: CCRSessionBadgeProps) {
  const { stats } = useCCRSessionStats(sessionId);

  if (!stats || !stats.total) return null;

  const tiers = Object.keys(stats.byTier || {});
  const primaryTier = tiers.length > 0
    ? tiers.reduce((a, b) =>
        (stats.byTier[a]?.requestCount || 0) >= (stats.byTier[b]?.requestCount || 0) ? a : b
      )
    : null;

  const { totalTokens, requestCount, estimatedCost } = stats.total;

  return (
    <div className="flex items-center gap-1.5 text-[10px] leading-none">
      {primaryTier && (
        <span
          className={`inline-flex items-center rounded border px-1.5 py-0.5 font-medium ${TIER_STYLES[primaryTier] || 'border-border bg-muted text-muted-foreground'}`}
          title={`Most-used tier: ${primaryTier} (${stats.byTier[primaryTier]?.requestCount || 0} requests)`}
        >
          {primaryTier}
        </span>
      )}
      {tiers.length > 1 && (
        <span className="text-muted-foreground" title={`Tiers used: ${tiers.join(', ')}`}>
          +{tiers.length - 1}
        </span>
      )}
      <span className="text-muted-foreground" title={`${requestCount} requests, ${totalTokens.toLocaleString()} tokens`}>
        {formatTokens(totalTokens)}
      </span>
      {estimatedCost > 0 && (
        <span className="text-muted-foreground" title={`Estimated cost: $${estimatedCost.toFixed(4)}`}>
          {formatCost(estimatedCost)}
        </span>
      )}
    </div>
  );
}
