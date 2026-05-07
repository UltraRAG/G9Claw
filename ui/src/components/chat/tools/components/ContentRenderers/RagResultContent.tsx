import React from 'react';
import type { ParsedRagToolResult } from '../../utils/ragToolResult';

interface RagResultContentProps {
  data: ParsedRagToolResult;
}

function compactText(value: unknown, maxLength = 360): string {
  const text = typeof value === 'string'
    ? value
    : value === undefined || value === null
      ? ''
      : String(value);
  const normalized = text.replace(/\s+/g, ' ').trim();
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, maxLength - 3)}...`;
}

function hostname(url: unknown): string {
  if (typeof url !== 'string' || !url.trim()) return '';
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return url;
  }
}

function formatValue(value: unknown): string {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : value.toFixed(3);
  if (typeof value === 'boolean') return value ? 'yes' : 'no';
  return String(value);
}

function getTitle(item: any, index: number): string {
  return compactText(item?.title || item?.name || item?.id || item?.url || `Result ${index + 1}`, 140);
}

function getSnippet(item: any): string {
  return compactText(item?.snippet || item?.content || item?.text || item?.summary || item?.body || '', 420);
}

function getSourceLine(item: any, sourceKind: ParsedRagToolResult['sourceKind']): string {
  if (sourceKind === 'web') {
    const site = hostname(item?.url) || formatValue(item?.source);
    const published = formatValue(item?.publishedAt);
    return [site, published].filter(Boolean).join(' | ');
  }

  if (sourceKind === 'local') {
    const source = formatValue(item?.source);
    const id = formatValue(item?.id);
    const score = formatValue(item?.score);
    return [
      source,
      id ? `id=${id}` : '',
      score ? `score=${score}` : '',
    ].filter(Boolean).join(' | ');
  }

  return formatValue(item?.source || item?.url || item?.id);
}

export const RagResultContent: React.FC<RagResultContentProps> = ({ data }) => {
  const resultCount = data.debug.resultCount ?? data.results.length;
  const topK = data.debug.topK;
  const status = data.debug.status;
  const elapsedMs = data.debug.elapsedMs;
  const endpoint = hostname(data.debug.url) || data.debug.url;

  return (
    <div className="mt-1 space-y-2 text-xs text-gray-700 dark:text-gray-300">
      <div className="rounded-md border border-gray-200/70 bg-gray-50/70 px-2.5 py-2 dark:border-gray-700/60 dark:bg-gray-900/30">
        <div className="flex flex-wrap items-center gap-1.5">
          <span className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${
            data.ok
              ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300'
              : 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300'
          }`}>
            {data.ok ? 'OK' : 'Error'}
          </span>
          <span className="font-medium text-gray-900 dark:text-gray-100">{data.sourceLabel}</span>
          {endpoint && <span className="text-gray-400 dark:text-gray-500">via {endpoint}</span>}
        </div>

        {data.query && (
          <div className="mt-1.5 break-words text-gray-600 dark:text-gray-400">
            <span className="font-medium text-gray-800 dark:text-gray-200">Query:</span> {data.query}
          </div>
        )}

        <div className="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-gray-500 dark:text-gray-400">
          <span>results={formatValue(resultCount) || '0'}</span>
          {topK !== undefined && <span>topK={formatValue(topK)}</span>}
          {status !== undefined && <span>status={formatValue(status)}</span>}
          {elapsedMs !== undefined && <span>elapsed={formatValue(elapsedMs)}ms</span>}
        </div>
      </div>

      {data.error && (
        <div className="rounded-md border border-red-200/70 bg-red-50/70 px-2.5 py-2 text-red-800 dark:border-red-800/50 dark:bg-red-950/20 dark:text-red-200">
          <div className="font-medium">{data.error.code || 'rag_error'}</div>
          {data.error.message && <div className="mt-0.5 break-words">{data.error.message}</div>}
        </div>
      )}

      {data.results.length > 0 ? (
        <ol className="divide-y divide-gray-200/70 rounded-md border border-gray-200/70 dark:divide-gray-700/60 dark:border-gray-700/60">
          {data.results.map((item, index) => {
            const title = getTitle(item, index);
            const snippet = getSnippet(item);
            const sourceLine = getSourceLine(item, data.sourceKind);
            const url = typeof item?.url === 'string' ? item.url : '';

            return (
              <li key={`${title}-${index}`} className="px-2.5 py-2">
                <div className="flex gap-2">
                  <span className="mt-0.5 w-5 flex-shrink-0 text-right font-mono text-[11px] text-gray-400 dark:text-gray-500">
                    {index + 1}
                  </span>
                  <div className="min-w-0 flex-1">
                    {url ? (
                      <a
                        href={url}
                        target="_blank"
                        rel="noreferrer"
                        className="break-words font-medium text-blue-700 hover:underline dark:text-blue-300"
                      >
                        {title}
                      </a>
                    ) : (
                      <div className="break-words font-medium text-gray-900 dark:text-gray-100">{title}</div>
                    )}
                    {sourceLine && (
                      <div className="mt-0.5 break-words text-[11px] text-gray-500 dark:text-gray-400">
                        {sourceLine}
                      </div>
                    )}
                    {snippet && (
                      <div className="mt-1 break-words leading-5 text-gray-700 dark:text-gray-300">
                        {snippet}
                      </div>
                    )}
                  </div>
                </div>
              </li>
            );
          })}
        </ol>
      ) : (
        <div className="rounded-md border border-gray-200/70 px-2.5 py-2 text-gray-500 dark:border-gray-700/60 dark:text-gray-400">
          No results returned.
        </div>
      )}

      <details className="group/raw">
        <summary className="flex cursor-pointer items-center gap-1.5 text-[11px] text-gray-400 hover:text-gray-600 dark:text-gray-500 dark:hover:text-gray-300">
          <svg
            className="h-2.5 w-2.5 transition-transform duration-150 group-open/raw:rotate-90"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
          </svg>
          raw retrieval JSON
        </summary>
        <pre className="mt-1 max-h-72 overflow-auto rounded border border-gray-200/50 bg-gray-50 p-2 font-mono text-[11px] text-gray-600 dark:border-gray-700/50 dark:bg-gray-950/40 dark:text-gray-400">
          {JSON.stringify(data.payload, null, 2)}
        </pre>
      </details>
    </div>
  );
};
