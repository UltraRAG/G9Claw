import { RefreshCw, AlertCircle, Zap, DollarSign, Layers, Users } from 'lucide-react';
import { useRoutingDashboard } from '../../hooks/useRoutingDashboard';
import TierDistributionBar from './TierDistributionBar';
import RoleSplitIndicator from './RoleSplitIndicator';
import ProjectRoutingCard from './ProjectRoutingCard';
import SessionRoutingRow from './SessionRoutingRow';
import { useState } from 'react';

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatCost(n: number): string {
  if (n === 0) return '$0.00';
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

function StatCard({ icon: Icon, label, value, sub }: { icon: any; label: string; value: string; sub?: string }) {
  return (
    <div className="flex items-center gap-3 rounded-lg border border-border/60 bg-card px-4 py-3">
      <div className="flex h-9 w-9 items-center justify-center rounded-md bg-muted">
        <Icon className="h-4 w-4 text-muted-foreground" />
      </div>
      <div>
        <div className="text-lg font-semibold tabular-nums text-foreground">{value}</div>
        <div className="text-xs text-muted-foreground">{label}</div>
        {sub && <div className="text-[10px] text-muted-foreground/70">{sub}</div>}
      </div>
    </div>
  );
}

export default function RoutingDashboard() {
  const { data, loading, error, refresh } = useRoutingDashboard();
  const [showUnmatched, setShowUnmatched] = useState(false);

  if (loading && !data) {
    return (
      <div className="flex h-full items-center justify-center">
        <RefreshCw className="h-5 w-5 animate-spin text-muted-foreground" />
        <span className="ml-2 text-sm text-muted-foreground">Loading dashboard...</span>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3">
        <AlertCircle className="h-8 w-8 text-destructive" />
        <p className="text-sm text-muted-foreground">{error}</p>
        <button
          onClick={refresh}
          className="rounded-md bg-primary px-3 py-1.5 text-xs text-primary-foreground hover:bg-primary/90"
        >
          Retry
        </button>
      </div>
    );
  }

  if (!data) return null;

  const { overall, projects, unmatchedSessions } = data;
  const sortedProjects = [...projects]
    .filter((p) => p.aggregated.routedSessionCount > 0 || p.sessions.length > 0)
    .sort((a, b) => b.aggregated.total.estimatedCost - a.aggregated.total.estimatedCost);

  return (
    <div className="mx-auto max-w-5xl space-y-6 p-4 sm:p-6">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-foreground">Routing Dashboard</h2>
        <button
          onClick={refresh}
          disabled={loading}
          className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1.5 text-xs text-muted-foreground transition-colors hover:bg-muted disabled:opacity-50"
        >
          <RefreshCw className={`h-3 w-3 ${loading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Overall summary */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatCard
          icon={Zap}
          label="Total Tokens"
          value={formatTokens(overall.total.totalTokens)}
          sub={`${overall.total.requestCount} requests`}
        />
        <StatCard
          icon={DollarSign}
          label="Est. Cost"
          value={formatCost(overall.total.estimatedCost)}
        />
        <StatCard
          icon={Layers}
          label="Projects"
          value={String(overall.projectCount)}
          sub={`${overall.sessionCount} sessions`}
        />
        <StatCard
          icon={Users}
          label="Main / Sub"
          value={`${((overall.byRole?.main?.requestCount || 0) + (overall.byRole?.sub?.requestCount || 0))} req`}
          sub={overall.byRole?.sub?.requestCount ? `${overall.byRole.sub.requestCount} sub-agent` : 'No sub-agents'}
        />
      </div>

      {/* Tier distribution bar */}
      {Object.keys(overall.byTier || {}).length > 0 && (
        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <span className="text-xs font-medium text-muted-foreground">Tier Distribution</span>
            <RoleSplitIndicator byRole={overall.byRole || {}} />
          </div>
          <TierDistributionBar byTier={overall.byTier} height="h-3" />
          <div className="flex flex-wrap gap-3 text-[10px] text-muted-foreground">
            {Object.entries(overall.byTier).map(([tier, bucket]) => (
              <span key={tier} className="flex items-center gap-1">
                <span className={`inline-block h-2 w-2 rounded-full ${
                  tier === 'SIMPLE' ? 'bg-green-500' :
                  tier === 'MEDIUM' ? 'bg-blue-500' :
                  tier === 'COMPLEX' ? 'bg-orange-500' :
                  tier === 'REASONING' ? 'bg-purple-500' : 'bg-gray-400'
                }`} />
                {tier}: {bucket.requestCount} req
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Projects */}
      <div className="space-y-2">
        <h3 className="text-sm font-medium text-foreground">
          Projects ({sortedProjects.length})
        </h3>
        {sortedProjects.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">
            No routing data yet. Start a conversation to see stats here.
          </p>
        ) : (
          sortedProjects.map((p) => (
            <ProjectRoutingCard key={p.name} project={p} />
          ))
        )}
      </div>

      {/* Unmatched sessions */}
      {unmatchedSessions.length > 0 && (
        <div className="space-y-2">
          <button
            type="button"
            onClick={() => setShowUnmatched(!showUnmatched)}
            className="flex items-center gap-1.5 text-sm font-medium text-muted-foreground hover:text-foreground"
          >
            <span>Unmatched Sessions ({unmatchedSessions.length})</span>
            <span className="text-[10px]">{showUnmatched ? '▼' : '▶'}</span>
          </button>
          {showUnmatched && (
            <div className="space-y-1">
              {unmatchedSessions.map((s) => (
                <SessionRoutingRow
                  key={s.sessionId}
                  session={{
                    sessionId: s.sessionId,
                    title: '',
                    provider: 'unknown',
                    lastActivity: null,
                    routing: {
                      total: s.total,
                      byTier: s.byTier || {},
                      byScenario: s.byScenario || {},
                      byRole: s.byRole || {},
                      byModel: s.byModel || {},
                      firstSeenAt: s.firstSeenAt,
                      lastActiveAt: s.lastActiveAt,
                    },
                  }}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
