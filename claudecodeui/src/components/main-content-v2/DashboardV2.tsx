import type { ReactNode } from 'react';
import { useMemo } from 'react';
import { Activity, AlertCircle, DollarSign, Loader2, RefreshCw, Sigma, TrendingUp } from 'lucide-react';
import { useRoutingDashboard } from '../../hooks/useRoutingDashboard';
import type { DashboardProject, DashboardSession } from '../../hooks/useRoutingDashboard';
import { cn } from '../../lib/utils.js';

function formatTokens(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0';
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(Math.round(n));
}

function formatCost(n: number): string {
  if (!n) return '$0.00';
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

function formatTime(iso?: string | null, fallback?: number): string {
  let value: number | null = null;
  if (typeof iso === 'string' && iso) {
    const parsed = Date.parse(iso);
    if (!Number.isNaN(parsed)) value = parsed;
  }
  if (value === null && typeof fallback === 'number' && fallback > 0) {
    value = fallback;
  }
  if (value === null) return '—';
  const d = new Date(value);
  return d.toLocaleTimeString([], { hour12: false });
}

type RecentRoute = {
  key: string;
  timeLabel: string;
  provider: string;
  model: string;
  tokens: number;
};

function collectRecentRoutes(projects: DashboardProject[]): RecentRoute[] {
  const sessions: Array<{ project: DashboardProject; session: DashboardSession }> = [];
  for (const project of projects) {
    for (const session of project.sessions) {
      if (!session.routing) continue;
      sessions.push({ project, session });
    }
  }

  sessions.sort((a, b) => {
    const aTime = a.session.routing?.lastActiveAt ?? 0;
    const bTime = b.session.routing?.lastActiveAt ?? 0;
    return bTime - aTime;
  });

  const out: RecentRoute[] = [];
  for (const { session } of sessions.slice(0, 10)) {
    const routing = session.routing!;
    const modelEntries = Object.entries(routing.byModel || {});
    if (modelEntries.length === 0) continue;
    modelEntries.sort((a, b) => (b[1]?.totalTokens ?? 0) - (a[1]?.totalTokens ?? 0));
    for (const [model, bucket] of modelEntries) {
      out.push({
        key: `${session.sessionId}:${model}`,
        timeLabel: formatTime(session.lastActivity, routing.lastActiveAt),
        provider: session.provider || '—',
        model,
        tokens: bucket?.totalTokens ?? 0,
      });
      if (out.length >= 10) return out;
    }
  }
  return out;
}

export default function DashboardV2() {
  const { data, loading, error, refresh } = useRoutingDashboard();

  const recent = useMemo<RecentRoute[]>(() => {
    if (!data) return [];
    return collectRecentRoutes(data.projects);
  }, [data]);

  if (loading && !data) {
    return (
      <div className="flex h-full items-center justify-center bg-white text-neutral-500 dark:bg-neutral-950 dark:text-neutral-400">
        <Loader2 className="h-4 w-4 animate-spin" strokeWidth={1.75} />
        <span className="ml-2 text-[13px]">Loading dashboard…</span>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 bg-white text-center dark:bg-neutral-950">
        <AlertCircle className="h-8 w-8 text-red-500" strokeWidth={1.75} />
        <p className="text-[13px] text-neutral-600 dark:text-neutral-400">{error}</p>
        <button
          onClick={refresh}
          className="text-xxs rounded-md bg-neutral-900 px-3 py-1.5 text-white transition hover:opacity-90 dark:bg-neutral-50 dark:text-neutral-900"
        >
          Retry
        </button>
      </div>
    );
  }

  if (!data) return null;

  const { overall } = data;
  const totalRequests = overall.total.requestCount || 0;
  const totalTokens = overall.total.totalTokens || 0;
  const inputTokens = overall.total.inputTokens || 0;
  const outputTokens = overall.total.outputTokens || 0;
  const totalCost = overall.total.estimatedCost || 0;

  return (
    <div className="h-full overflow-y-auto bg-white dark:bg-neutral-950">
      <div className="mx-auto w-full max-w-[960px] px-8 py-8">
        <div className="flex items-start justify-between">
          <div>
            <h2 className="text-[20px] font-semibold tracking-tight text-neutral-900 dark:text-neutral-100">
              Dashboard
            </h2>
            <p className="mt-0.5 text-[13px] text-neutral-500 dark:text-neutral-400">
              Usage across all projects and sessions.
            </p>
          </div>
          <button
            type="button"
            onClick={refresh}
            disabled={loading}
            className="text-xxs inline-flex h-8 items-center gap-1.5 rounded-md border border-neutral-200 px-2.5 text-neutral-600 transition hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
          >
            <RefreshCw className={cn('h-3.5 w-3.5', loading && 'animate-spin')} strokeWidth={1.75} />
            <span>Refresh</span>
          </button>
        </div>

        <div className="mt-6 grid grid-cols-1 gap-3 md:grid-cols-3">
          <StatCard
            icon={<Activity className="h-3.5 w-3.5" strokeWidth={1.75} />}
            label="Requests"
            value={totalRequests.toLocaleString()}
            sub={overall.sessionCount ? `${overall.sessionCount} sessions` : undefined}
            hint={
              overall.projectCount
                ? (
                    <span className="inline-flex items-center gap-1 text-emerald-600 dark:text-emerald-400">
                      <TrendingUp className="h-3 w-3" strokeWidth={1.75} />
                      <span>{overall.projectCount} active projects</span>
                    </span>
                  )
                : undefined
            }
          />
          <StatCard
            icon={<Sigma className="h-3.5 w-3.5" strokeWidth={1.75} />}
            label="Tokens"
            value={formatTokens(totalTokens)}
            sub={`${formatTokens(inputTokens)} in · ${formatTokens(outputTokens)} out`}
          />
          <StatCard
            icon={<DollarSign className="h-3.5 w-3.5" strokeWidth={1.75} />}
            label="Cost"
            value={formatCost(totalCost)}
            sub={totalRequests > 0 ? `≈ ${formatCost(totalCost / totalRequests)} / request` : undefined}
          />
        </div>

        <div className="mt-6 rounded-xl border border-neutral-200 bg-white p-5 dark:border-neutral-800 dark:bg-neutral-950">
          <div className="text-xxs mb-4 uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
            Recent routes
          </div>
          {recent.length === 0 ? (
            <p className="py-6 text-center text-[13px] text-neutral-500 dark:text-neutral-400">
              No routing activity yet. Start a conversation to see stats here.
            </p>
          ) : (
            <table className="w-full text-[13px]">
              <thead className="text-xxs text-neutral-500 dark:text-neutral-400">
                <tr className="text-left">
                  <th className="pb-2 font-normal">Time</th>
                  <th className="pb-2 font-normal">Provider</th>
                  <th className="pb-2 font-normal">Model</th>
                  <th className="pb-2 text-right font-normal">Tokens</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-neutral-200 dark:divide-neutral-800">
                {recent.map((row) => (
                  <tr key={row.key}>
                    <td className="text-xxs py-2 font-mono text-neutral-500 dark:text-neutral-400">
                      {row.timeLabel}
                    </td>
                    <td className="py-2 capitalize text-neutral-700 dark:text-neutral-300">
                      {row.provider}
                    </td>
                    <td className="py-2 text-neutral-700 dark:text-neutral-300">{row.model}</td>
                    <td className="py-2 text-right font-mono text-neutral-800 dark:text-neutral-200">
                      {row.tokens.toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}

function StatCard({
  icon,
  label,
  value,
  sub,
  hint,
}: {
  icon: ReactNode;
  label: string;
  value: string;
  sub?: string;
  hint?: ReactNode;
}) {
  return (
    <div className="rounded-xl border border-neutral-200 bg-white p-5 dark:border-neutral-800 dark:bg-neutral-950">
      <div className="text-xxs flex items-center gap-2 uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
        {icon}
        <span>{label}</span>
      </div>
      <div className="mt-2 text-[28px] font-semibold tracking-tight text-neutral-900 dark:text-neutral-100">
        {value}
      </div>
      <div className="text-xxs mt-1 text-neutral-500 dark:text-neutral-400">{sub ?? ' '}</div>
      {hint ? <div className="text-xxs mt-1">{hint}</div> : null}
    </div>
  );
}
