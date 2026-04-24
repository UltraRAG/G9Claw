import { useCallback, useEffect, useState } from 'react';
import { AlertCircle, Loader2, RefreshCw } from 'lucide-react';
import type { Project } from '../../types/app';
import { authenticatedFetch } from '../../utils/api';
import { cn } from '../../lib/utils.js';

type MemoryItem = {
  name?: string;
  description?: string;
  type?: string;
  scope?: string;
  projectId?: string;
  updatedAt?: string;
  capturedAt?: string;
  relativePath?: string;
  file?: string;
};

type MemoryV2Props = {
  selectedProject: Project | null;
};

function formatRelative(iso?: string): string {
  if (!iso) return '—';
  const parsed = Date.parse(iso);
  if (Number.isNaN(parsed)) return '—';
  const diffMs = Date.now() - parsed;
  const diffSec = Math.round(diffMs / 1000);
  if (diffSec < 60) return 'just now';
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 30) return `${diffDay}d ago`;
  return new Date(parsed).toLocaleDateString();
}

export default function MemoryV2({ selectedProject }: MemoryV2Props) {
  const [items, setItems] = useState<MemoryItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const projectPath = selectedProject?.fullPath || selectedProject?.path || null;

  const refresh = useCallback(async () => {
    if (!projectPath) {
      setItems([]);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const params = new URLSearchParams({ projectPath, limit: '50' });
      const response = await authenticatedFetch(`/api/memory/memory/list?${params.toString()}`);
      if (!response.ok) {
        const body = (await response.json().catch(() => ({}))) as { error?: string };
        throw new Error(body?.error || `HTTP ${response.status}`);
      }
      const data = (await response.json()) as MemoryItem[] | { items?: MemoryItem[] };
      const list: MemoryItem[] = Array.isArray(data) ? data : Array.isArray(data?.items) ? data.items : [];
      setItems(list);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, [projectPath]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  if (!selectedProject) {
    return (
      <div className="flex h-full items-center justify-center bg-white text-[13px] text-neutral-500 dark:bg-neutral-950 dark:text-neutral-400">
        Pick a project to inspect memory.
      </div>
    );
  }

  return (
    <div className="h-full overflow-y-auto bg-white dark:bg-neutral-950">
      <div className="mx-auto w-full max-w-[960px] space-y-4 px-8 py-8">
        <div className="flex items-start justify-between">
          <div>
            <h2 className="text-[20px] font-semibold tracking-tight text-neutral-900 dark:text-neutral-100">
              Memory
            </h2>
            <p className="mt-0.5 text-[13px] text-neutral-500 dark:text-neutral-400">
              Facts edgeclaw remembers across sessions.
            </p>
          </div>
          <button
            type="button"
            onClick={() => void refresh()}
            disabled={loading}
            className="text-xxs inline-flex h-8 items-center gap-1.5 rounded-md border border-neutral-200 px-2.5 text-neutral-600 transition hover:bg-neutral-50 disabled:opacity-50 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
          >
            <RefreshCw className={cn('h-3.5 w-3.5', loading && 'animate-spin')} strokeWidth={1.75} />
            <span>Refresh</span>
          </button>
        </div>

        {loading && items.length === 0 ? (
          <div className="flex items-center justify-center gap-2 rounded-xl border border-neutral-200 py-10 text-[13px] text-neutral-500 dark:border-neutral-800 dark:text-neutral-400">
            <Loader2 className="h-3.5 w-3.5 animate-spin" strokeWidth={1.75} />
            <span>Loading memory…</span>
          </div>
        ) : error ? (
          <div className="flex items-center gap-3 rounded-xl border border-red-200 bg-red-50 p-4 text-[13px] text-red-700 dark:border-red-900/60 dark:bg-red-950/30 dark:text-red-400">
            <AlertCircle className="h-4 w-4" strokeWidth={1.75} />
            <span>{error}</span>
          </div>
        ) : items.length === 0 ? (
          <div className="rounded-xl border border-neutral-200 p-10 text-center text-[13px] text-neutral-500 dark:border-neutral-800 dark:text-neutral-400">
            No memories yet. Memory is built up over time as you interact with edgeclaw.
          </div>
        ) : (
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {items.map((item, index) => {
              const typeLabel = item.scope === 'project'
                ? `Project · ${item.projectId || selectedProject.displayName || selectedProject.name}`
                : item.type === 'user'
                  ? 'Preference'
                  : item.type === 'feedback'
                    ? 'Feedback'
                    : (item.type ?? 'Memory');
              const body = item.description || item.name || '';
              return (
                <div
                  key={`${item.relativePath ?? item.name ?? index}`}
                  className="rounded-xl border border-neutral-200 bg-white p-5 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div className="text-xxs uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
                    {typeLabel}
                  </div>
                  <p className="mt-2 text-[14px] leading-relaxed text-neutral-800 dark:text-neutral-200">
                    {body || <span className="italic text-neutral-400">(no content)</span>}
                  </p>
                  {item.name && body !== item.name ? (
                    <div className="text-xxs mt-2 font-mono text-neutral-500 dark:text-neutral-500">
                      {item.name}
                    </div>
                  ) : null}
                  <div className="my-3 h-px bg-neutral-200 dark:bg-neutral-800" />
                  <div className="text-xxs flex items-center justify-between text-neutral-500 dark:text-neutral-400">
                    <span>Updated {formatRelative(item.updatedAt || item.capturedAt)}</span>
                    {item.scope ? (
                      <span className="font-mono">{item.scope}</span>
                    ) : null}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
