import type { DashboardSession } from '../../hooks/useRoutingDashboard';
import TierDistributionBar from './TierDistributionBar';
import RoleSplitIndicator from './RoleSplitIndicator';

const TIER_BADGE: Record<string, string> = {
  SIMPLE: 'bg-green-500/15 text-green-700 dark:text-green-400 border-green-500/20',
  MEDIUM: 'bg-blue-500/15 text-blue-700 dark:text-blue-400 border-blue-500/20',
  COMPLEX: 'bg-orange-500/15 text-orange-700 dark:text-orange-400 border-orange-500/20',
  REASONING: 'bg-purple-500/15 text-purple-700 dark:text-purple-400 border-purple-500/20',
};

const PROVIDER_BADGE: Record<string, string> = {
  claude: 'bg-orange-500/15 text-orange-700 dark:text-orange-400',
  cursor: 'bg-blue-500/15 text-blue-700 dark:text-blue-400',
  codex: 'bg-emerald-500/15 text-emerald-700 dark:text-emerald-400',
  gemini: 'bg-indigo-500/15 text-indigo-700 dark:text-indigo-400',
};

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatCost(n: number): string {
  if (n === 0) return '--';
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(3)}`;
}

function timeAgo(ts: string | number | null): string {
  if (!ts) return '--';
  const d = typeof ts === 'number' ? ts : new Date(ts).getTime();
  if (isNaN(d)) return '--';
  const sec = Math.floor((Date.now() - d) / 1000);
  if (sec < 60) return '<1m';
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

type SessionRoutingRowProps = {
  session: DashboardSession;
};

export default function SessionRoutingRow({ session }: SessionRoutingRowProps) {
  const r = session.routing;
  const tiers = r ? Object.keys(r.byTier) : [];
  const models = r ? Object.keys(r.byModel || {}) : [];

  return (
    <div className="flex items-center gap-3 rounded-md border border-border/40 bg-card/50 px-3 py-2 text-xs">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span className={`inline-flex shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${PROVIDER_BADGE[session.provider] || 'bg-muted text-muted-foreground'}`}>
            {session.provider}
          </span>
          <span className="truncate font-medium text-foreground" title={session.title || session.sessionId}>
            {session.title || session.sessionId.slice(0, 12) + '...'}
          </span>
        </div>

        {models.length > 0 && (
          <div className="mt-0.5 flex flex-wrap gap-1">
            {models.map((m) => (
              <span key={m} className="rounded bg-muted px-1 py-0.5 text-[9px] text-muted-foreground">
                {m.replace(/^claude-/, '').replace(/-\d{8}$/, '')}
              </span>
            ))}
          </div>
        )}
      </div>

      {r ? (
        <>
          <div className="flex shrink-0 flex-wrap gap-1">
            {tiers.map((t) => (
              <span
                key={t}
                className={`inline-flex rounded border px-1.5 py-0.5 text-[10px] font-medium ${TIER_BADGE[t] || 'border-border bg-muted text-muted-foreground'}`}
              >
                {t}
              </span>
            ))}
          </div>

          <div className="hidden w-20 shrink-0 sm:block">
            <RoleSplitIndicator byRole={r.byRole || {}} />
          </div>

          <div className="w-24 shrink-0">
            <TierDistributionBar byTier={r.byTier} height="h-1.5" />
          </div>

          <div className="w-14 shrink-0 text-right tabular-nums text-muted-foreground" title={`${r.total.totalTokens.toLocaleString()} tokens`}>
            {formatTokens(r.total.totalTokens)}
          </div>

          <div className="w-16 shrink-0 text-right tabular-nums text-muted-foreground">
            {formatCost(r.total.estimatedCost)}
          </div>

          <div className="w-8 shrink-0 text-right text-muted-foreground" title={r.lastActiveAt ? new Date(r.lastActiveAt).toLocaleString() : ''}>
            {timeAgo(r.lastActiveAt)}
          </div>
        </>
      ) : (
        <span className="text-muted-foreground/50">No routing data</span>
      )}
    </div>
  );
}
