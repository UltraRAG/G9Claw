import { useState } from 'react';
import { ChevronRight, FolderOpen } from 'lucide-react';
import type { DashboardProject } from '../../hooks/useRoutingDashboard';
import TierDistributionBar from './TierDistributionBar';
import RoleSplitIndicator from './RoleSplitIndicator';
import SessionRoutingRow from './SessionRoutingRow';

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatCost(n: number): string {
  if (n === 0) return '--';
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

type ProjectRoutingCardProps = {
  project: DashboardProject;
  defaultExpanded?: boolean;
};

export default function ProjectRoutingCard({ project, defaultExpanded = false }: ProjectRoutingCardProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  const { aggregated } = project;
  const hasRouting = aggregated.routedSessionCount > 0;

  return (
    <div className="overflow-hidden rounded-lg border border-border/60 bg-card">
      <button
        type="button"
        onClick={() => setExpanded(!expanded)}
        className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-muted/40"
      >
        <ChevronRight
          className={`h-4 w-4 shrink-0 text-muted-foreground transition-transform ${expanded ? 'rotate-90' : ''}`}
        />
        <FolderOpen className="h-4 w-4 shrink-0 text-muted-foreground" />

        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-2">
            <span className="truncate text-sm font-medium text-foreground">
              {project.displayName}
            </span>
            <span className="shrink-0 text-xs text-muted-foreground">
              {aggregated.routedSessionCount}/{aggregated.sessionCount} sessions
            </span>
          </div>
        </div>

        {hasRouting && (
          <>
            <div className="hidden w-20 shrink-0 sm:block">
              <RoleSplitIndicator byRole={aggregated.byRole || {}} />
            </div>
            <div className="w-28 shrink-0">
              <TierDistributionBar byTier={aggregated.byTier} />
            </div>
            <div className="w-14 shrink-0 text-right text-xs tabular-nums text-muted-foreground">
              {formatTokens(aggregated.total.totalTokens)}
            </div>
            <div className="w-16 shrink-0 text-right text-xs tabular-nums text-muted-foreground">
              {formatCost(aggregated.total.estimatedCost)}
            </div>
          </>
        )}
      </button>

      {expanded && (
        <div className="space-y-1 border-t border-border/40 px-3 py-2">
          {project.sessions.length === 0 ? (
            <p className="py-3 text-center text-xs text-muted-foreground">No sessions</p>
          ) : (
            project.sessions.map((s) => (
              <SessionRoutingRow key={s.sessionId} session={s} />
            ))
          )}
        </div>
      )}
    </div>
  );
}
