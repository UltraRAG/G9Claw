import type { TokenBucket } from '../../hooks/useRouterSettings';
import { Tooltip } from '../../shared/view/ui';

type RoleSplitIndicatorProps = {
  byRole: Record<string, TokenBucket>;
};

export default function RoleSplitIndicator({ byRole }: RoleSplitIndicatorProps) {
  const main = byRole.main?.totalTokens || 0;
  const sub = byRole.sub?.totalTokens || 0;
  const total = main + sub;

  if (total === 0) return <span className="text-xs text-muted-foreground">--</span>;

  const mainPct = (main / total) * 100;
  const subPct = (sub / total) * 100;

  return (
    <div className="flex items-center gap-1.5">
      <Tooltip
        content={`Main: ${main.toLocaleString()} tokens (${mainPct.toFixed(1)}%) | Sub: ${sub.toLocaleString()} tokens (${subPct.toFixed(1)}%)`}
        position="top"
      >
        <div className="flex h-2 w-16 overflow-hidden rounded-full bg-muted">
          {mainPct > 0 && (
            <div className="bg-blue-500 transition-all" style={{ width: `${mainPct}%` }} />
          )}
          {subPct > 0 && (
            <div className="bg-gray-400 transition-all" style={{ width: `${subPct}%` }} />
          )}
        </div>
      </Tooltip>
      <span className="text-[10px] tabular-nums text-muted-foreground">
        {sub > 0 ? `${mainPct.toFixed(0)}/${subPct.toFixed(0)}` : '100%'}
      </span>
    </div>
  );
}
