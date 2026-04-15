import path from 'path';
import { EdgeClawMemoryService } from '../../../edgeclaw-memory-core/lib/index.js';
import { extractProjectDirectory } from '../projects.js';

const servicesByProjectPath = new Map();

function normalizePath(projectPath) {
  return typeof projectPath === 'string' && projectPath.trim()
    ? path.resolve(projectPath.trim())
    : '';
}

export async function resolveProjectPathFromRequest(req) {
  const queryProjectPath = normalizePath(req.query?.projectPath);
  if (queryProjectPath) {
    return queryProjectPath;
  }

  const bodyProjectPath = normalizePath(req.body?.projectPath);
  if (bodyProjectPath) {
    return bodyProjectPath;
  }

  const projectName = typeof req.query?.projectName === 'string'
    ? req.query.projectName.trim()
    : typeof req.params?.projectName === 'string'
      ? req.params.projectName.trim()
      : '';

  if (!projectName) {
    throw new Error('projectPath or projectName is required');
  }

  return path.resolve(await extractProjectDirectory(projectName));
}

export async function getMemoryServiceForRequest(req) {
  const projectPath = await resolveProjectPathFromRequest(req);
  let service = servicesByProjectPath.get(projectPath);
  if (!service) {
    service = new EdgeClawMemoryService({
      workspaceDir: projectPath,
      source: 'claudecodeui',
    });
    servicesByProjectPath.set(projectPath, service);
  }
  return {
    projectPath,
    service,
  };
}

export function closeMemoryServices() {
  for (const service of servicesByProjectPath.values()) {
    try {
      service.close();
    } catch {
      // ignore close failures during shutdown
    }
  }
  servicesByProjectPath.clear();
}
