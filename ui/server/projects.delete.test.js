import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const originalHome = process.env.HOME;
const originalUserProfile = process.env.USERPROFILE;
const tempDirs = [];
let projectsModule = null;

async function createTempHome() {
  const homeDir = await fs.mkdtemp(path.join(os.tmpdir(), 'projects-delete-home-'));
  tempDirs.push(homeDir);
  process.env.HOME = homeDir;
  process.env.USERPROFILE = homeDir;
  return homeDir;
}

function encodeClaudeProjectName(projectRoot) {
  return projectRoot.replace(/[\\/:\s~]/g, '-');
}

function encodeManualProjectName(projectRoot) {
  return projectRoot.replace(/[\\/:\s~_]/g, '-');
}

async function loadProjectsModule() {
  if (!projectsModule) {
    projectsModule = await import('./projects.js');
  }
  projectsModule.clearProjectDirectoryCache();
  return projectsModule;
}

afterEach(async () => {
  projectsModule?.clearProjectDirectoryCache();

  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    await fs.rm(dir, { recursive: true, force: true });
  }

  if (originalHome === undefined) {
    delete process.env.HOME;
  } else {
    process.env.HOME = originalHome;
  }

  if (originalUserProfile === undefined) {
    delete process.env.USERPROFILE;
  } else {
    process.env.USERPROFILE = originalUserProfile;
  }
});

test('deleteProject removes manual config aliases for the same project path', async () => {
  const homeDir = await createTempHome();
  const {
    addProjectManually,
    clearProjectDirectoryCache,
    deleteProject,
    getProjects,
    loadProjectConfig,
  } = await loadProjectsModule();

  const projectRoot = path.join(homeDir, 'workspace_root', 'site');
  await fs.mkdir(projectRoot, { recursive: true });

  const manuallyAddedProject = await addProjectManually(projectRoot, 'Site');
  const claudeProjectName = encodeClaudeProjectName(projectRoot);
  const manualProjectName = encodeManualProjectName(projectRoot);

  assert.equal(manuallyAddedProject.name, manualProjectName);
  assert.notEqual(claudeProjectName, manualProjectName);

  const claudeProjectDir = path.join(homeDir, '.claude', 'projects', claudeProjectName);
  await fs.mkdir(claudeProjectDir, { recursive: true });
  await fs.writeFile(
    path.join(claudeProjectDir, 'session.jsonl'),
    `${JSON.stringify({
      sessionId: 'session-1',
      cwd: projectRoot,
      timestamp: new Date().toISOString(),
      type: 'user',
    })}\n`,
    'utf8',
  );

  clearProjectDirectoryCache();
  const beforeDelete = await getProjects();
  const matchingProjects = beforeDelete.filter(
    (project) => path.resolve(project.fullPath || project.path || '') === path.resolve(projectRoot),
  );
  assert.equal(matchingProjects.length, 1);
  assert.equal(matchingProjects[0].name, claudeProjectName);

  await deleteProject(claudeProjectName, true);

  clearProjectDirectoryCache();
  const afterDelete = await getProjects();
  assert.equal(
    afterDelete.some(
      (project) => path.resolve(project.fullPath || project.path || '') === path.resolve(projectRoot),
    ),
    false,
  );

  const config = await loadProjectConfig();
  assert.equal(config[claudeProjectName], undefined);
  assert.equal(config[manualProjectName], undefined);
});
