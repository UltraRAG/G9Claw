import express from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  MemoryBundleValidationError,
} from '../../../edgeclaw-memory-core/lib/index.js';
import {
  clearAllMemoryData,
  exportAllProjectsMemoryBundle,
  getMemoryServiceForRequest,
  importAllProjectsMemoryBundle,
  rollbackLastMemoryDream,
  runManualMemoryDream,
  runManualMemoryFlush,
} from '../services/memoryService.js';

const router = express.Router();
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const MEMORY_DASHBOARD_DIR = path.resolve(
  __dirname,
  '../../../edgeclaw-memory-core/ui-source',
);

function parseLimit(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(1, Math.min(200, parsed));
}

function parseOffset(value, fallback = 0) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(0, parsed);
}

function parseMemoryKind(value) {
  return value === 'user' || value === 'feedback' || value === 'project'
    ? value
    : 'all';
}

function normalizeSearchText(value) {
  return String(value || '').toLowerCase().replace(/\s+/g, ' ').trim();
}

function buildWorkspaceSnapshot(repository, { query = '', limit = 100, offset = 0 } = {}) {
  const store = repository.getFileMemoryStore();
  const projectMeta = store.getProjectMeta() ?? null;
  const manifestEntries = repository.listMemoryEntries({
    scope: 'project',
    includeDeprecated: true,
    limit: 1000,
  });
  const records = repository.getMemoryRecordsByIds(
    manifestEntries.map((entry) => entry.relativePath),
    5000,
  );
  const normalizedQuery = normalizeSearchText(query);
  const filtered = !normalizedQuery
    ? records
    : records.filter((record) =>
        normalizeSearchText(
          [
            record.name,
            record.description,
            record.relativePath,
            record.preview,
            record.sourceSessionKey ?? '',
          ].join(' '),
        ).includes(normalizedQuery),
      );
  const page = filtered
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    .slice(offset, offset + limit);
  const activeFiltered = filtered.filter((record) => !record.deprecated);
  const manifestPath = path.join(store.getRootDir(), 'MEMORY.md');

  return {
    projectMetaPath: projectMeta ? 'project.meta.md' : null,
    projectMeta,
    manifestPath: 'MEMORY.md',
    manifestContent: (() => {
      try {
        return fs.readFileSync(manifestPath, 'utf-8');
      } catch {
        return '';
      }
    })(),
    totalFiles: activeFiltered.length,
    totalProjects: activeFiltered.filter((record) => record.type === 'project').length,
    totalFeedback: activeFiltered.filter((record) => record.type === 'feedback').length,
    projectEntries: page.filter((record) => record.type === 'project' && !record.deprecated),
    feedbackEntries: page.filter((record) => record.type === 'feedback' && !record.deprecated),
    deprecatedProjectEntries: page.filter((record) => record.type === 'project' && record.deprecated),
    deprecatedFeedbackEntries: page.filter((record) => record.type === 'feedback' && record.deprecated),
  };
}

function buildDashboardSnapshot(service, repository, { query = '' } = {}) {
  return {
    overview: service.overview(),
    settings: service.getSettings(),
    workspace: buildWorkspaceSnapshot(repository, {
      query,
      limit: 200,
      offset: 0,
    }),
    userSummary: service.getUserSummary(),
    caseTraces: service.listCaseTraces(12),
    indexTraces: service.listIndexTraces(10),
    dreamTraces: service.listDreamTraces(10),
  };
}

function getQuery(req) {
  return typeof req.query.q === 'string' ? req.query.q.trim() : '';
}

async function withMemoryService(req, res, fn) {
  try {
    const { projectPath, dataDir, service } = await getMemoryServiceForRequest(req);
    return await fn({ projectPath, dataDir, service, repository: service.repository });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return res.status(400).json({ error: message });
  }
}

function buildDownloadFileName(prefix, exportedAt) {
  const safe = String(exportedAt || '')
    .replace(/[^\dTZ-]/g, '-')
    .replace(/-+/g, '-');
  return `${prefix}-${safe || 'export'}.json`;
}

function sendBundleDownload(res, bundle, prefix) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader(
    'Content-Disposition',
    `attachment; filename="${buildDownloadFileName(prefix, bundle.exportedAt)}"`,
  );
  res.send(JSON.stringify(bundle, null, 2));
}

router.get('/overview', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.overview());
  }),
);

router.route('/settings')
  .get(async (req, res) =>
    withMemoryService(req, res, async ({ service }) => {
      res.json(service.getSettings());
    }))
  .post(async (req, res) =>
    withMemoryService(req, res, async ({ service }) => {
      res.json(service.saveSettings(req.body ?? {}));
    }));

router.post('/index/run', async (req, res) =>
  withMemoryService(req, res, async ({ dataDir, service, repository }) => {
    const result = await runManualMemoryFlush(service, dataDir, { reason: 'manual' });
    res.json({
      ...result,
      dashboard: buildDashboardSnapshot(service, repository, {
        query: getQuery(req),
      }),
    });
  }),
);

router.post('/dream/run', async (req, res) =>
  withMemoryService(req, res, async ({ dataDir, service, repository }) => {
    const result = await runManualMemoryDream(service, dataDir);
    res.json({
      ...result,
      dashboard: buildDashboardSnapshot(service, repository, {
        query: getQuery(req),
      }),
    });
  }),
);

router.post('/dream/rollback-last', async (req, res) =>
  withMemoryService(req, res, async ({ dataDir, service, repository }) => {
    const result = await rollbackLastMemoryDream(service, dataDir);
    res.json({
      ...result,
      dashboard: buildDashboardSnapshot(service, repository, {
        query: getQuery(req),
      }),
    });
  }),
);

router.get('/snapshot', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.snapshot(parseLimit(req.query.limit, 24)));
  }),
);

router.get('/memory/list', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const kind = parseMemoryKind(req.query.kind);
    const query = typeof req.query.query === 'string' ? req.query.query.trim() : '';
    const limit = parseLimit(req.query.limit, 10);
    const offset = parseOffset(req.query.offset, 0);
    const items = service.list({
      ...(kind !== 'all' ? { kinds: [kind] } : {}),
      ...(query ? { query } : {}),
      limit,
      offset,
    });
    res.json(items);
  }),
);

router.get('/memory/get', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const ids = String(req.query.ids || '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean);
    if (ids.length === 0) {
      return res.status(400).json({ error: 'ids query parameter is required' });
    }
    res.json(service.get(ids, 5000));
  }),
);

router.post('/memory/actions', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    try {
      res.json(service.act(req.body ?? {}));
    } catch (error) {
      res.status(400).json({
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }),
);

router.get('/memory/user-summary', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.getUserSummary());
  }),
);

router.route('/project-meta')
  .get(async (req, res) =>
    withMemoryService(req, res, async ({ service }) => {
      res.json(service.getProjectMeta());
    }))
  .post(async (req, res) =>
    withMemoryService(req, res, async ({ service }) => {
      try {
        res.json(service.updateProjectMeta(req.body ?? {}));
      } catch (error) {
        res.status(400).json({
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }));

router.get('/workspace', async (req, res) =>
  withMemoryService(req, res, async ({ repository }) => {
    res.json(
      buildWorkspaceSnapshot(repository, {
        query: getQuery(req),
        limit: parseLimit(req.query.limit, 100),
        offset: parseOffset(req.query.offset, 0),
      }),
    );
  }),
);

router.get('/cases', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.listCaseTraces(parseLimit(req.query.limit, 12)));
  }),
);

router.get('/cases/:caseId', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const record = service.getCaseTrace(req.params.caseId);
    if (!record) {
      return res.status(404).json({ error: 'Not found' });
    }
    res.json(record);
  }),
);

router.get('/index-traces', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.listIndexTraces(parseLimit(req.query.limit, 30)));
  }),
);

router.get('/index-traces/:indexTraceId', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const record = service.getIndexTrace(req.params.indexTraceId);
    if (!record) {
      return res.status(404).json({ error: 'Not found' });
    }
    res.json(record);
  }),
);

router.get('/dream-traces', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.listDreamTraces(parseLimit(req.query.limit, 30)));
  }),
);

router.get('/dream-traces/:dreamTraceId', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const record = service.getDreamTrace(req.params.dreamTraceId);
    if (!record) {
      return res.status(404).json({ error: 'Not found' });
    }
    res.json(record);
  }),
);

router.get('/export/current-project', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const bundle = service.exportBundle();
    sendBundleDownload(res, bundle, 'edgeclaw-memory-current-project');
  }),
);

router.get('/export/all-projects', async (_req, res) => {
  try {
    const bundle = await exportAllProjectsMemoryBundle();
    sendBundleDownload(res, bundle, 'edgeclaw-memory-all-projects');
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

router.post('/import/current-project', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    try {
      res.json(service.importBundle(req.body));
    } catch (error) {
      const status = error instanceof MemoryBundleValidationError ? 400 : 500;
      res.status(status).json({
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }),
);

router.post('/import/all-projects', async (req, res) => {
  try {
    res.json(await importAllProjectsMemoryBundle(req.body));
  } catch (error) {
    const status = error instanceof MemoryBundleValidationError ? 400 : 500;
    res.status(status).json({
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

router.get('/export', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const bundle = service.exportBundle();
    sendBundleDownload(res, bundle, 'edgeclaw-memory-current-project');
  }),
);

router.post('/import', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    try {
      res.json(service.importBundle(req.body));
    } catch (error) {
      const status = error instanceof MemoryBundleValidationError ? 400 : 500;
      res.status(status).json({
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }),
);

router.post('/clear', async (req, res) => {
  const scope = req.body?.scope === 'all_memory' ? 'all_memory' : 'current_project';
  if (scope === 'all_memory') {
    try {
      res.json(await clearAllMemoryData());
    } catch (error) {
      res.status(500).json({
        error: error instanceof Error ? error.message : String(error),
      });
    }
    return;
  }

  return withMemoryService(req, res, async ({ service, repository }) => {
    const result = service.clear(scope);
    res.json({
      ...result,
      dashboard: buildDashboardSnapshot(service, repository, {
        query: getQuery(req),
      }),
    });
  });
});

export default router;
