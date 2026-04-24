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
import { getProjects } from '../projects.js';

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

function emptyBucket() {
  return { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, totalTokens: 0, requestCount: 0, estimatedCost: 0 };
}

function mergeBuckets(target, source) {
  target.inputTokens += source.inputTokens || 0;
  target.outputTokens += source.outputTokens || 0;
  target.cacheReadTokens += source.cacheReadTokens || 0;
  target.totalTokens += source.totalTokens || 0;
  target.requestCount += source.requestCount || 0;
  target.estimatedCost += source.estimatedCost || 0;
}

function mergeRecordBuckets(target, source) {
  for (const [key, bucket] of Object.entries(source || {})) {
    if (!target[key]) target[key] = emptyBucket();
    mergeBuckets(target[key], bucket);
  }
}

router.get('/dashboard', async (_req, res) => {
  try {
    const collector = getCollector();
    const ccrSessions = collector ? collector.getSessionStats() : [];
    const allSessions = Array.isArray(ccrSessions) ? ccrSessions : [];

    const projectsData = await getProjects().catch(() => []);

    const ccrMap = new Map();
    for (const s of allSessions) {
      ccrMap.set(s.sessionId, s);
    }

    const matchedIds = new Set();
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

      const sessions = projSessions.map((s) => {
        const sid = s.id;
        const ccrStats = ccrMap.get(sid);
        if (ccrStats) {
          matchedIds.add(sid);
          aggregated.routedSessionCount++;
          mergeBuckets(aggregated.total, ccrStats.total || {});
          mergeRecordBuckets(aggregated.byTier, ccrStats.byTier);
          mergeRecordBuckets(aggregated.byRole, ccrStats.byRole);
        }

        return {
          sessionId: sid,
          title: s.summary || s.title || s.name || s.lastUserMessage || '',
          provider: s.__provider || 'claude',
          lastActivity: s.lastActivity || s.updated_at || s.createdAt || null,
          routing: ccrStats
            ? {
                total: ccrStats.total,
                byTier: ccrStats.byTier || {},
                byScenario: ccrStats.byScenario || {},
                byRole: ccrStats.byRole || {},
                byModel: ccrStats.byModel || {},
                firstSeenAt: ccrStats.firstSeenAt,
                lastActiveAt: ccrStats.lastActiveAt,
              }
            : null,
        };
      });

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

    const unmatchedSessions = allSessions.filter((s) => !matchedIds.has(s.sessionId));

    res.json({ projects, overall, unmatchedSessions });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
