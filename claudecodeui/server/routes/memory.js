import express from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  TMP_PROJECT_ID,
  MemoryBundleValidationError,
} from '../../../edgeclaw-memory-core/lib/index.js';
import { getMemoryServiceForRequest } from '../services/memoryService.js';

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

function latestUpdatedAt(meta, entries) {
  return [meta.updatedAt, ...entries.map((entry) => entry.updatedAt)]
    .filter(Boolean)
    .sort((left, right) => right.localeCompare(left))[0] || '';
}

function buildProjectGroups(repository, { query = '', limit = 50, offset = 0 } = {}) {
  const store = repository.getFileMemoryStore();
  const normalizedQuery = normalizeSearchText(query);
  const groups = store.listProjectMetas().map((meta) => {
    const entries = repository.listMemoryEntries({
      scope: 'project',
      projectId: meta.projectId,
      limit: 500,
      includeDeprecated: true,
    });
    const activeEntries = entries.filter((entry) => !entry.deprecated);
    const deprecatedEntries = entries.filter((entry) => entry.deprecated);
    const projectEntries = activeEntries.filter((entry) => entry.type === 'project');
    const feedbackEntries = activeEntries.filter((entry) => entry.type === 'feedback');
    const deprecatedProjectEntries = deprecatedEntries.filter((entry) => entry.type === 'project');
    const deprecatedFeedbackEntries = deprecatedEntries.filter((entry) => entry.type === 'feedback');

    return {
      projectId: meta.projectId,
      projectName: meta.projectName,
      description: meta.description,
      aliases: [...meta.aliases],
      status: meta.status,
      updatedAt: latestUpdatedAt(meta, activeEntries),
      projectEntries,
      feedbackEntries,
      deprecatedProjectEntries,
      deprecatedFeedbackEntries,
      projectCount: projectEntries.length,
      feedbackCount: feedbackEntries.length,
    };
  });

  const visibleGroups = groups.filter(
    (group) => group.projectCount + group.feedbackCount > 0,
  );
  const filtered = !normalizedQuery
    ? visibleGroups
    : visibleGroups.filter((group) =>
        normalizeSearchText(
          [
            group.projectName,
            group.description,
            ...group.aliases,
            ...group.projectEntries.flatMap((entry) => [
              entry.name,
              entry.description,
              entry.relativePath,
            ]),
            ...group.feedbackEntries.flatMap((entry) => [
              entry.name,
              entry.description,
              entry.relativePath,
            ]),
          ].join(' '),
        ).includes(normalizedQuery),
      );

  return filtered
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    .slice(offset, offset + limit);
}

function buildTmpSnapshot(repository, { query = '', limit = 100, offset = 0 } = {}) {
  const store = repository.getFileMemoryStore();
  const manifestEntries = repository.listMemoryEntries({
    scope: 'project',
    projectId: TMP_PROJECT_ID,
    includeTmp: true,
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
  const manifestPath = path.join(store.getRootDir(), 'projects', TMP_PROJECT_ID, 'MEMORY.md');

  return {
    manifestPath: `projects/${TMP_PROJECT_ID}/MEMORY.md`,
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

function getQuery(req) {
  return typeof req.query.q === 'string' ? req.query.q.trim() : '';
}

async function withMemoryService(req, res, fn) {
  try {
    const { projectPath, service } = await getMemoryServiceForRequest(req);
    return await fn({ projectPath, service, repository: service.repository });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return res.status(400).json({ error: message });
  }
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
  withMemoryService(req, res, async ({ service }) => {
    res.json(await service.flush({ reason: 'manual' }));
  }),
);

router.post('/dream/run', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(await service.dream('manual'));
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
    const projectId = typeof req.query.projectId === 'string' ? req.query.projectId.trim() : '';
    const query = typeof req.query.query === 'string' ? req.query.query.trim() : '';
    const limit = parseLimit(req.query.limit, 10);
    const offset = parseOffset(req.query.offset, 0);
    const items = service.list({
      ...(kind !== 'all' ? { kinds: [kind] } : {}),
      ...(query ? { query } : {}),
      ...(projectId ? { projectId } : {}),
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

router.get('/projects', async (req, res) =>
  withMemoryService(req, res, async ({ repository }) => {
    res.json(
      buildProjectGroups(repository, {
        query: getQuery(req),
        limit: parseLimit(req.query.limit, 100),
        offset: parseOffset(req.query.offset, 0),
      }),
    );
  }),
);

router.get('/tmp', async (req, res) =>
  withMemoryService(req, res, async ({ repository }) => {
    res.json(
      buildTmpSnapshot(repository, {
        query: getQuery(req),
        limit: parseLimit(req.query.limit, 200),
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

router.get('/export', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    const bundle = service.exportBundle();
    const safe = String(bundle.exportedAt || '')
      .replace(/[^\dTZ-]/g, '-')
      .replace(/-+/g, '-');
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="clawxmemory-memory-${safe || 'export'}.json"`,
    );
    res.send(JSON.stringify(bundle, null, 2));
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

router.post('/clear', async (req, res) =>
  withMemoryService(req, res, async ({ service }) => {
    res.json(service.clear());
  }),
);

export default router;
