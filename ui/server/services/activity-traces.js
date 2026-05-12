import { promises as fs } from 'fs';
import path from 'path';

function getTraceRoot(projectRoot) {
  if (!projectRoot || typeof projectRoot !== 'string') {
    return null;
  }
  return path.join(projectRoot, '.clawhub', 'activity-traces');
}

function getTracePath(projectRoot, sessionId) {
  const root = getTraceRoot(projectRoot);
  if (!root || !sessionId) {
    return null;
  }
  const safeSessionId = String(sessionId).replace(/[^a-zA-Z0-9._-]/g, '_');
  return path.join(root, `${safeSessionId}.jsonl`);
}

export async function appendActivitySummary(projectRoot, sessionId, summary) {
  const tracePath = getTracePath(projectRoot, sessionId);
  if (!tracePath || !summary) {
    return;
  }

  await fs.mkdir(path.dirname(tracePath), { recursive: true });
  await fs.appendFile(tracePath, `${JSON.stringify(summary)}\n`, 'utf8');
}

export async function readActivitySummaries(projectRoot, sessionId) {
  const tracePath = getTracePath(projectRoot, sessionId);
  if (!tracePath) {
    return [];
  }

  let raw;
  try {
    raw = await fs.readFile(tracePath, 'utf8');
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      console.warn(`[ActivityTraces] Failed to read ${tracePath}:`, error?.message || error);
    }
    return [];
  }

  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}
