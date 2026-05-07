export type RagSourceKind = 'web' | 'local' | 'unknown';

export interface ParsedRagToolResult {
  ok: boolean;
  query: string;
  results: any[];
  citations: any[];
  debug: Record<string, any>;
  error?: {
    code?: string;
    message?: string;
  };
  sourceKind: RagSourceKind;
  sourceLabel: string;
  payload: Record<string, any>;
  rawText: string;
}

function stringifyUnknown(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value === undefined || value === null) return '';
  if (Array.isArray(value)) {
    return value.map(stringifyUnknown).filter(Boolean).join('\n');
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    if (typeof record.text === 'string') return record.text;
    if (typeof record.content === 'string') return record.content;
    try {
      return JSON.stringify(value);
    } catch {
      return '';
    }
  }
  return String(value);
}

function extractResultText(toolResult: any): string {
  const candidates = [
    toolResult?.content,
    toolResult?.toolUseResult?.stdout,
    toolResult?.toolUseResult?.output,
    toolResult,
  ];

  for (const candidate of candidates) {
    const text = stringifyUnknown(candidate).trim();
    if (text) return text;
  }
  return '';
}

function parseJsonObject(text: string): Record<string, any> | null {
  const trimmed = text.trim();
  if (!trimmed) return null;

  const candidates = [trimmed];
  const firstBrace = trimmed.indexOf('{');
  const lastBrace = trimmed.lastIndexOf('}');
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    candidates.push(trimmed.slice(firstBrace, lastBrace + 1));
  }

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, any>;
      }
    } catch {
      // Try the next candidate.
    }
  }
  return null;
}

function hasRagShape(payload: Record<string, any>): boolean {
  if (!('query' in payload) || !Array.isArray(payload.results) || !Array.isArray(payload.citations)) {
    return false;
  }

  const context = typeof payload.context === 'string' ? payload.context : '';
  const debug = payload.debug && typeof payload.debug === 'object' ? payload.debug as Record<string, any> : {};
  const citations = payload.citations as any[];
  const errorCode = typeof payload.error?.code === 'string' ? payload.error.code : '';
  const ragErrorCodes = new Set([
    'rag_disabled',
    'missing_config',
    'invalid_arguments',
    'http_error',
    'timeout',
    'request_error',
    'invalid_json',
  ]);

  return (
    context.includes('9GClaw GLM Web Search') ||
    context.includes('9GClaw Local Knowledge Search') ||
    debug.provider === 'zai' ||
    'milvusUriConfigured' in debug ||
    citations.some((item) => item?.type === 'web' || item?.type === 'local_knowledge') ||
    Boolean(payload.error && (debug.url || ragErrorCodes.has(errorCode)))
  );
}

function inferSourceKind(payload: Record<string, any>): RagSourceKind {
  const debug = payload.debug && typeof payload.debug === 'object' ? payload.debug as Record<string, any> : {};
  const citations = Array.isArray(payload.citations) ? payload.citations : [];
  const results = Array.isArray(payload.results) ? payload.results : [];
  const context = typeof payload.context === 'string' ? payload.context : '';

  if (
    debug.provider === 'zai' ||
    context.includes('GLM Web Search') ||
    citations.some((item) => item?.type === 'web') ||
    results.some((item) => typeof item?.url === 'string' && item.url)
  ) {
    return 'web';
  }

  if (
    'milvusUriConfigured' in debug ||
    context.includes('Local Knowledge Search') ||
    citations.some((item) => item?.type === 'local_knowledge') ||
    results.some((item) => typeof item?.id === 'string' && item.id)
  ) {
    return 'local';
  }

  return 'unknown';
}

function sourceLabel(kind: RagSourceKind): string {
  if (kind === 'web') return 'Z.AI / GLM Web Search';
  if (kind === 'local') return 'Local Knowledge';
  return 'RAG Search';
}

export function parseRagToolResult(toolResult: any): ParsedRagToolResult | null {
  const rawText = extractResultText(toolResult);
  const payload = parseJsonObject(rawText);
  if (!payload || !hasRagShape(payload)) return null;

  const sourceKind = inferSourceKind(payload);
  const debug = payload.debug && typeof payload.debug === 'object'
    ? payload.debug as Record<string, any>
    : {};
  const error = payload.error && typeof payload.error === 'object'
    ? payload.error as ParsedRagToolResult['error']
    : undefined;

  return {
    ok: payload.ok !== false,
    query: typeof payload.query === 'string' ? payload.query : '',
    results: Array.isArray(payload.results) ? payload.results : [],
    citations: Array.isArray(payload.citations) ? payload.citations : [],
    debug,
    error,
    sourceKind,
    sourceLabel: sourceLabel(sourceKind),
    payload,
    rawText,
  };
}
