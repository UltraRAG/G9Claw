/**
 * CCR (Claude Code Router) API routes — zero-port mode.
 *
 * Directly calls CCR services in-process instead of proxying HTTP.
 * Exposes stats, health, config CRUD, and dashboard endpoints.
 */

import { Router } from 'express';
import {
  getCCRBaseUrl,
  getCCRModule,
  getCCRServices,
  getCCRInstance,
  loadCCRConfig,
  saveCCRConfig,
  restartCCR,
} from '../embedded-ccr.js';
import { resolveClaudeCodeMainRoot } from '../claude-code-main-path.js';
import { buildCcrConfig, readEdgeClawConfigFile } from '../services/edgeclawConfig.js';
import { getProjects, getSessions } from '../projects.js';
import { readFile, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

const router = Router();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getCollector() {
  const mod = getCCRModule();
  if (!mod?.getGlobalStatsCollector) return null;
  return mod.getGlobalStatsCollector();
}

function maskApiKey(key) {
  if (!key || typeof key !== 'string' || key.length < 12) return key;
  return key.slice(0, 6) + '****' + key.slice(-4);
}

function sanitizeConfigForClient(config) {
  if (!config) return config;
  const clone = JSON.parse(JSON.stringify(config));
  if (Array.isArray(clone.Providers)) {
    for (const p of clone.Providers) {
      if (p.api_key) p.api_key = maskApiKey(p.api_key);
    }
  }
  return clone;
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

router.get('/health', (_req, res) => {
  const services = getCCRServices();
  if (!services) {
    return res.status(503).json({ error: 'CCR not running', embedded: false });
  }
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    port: null,
    embedded: true,
    zeroPort: true,
  });
});

// ---------------------------------------------------------------------------
// Stats — direct service calls (no HTTP proxy)
// ---------------------------------------------------------------------------

router.get('/stats/summary', (_req, res) => {
  const collector = getCollector();
  if (!collector) return res.json({ error: 'Token stats not enabled' });
  res.json(collector.getSummary());
});

router.get('/stats/sessions', (_req, res) => {
  const collector = getCollector();
  if (!collector) return res.json({ error: 'Token stats not enabled' });
  res.json(collector.getSessionStats());
});

router.get('/stats/sessions/:sessionId', (req, res) => {
  const collector = getCollector();
  if (!collector) return res.status(503).json({ error: 'Token stats not enabled' });

  const sessions = collector.getSessionStats();
  const all = Array.isArray(sessions) ? sessions : [];
  const match = all.find((s) => s.sessionId === req.params.sessionId);
  if (!match) return res.status(404).json({ error: 'Session not found in CCR stats' });
  res.json(match);
});

router.get('/stats/hourly', (_req, res) => {
  const collector = getCollector();
  if (!collector) return res.json({ error: 'Token stats not enabled' });
  res.json(collector.getHourly());
});

router.post('/stats/reset', async (_req, res) => {
  const collector = getCollector();
  if (!collector) return res.json({ error: 'Token stats not enabled' });
  await collector.reset();
  res.json({ message: 'Stats reset successfully' });
});

// ---------------------------------------------------------------------------
// Config CRUD
// ---------------------------------------------------------------------------

router.get('/config', (_req, res) => {
  try {
    const ccrRoot = resolveClaudeCodeMainRoot();
    const config = loadCCRConfig(ccrRoot);
    if (!config) return res.status(404).json({ error: 'Router not enabled — set router.enabled: true in ~/.edgeclaw/config.yaml' });
    res.json(sanitizeConfigForClient(config));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.put('/config', async (req, res) => {
  try {
    const incoming = req.body;
    if (!incoming || typeof incoming !== 'object') {
      return res.status(400).json({ error: 'Invalid config body' });
    }

    const ccrRoot = resolveClaudeCodeMainRoot();
    const existing = loadCCRConfig(ccrRoot);

    if (existing && Array.isArray(incoming.Providers) && Array.isArray(existing.Providers)) {
      for (const provider of incoming.Providers) {
        if (provider.api_key && provider.api_key.includes('****')) {
          const orig = existing.Providers.find((p) => p.name === provider.name);
          if (orig) provider.api_key = orig.api_key;
        }
      }
    }

    saveCCRConfig(incoming);

    try {
      const result = await restartCCR();
      res.json({ success: true, restarted: true, zeroPort: true });
    } catch (restartErr) {
      res.json({ success: true, restarted: false, restartError: restartErr.message });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Dashboard — cross-references projects with CCR session stats
// ---------------------------------------------------------------------------

function extractPlainQuery(raw) {
  if (!raw || !raw.startsWith('{')) return raw || '';
  try {
    const obj = JSON.parse(raw);
    return obj.query || obj.focus_user_turn?.content || raw;
  } catch { /* JSON may be truncated */ }
  // Regex fallback for truncated JSON — content may not have closing quote
  const m = raw.match(/"(?:query|content)":\s*"([^"]{2,})/);
  if (m) return m[1].replace(/["}\]\\,\s]+$/, '').replace(/…$/, '');
  return raw;
}

async function extractUserQueries(projectName, sessionId, limit = 20) {
  try {
    const sessionPath = join(homedir(), '.claude', 'projects', projectName, `${sessionId}.jsonl`);
    const raw = await readFile(sessionPath, 'utf-8');
    const queries = [];
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const entry = JSON.parse(line);
        if (entry.message?.role !== 'user') continue;
        let text = entry.message.content;
        if (Array.isArray(text) && text.length > 0 && text[0].type === 'text') text = text[0].text;
        if (typeof text !== 'string' || !text || text.startsWith('<') || text.startsWith('{')) continue;
        if (text === 'Warmup' || text.startsWith('Caveat:') || text.startsWith('This session is being continued')) continue;
        queries.push(text.length > 120 ? text.slice(0, 120) + '…' : text);
        if (queries.length >= limit) break;
      } catch { /* skip malformed lines */ }
    }
    return queries;
  } catch {
    return [];
  }
}

function emptyBucket() {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    totalTokens: 0,
    requestCount: 0,
    estimatedCost: 0,
    baselineCost: 0,
    savedCost: 0,
  };
}

function mergeBuckets(target, source) {
  target.inputTokens += source.inputTokens || 0;
  target.outputTokens += source.outputTokens || 0;
  target.cacheReadTokens += source.cacheReadTokens || 0;
  target.totalTokens += source.totalTokens || 0;
  target.requestCount += source.requestCount || 0;
  target.estimatedCost += source.estimatedCost || 0;
  target.baselineCost += source.baselineCost || 0;
  target.savedCost += source.savedCost || 0;
}

function mergeRecordBuckets(target, source) {
  for (const [key, bucket] of Object.entries(source || {})) {
    if (!target[key]) target[key] = emptyBucket();
    mergeBuckets(target[key], bucket);
  }
}

const transcriptStatsCache = new Map();
const TRANSCRIPT_STATS_CACHE_MAX = 300;

function normalizeText(value) {
  return String(value || '').trim();
}

function projectMatchesFilter(project, filter) {
  const needle = normalizeText(filter);
  if (!needle) return true;
  return [project.name, project.displayName, project.fullPath, project.path]
    .map(normalizeText)
    .some((value) => value === needle || value.endsWith(`/${needle}`));
}

function displayNameFromProjectName(projectName, requestedProject) {
  const requested = normalizeText(requestedProject);
  if (requested && !requested.startsWith('-')) return requested;
  const parts = normalizeText(projectName).split('-').filter(Boolean);
  return parts[parts.length - 1] || projectName;
}

async function resolveClaudeProjectName(requestedProject) {
  const needle = normalizeText(requestedProject);
  if (!needle) return null;
  const projectsDir = join(homedir(), '.claude', 'projects');
  let entries = [];
  try {
    entries = await readdir(projectsDir, { withFileTypes: true });
  } catch {
    return null;
  }
  const names = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name);
  return (
    names.find((name) => name === needle) ||
    names.find((name) => name.endsWith(`-${needle}`)) ||
    names.find((name) => name.includes(needle)) ||
    null
  );
}

async function getProjectsForDashboard(requestedProject) {
  if (!requestedProject) return getProjects();
  const projectName = await resolveClaudeProjectName(requestedProject);
  if (!projectName) {
    const allProjects = await getProjects().catch(() => []);
    return allProjects.filter((project) => projectMatchesFilter(project, requestedProject));
  }

  const sessionResult = await getSessions(projectName, 5, 0);
  const sessions = sessionResult.sessions || [];
  return [{
    name: projectName,
    displayName: displayNameFromProjectName(projectName, requestedProject),
    fullPath: sessions.find((session) => session.cwd)?.cwd || '',
    sessions,
    cursorSessions: [],
    codexSessions: [],
    geminiSessions: [],
  }];
}

function normalizeUsage(usage) {
  if (!usage || typeof usage !== 'object') return { input: 0, output: 0, cacheRead: 0 };
  return {
    input: Number(usage.input_tokens ?? usage.input ?? 0) || 0,
    output: Number(usage.output_tokens ?? usage.output ?? 0) || 0,
    cacheRead: Number(usage.cache_read_input_tokens ?? usage.cacheRead ?? 0) || 0,
  };
}

function getPricingContext() {
  try {
    const { config } = readEdgeClawConfigFile();
    const ccrConfig = buildCcrConfig(config);
    return {
      modelPricing: ccrConfig.tokenStats?.modelPricing || {},
      savingsBaselineModel: ccrConfig.tokenStats?.savingsBaselineModel || null,
    };
  } catch {
    return { modelPricing: {}, savingsBaselineModel: null };
  }
}

function parseModelRef(ref) {
  const text = normalizeText(ref);
  if (!text) return { provider: '', model: '' };
  const [provider, ...modelParts] = text.split(',');
  return modelParts.length > 0
    ? { provider, model: modelParts.join(',') }
    : { provider: '', model: provider };
}

function lookupPricing(model, provider, pricing) {
  const fallback = { inputPer1M: 3, outputPer1M: 15 };
  if (!pricing || typeof pricing !== 'object') return fallback;

  const providerModel = provider ? `${provider},${model}` : '';
  const direct = providerModel && pricing[providerModel]
    ? pricing[providerModel]
    : provider && pricing[provider]
      ? pricing[provider]
      : pricing[model];
  if (direct) {
    return {
      inputPer1M: direct.inputPer1M ?? fallback.inputPer1M,
      outputPer1M: direct.outputPer1M ?? fallback.outputPer1M,
    };
  }

  const lowerModel = normalizeText(model).toLowerCase();
  const match = Object.entries(pricing)
    .filter(([key]) => !key.includes(',') && lowerModel.includes(key.toLowerCase()))
    .sort(([a], [b]) => b.length - a.length)[0];
  if (!match) return fallback;
  const [, value] = match;
  return {
    inputPer1M: value.inputPer1M ?? fallback.inputPer1M,
    outputPer1M: value.outputPer1M ?? fallback.outputPer1M,
  };
}

function calculateUsageCost(usage, model, provider, pricing) {
  const p = lookupPricing(model, provider, pricing);
  return ((usage.input || 0) * p.inputPer1M + (usage.output || 0) * p.outputPer1M) / 1_000_000;
}

function calculateBaselineCost(usage, pricingContext, fallbackProvider, fallbackModel) {
  const baseline = parseModelRef(pricingContext.savingsBaselineModel);
  const provider = baseline.provider || fallbackProvider;
  const model = baseline.model || fallbackModel;
  return calculateUsageCost(usage, model, provider, pricingContext.modelPricing);
}

function addUsageBucket(bucket, usage, cost, baselineCost) {
  bucket.inputTokens += usage.input || 0;
  bucket.outputTokens += usage.output || 0;
  bucket.cacheReadTokens += usage.cacheRead || 0;
  bucket.totalTokens += (usage.input || 0) + (usage.output || 0);
  bucket.requestCount += 1;
  bucket.estimatedCost += cost || 0;
  bucket.baselineCost += baselineCost || 0;
  bucket.savedCost += (baselineCost || 0) - (cost || 0);
}

function ensureRecordBucket(map, key) {
  if (!map[key]) map[key] = emptyBucket();
  return map[key];
}

function extractUserText(entry) {
  if (entry?.message?.role !== 'user') return '';
  const content = entry.message.content;
  let text = '';
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    const firstText = content.find((part) => part?.type === 'text' && typeof part.text === 'string');
    text = firstText?.text || '';
  }
  if (!text || text.startsWith('<') || text.startsWith('{')) return '';
  if (text === 'Warmup' || text.startsWith('Caveat:') || text.startsWith('This session is being continued')) return '';
  return text;
}

async function readTranscriptStats(projectName, sessionId, pricingContext) {
  const sessionPath = join(homedir(), '.claude', 'projects', projectName, `${sessionId}.jsonl`);
  let fileStat;
  try {
    fileStat = await stat(sessionPath);
  } catch {
    return { userQueries: [], stats: null };
  }

  const cacheKey = `${sessionPath}:${fileStat.mtimeMs}:${fileStat.size}`;
  const cached = transcriptStatsCache.get(cacheKey);
  if (cached) return cached;

  const stats = {
    sessionId,
    total: emptyBucket(),
    byScenario: {},
    byTier: {},
    byRole: {},
    byModel: {},
    requestLog: [],
    firstSeenAt: Date.now(),
    lastActiveAt: 0,
  };
  const userQueries = [];
  let latestUserQuery = '';

  try {
    const raw = await readFile(sessionPath, 'utf-8');
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }

      const userText = extractUserText(entry);
      if (userText) {
        latestUserQuery = userText;
        userQueries.push(userText.length > 120 ? `${userText.slice(0, 120)}…` : userText);
      }

      if (entry?.message?.role !== 'assistant') continue;
      const usage = normalizeUsage(entry.message.usage);
      const tokenTotal = usage.input + usage.output + usage.cacheRead;
      if (tokenTotal <= 0) continue;

      const model = normalizeText(entry.message.model || 'unknown');
      const provider = '';
      const role = entry.isSidechain ? 'sub' : 'main';
      const tier = 'RECORDED';
      const scenario = 'transcript';
      const ts = entry.timestamp ? Date.parse(entry.timestamp) : Date.now();
      const cost = calculateUsageCost(usage, model, provider, pricingContext.modelPricing);
      const baselineCost = calculateBaselineCost(usage, pricingContext, provider, model);

      if (!Number.isNaN(ts)) {
        if (!stats.lastActiveAt || ts > stats.lastActiveAt) stats.lastActiveAt = ts;
        if (!stats.firstSeenAt || ts < stats.firstSeenAt) stats.firstSeenAt = ts;
      }

      addUsageBucket(stats.total, usage, cost, baselineCost);
      addUsageBucket(ensureRecordBucket(stats.byScenario, scenario), usage, cost, baselineCost);
      addUsageBucket(ensureRecordBucket(stats.byTier, tier), usage, cost, baselineCost);
      addUsageBucket(ensureRecordBucket(stats.byRole, role), usage, cost, baselineCost);
      addUsageBucket(ensureRecordBucket(stats.byModel, model), usage, cost, baselineCost);

      stats.requestLog.push({
        ts: Number.isNaN(ts) ? Date.now() : ts,
        role,
        tier,
        model,
        tokens: tokenTotal,
        cost,
        baselineCost,
        savedCost: baselineCost - cost,
        query: latestUserQuery,
      });
    }
  } catch {
    return { userQueries: [], stats: null };
  }

  if (!stats.lastActiveAt) stats.lastActiveAt = fileStat.mtimeMs;
  if (!stats.firstSeenAt) stats.firstSeenAt = stats.lastActiveAt;
  if (stats.requestLog.length > 100) stats.requestLog = stats.requestLog.slice(-100);

  const result = {
    userQueries,
    stats: stats.total.requestCount > 0 ? stats : null,
  };

  transcriptStatsCache.set(cacheKey, result);
  if (transcriptStatsCache.size > TRANSCRIPT_STATS_CACHE_MAX) {
    const firstKey = transcriptStatsCache.keys().next().value;
    transcriptStatsCache.delete(firstKey);
  }
  return result;
}

router.get('/dashboard', async (_req, res) => {
  try {
    const requestedProject = normalizeText(_req.query?.project);
    const pricingContext = getPricingContext();

    // Prefer live stats from proxy subprocess over in-process collector
    let allSessions = [];
    const proxyPort = process.env.PROXY_PORT || process.env.EDGECLAW_PROXY_PORT || '18080';
    try {
      const resp = await fetch(`http://127.0.0.1:${proxyPort}/ccr-stats/sessions`, { signal: AbortSignal.timeout(2000) });
      if (resp.ok) {
        const data = await resp.json();
        if (Array.isArray(data) && data.length > 0) allSessions = data;
      }
    } catch { /* proxy unreachable, fall through to in-process collector */ }

    if (allSessions.length === 0) {
      const collector = getCollector();
      const ccrSessions = collector ? collector.getSessionStats() : [];
      allSessions = Array.isArray(ccrSessions) ? ccrSessions : [];
    }

    const projectsData = await getProjectsForDashboard(requestedProject).catch(() => []);

    // Build lookup map: exact sessionId → stats, plus suffix-based fallback
    // CCR stores sessionId as extracted from metadata.user_id's session_id field.
    // UI sessions use IDs like "abc-123" which should match directly.
    const ccrMap = new Map();
    const ccrSuffixMap = new Map();
    for (const s of allSessions) {
      ccrMap.set(s.sessionId, s);
      // Also index by last segment after underscore for legacy format matching
      const parts = (s.sessionId || '').split('_session_');
      if (parts.length > 1) ccrSuffixMap.set(parts[1], s);
    }

    function findCcrStats(uiSessionId) {
      return ccrMap.get(uiSessionId) || ccrSuffixMap.get(uiSessionId) || null;
    }

    const matchedCcrIds = new Set();
    const overall = {
      total: emptyBucket(),
      byTier: {},
      byRole: {},
      projectCount: 0,
      sessionCount: 0,
    };

    const projects = [];

    for (const proj of projectsData) {
      const projSessions = [
        ...(proj.sessions || []).map((s) => ({ ...s, __provider: s.__provider || 'claude' })),
        ...(proj.cursorSessions || []).map((s) => ({ ...s, __provider: 'cursor' })),
        ...(proj.codexSessions || []).map((s) => ({ ...s, __provider: 'codex' })),
        ...(proj.geminiSessions || []).map((s) => ({ ...s, __provider: 'gemini' })),
      ];

      const aggregated = {
        total: emptyBucket(),
        byTier: {},
        byRole: {},
        sessionCount: projSessions.length,
        routedSessionCount: 0,
      };

      const sessions = await Promise.all(projSessions.map(async (s) => {
        const sid = s.id;
        const ccrStats = findCcrStats(sid);
        const transcript = ccrStats ? { userQueries: [], stats: null } : await readTranscriptStats(proj.name, sid, pricingContext);
        const routingStats = ccrStats || transcript.stats;
        if (routingStats) {
          if (ccrStats) matchedCcrIds.add(ccrStats.sessionId);
          aggregated.routedSessionCount++;
          mergeBuckets(aggregated.total, routingStats.total || {});
          mergeRecordBuckets(aggregated.byTier, routingStats.byTier);
          mergeRecordBuckets(aggregated.byRole, routingStats.byRole);
        }

        const userQueries = ccrStats?.requestLog?.map((entry) => entry.query).filter(Boolean) || transcript.userQueries || [];

        return {
          sessionId: sid,
          title: s.summary || s.title || s.name || s.lastUserMessage || '',
          provider: s.__provider || 'claude',
          lastActivity: s.lastActivity || s.updated_at || s.createdAt || null,
          userQueries,
          routing: routingStats
            ? {
                total: routingStats.total,
                byTier: routingStats.byTier || {},
                byScenario: routingStats.byScenario || {},
                byRole: routingStats.byRole || {},
                byModel: routingStats.byModel || {},
                requestLog: routingStats.requestLog || [],
                firstSeenAt: routingStats.firstSeenAt,
                lastActiveAt: routingStats.lastActiveAt,
              }
            : null,
        };
      }));

      mergeBuckets(overall.total, aggregated.total);
      mergeRecordBuckets(overall.byTier, aggregated.byTier);
      mergeRecordBuckets(overall.byRole, aggregated.byRole);
      overall.sessionCount += aggregated.sessionCount;

      projects.push({
        name: proj.name,
        displayName: proj.displayName || proj.name,
        fullPath: proj.fullPath || proj.path || '',
        sessions,
        aggregated,
      });
    }

    overall.projectCount = projects.length;

    const unmatchedSessions = requestedProject ? [] : allSessions.filter((s) => !matchedCcrIds.has(s.sessionId));

    if (!requestedProject) {
      // Merge unmatched sessions into the "general" project on the overview.
      let generalProject = projects.find((p) => p.displayName === 'general' || p.name === 'general');
      if (!generalProject) {
        generalProject = {
          name: 'general',
          displayName: 'general',
          fullPath: '',
          sessions: [],
          aggregated: { total: emptyBucket(), byTier: {}, byRole: {}, sessionCount: 0, routedSessionCount: 0 },
        };
        projects.push(generalProject);
        overall.projectCount = projects.length;
      }

      for (const s of unmatchedSessions) {
        mergeBuckets(overall.total, s.total || {});
        mergeRecordBuckets(overall.byTier, s.byTier);
        mergeRecordBuckets(overall.byRole, s.byRole);

        mergeBuckets(generalProject.aggregated.total, s.total || {});
        mergeRecordBuckets(generalProject.aggregated.byTier, s.byTier);
        mergeRecordBuckets(generalProject.aggregated.byRole, s.byRole);
        generalProject.aggregated.sessionCount++;
        if (s.total && s.total.requestCount > 0) generalProject.aggregated.routedSessionCount++;

        let unmatchedTitle = s.sessionId;
        const firstQuery = s.requestLog?.[0]?.query;
        if (firstQuery) {
          unmatchedTitle = extractPlainQuery(firstQuery);
          if (unmatchedTitle.length > 80) unmatchedTitle = unmatchedTitle.slice(0, 80) + '…';
        }

        generalProject.sessions.push({
          sessionId: s.sessionId,
          title: unmatchedTitle,
          provider: 'router',
          lastActivity: s.lastActiveAt ? new Date(s.lastActiveAt).toISOString() : null,
          userQueries: (s.requestLog || []).filter((e) => e.role === 'main').map((e) => e.query ? extractPlainQuery(e.query) : null).filter(Boolean),
          routing: {
            total: s.total,
            byTier: s.byTier || {},
            byScenario: s.byScenario || {},
            byRole: s.byRole || {},
            byModel: s.byModel || {},
            requestLog: s.requestLog || [],
            firstSeenAt: s.firstSeenAt,
            lastActiveAt: s.lastActiveAt,
          },
        });
      }

      overall.sessionCount += unmatchedSessions.length;
    }

    res.json({ projects, overall, unmatchedSessions: [] });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
