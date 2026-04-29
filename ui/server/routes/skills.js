import express from 'express';
import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { parseFrontmatter } from '../utils/frontmatter.js';

const execFileAsync = promisify(execFile);
const router = express.Router();

// ---------------------------------------------------------------------------
// Path & slug safety
// ---------------------------------------------------------------------------

const SLUG_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/;

function safeSlug(slug) {
  return typeof slug === 'string' && SLUG_RE.test(slug) && !slug.includes('..');
}

// "general chat" cwds — these come through as projectPath but are not real
// projects. Match the patterns from edgeclaw runtimePaths.generalCwd default
// and the memory-core constant. See routes/commands.js for the same logic.
const GENERAL_CWD_PATHS = [
  path.join(os.homedir(), 'Claude', 'general'),
  path.join(os.homedir(), '.claude-gateway', 'general'),
].map((p) => path.resolve(p));

function isGeneralCwd(projectPath) {
  if (!projectPath) return false;
  return GENERAL_CWD_PATHS.includes(path.resolve(projectPath));
}

function userSkillsRoot() {
  return path.join(os.homedir(), '.claude', 'skills');
}

function projectSkillsRoot(projectPath) {
  return path.join(projectPath, '.claude', 'skills');
}

// Validate that an absolute skillPath belongs to a known skills root and has
// a single safe slug segment. Returns { ok, scope, slug, root } or { ok: false, reason }.
function classifySkillPath(skillPath, projectPath = null) {
  if (typeof skillPath !== 'string' || !skillPath) {
    return { ok: false, reason: 'skillPath is required' };
  }
  const abs = path.resolve(skillPath);
  if (abs.includes('..')) {
    return { ok: false, reason: 'skillPath contains ".."' };
  }

  const candidates = [{ root: userSkillsRoot(), scope: 'user' }];
  if (projectPath && !isGeneralCwd(projectPath)) {
    candidates.push({ root: projectSkillsRoot(projectPath), scope: 'project' });
  }

  for (const { root, scope } of candidates) {
    const rootResolved = path.resolve(root);
    if (abs === rootResolved) {
      return { ok: false, reason: 'skillPath is the skills root, not a skill' };
    }
    const rel = path.relative(rootResolved, abs);
    if (rel.startsWith('..') || path.isAbsolute(rel)) continue;
    const segments = rel.split(path.sep).filter(Boolean);
    if (segments.length === 0) continue;
    const slug = segments[0];
    if (!safeSlug(slug)) {
      return { ok: false, reason: `Invalid slug "${slug}"` };
    }
    return {
      ok: true,
      scope,
      slug,
      root: rootResolved,
      skillDir: path.join(rootResolved, slug),
    };
  }

  return { ok: false, reason: 'skillPath is not inside any known skills root' };
}

// ---------------------------------------------------------------------------
// Skill enumeration
// ---------------------------------------------------------------------------

async function readSkillMeta(skillDir) {
  const skillFile = path.join(skillDir, 'SKILL.md');
  let content;
  try {
    content = await fs.readFile(skillFile, 'utf8');
  } catch {
    return null;
  }
  let frontmatter = {};
  try {
    const parsed = parseFrontmatter(content);
    frontmatter = parsed.data || {};
  } catch {
    /* tolerate parse failures — surface raw skill anyway */
  }
  let mtime = null;
  try {
    const stat = await fs.stat(skillFile);
    mtime = stat.mtimeMs;
  } catch {
    /* ignore */
  }
  return {
    slug: path.basename(skillDir),
    name: frontmatter.name || path.basename(skillDir),
    description: frontmatter.description || '',
    version: frontmatter.version || null,
    skillFile,
    skillDir,
    mtime,
  };
}

async function listSkillsIn(root, scope) {
  let entries;
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const skills = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (!safeSlug(entry.name)) continue;
    const meta = await readSkillMeta(path.join(root, entry.name));
    if (!meta) continue;
    skills.push({ ...meta, scope });
  }
  skills.sort((a, b) => a.slug.localeCompare(b.slug));
  return skills;
}

router.post('/list', async (req, res) => {
  try {
    const { projectPath } = req.body || {};
    const generalCwd = isGeneralCwd(projectPath);
    const effectiveProjectPath = generalCwd ? null : projectPath || null;

    const userSkills = await listSkillsIn(userSkillsRoot(), 'user');
    const projectSkills = effectiveProjectPath
      ? await listSkillsIn(projectSkillsRoot(effectiveProjectPath), 'project')
      : [];

    res.json({
      user: userSkills,
      project: projectSkills,
      projectPath: effectiveProjectPath,
      isGeneralCwd: generalCwd,
    });
  } catch (e) {
    console.error('[skills/list]', e);
    res.status(500).json({ error: 'Failed to list skills', message: e.message });
  }
});

// ---------------------------------------------------------------------------
// Read & write SKILL.md
// ---------------------------------------------------------------------------

router.post('/read', async (req, res) => {
  try {
    const { skillPath, projectPath } = req.body || {};
    const cls = classifySkillPath(skillPath, projectPath);
    if (!cls.ok) return res.status(400).json({ error: cls.reason });

    const skillFile = path.join(cls.skillDir, 'SKILL.md');
    let content;
    try {
      content = await fs.readFile(skillFile, 'utf8');
    } catch (e) {
      if (e.code === 'ENOENT') return res.status(404).json({ error: 'SKILL.md not found' });
      throw e;
    }
    const meta = await readSkillMeta(cls.skillDir);
    res.json({ content, scope: cls.scope, slug: cls.slug, skill: meta });
  } catch (e) {
    console.error('[skills/read]', e);
    res.status(500).json({ error: 'Failed to read skill', message: e.message });
  }
});

router.post('/write', async (req, res) => {
  try {
    const { skillPath, content, projectPath } = req.body || {};
    if (typeof content !== 'string') {
      return res.status(400).json({ error: 'content (string) is required' });
    }
    const cls = classifySkillPath(skillPath, projectPath);
    if (!cls.ok) return res.status(400).json({ error: cls.reason });

    await fs.mkdir(cls.skillDir, { recursive: true });
    const skillFile = path.join(cls.skillDir, 'SKILL.md');
    await fs.writeFile(skillFile, content, 'utf8');
    const meta = await readSkillMeta(cls.skillDir);
    res.json({ ok: true, scope: cls.scope, slug: cls.slug, skill: meta });
  } catch (e) {
    console.error('[skills/write]', e);
    res.status(500).json({ error: 'Failed to write skill', message: e.message });
  }
});

// ---------------------------------------------------------------------------
// Create / delete
// ---------------------------------------------------------------------------

function buildInitialSkillContent({ slug, name, description, body }) {
  const fmName = (name || slug).replace(/\n/g, ' ').trim();
  const fmDesc = (description || '').replace(/\n/g, ' ').trim();
  const lines = ['---', `name: ${fmName}`];
  if (fmDesc) lines.push(`description: ${fmDesc}`);
  lines.push('---', '', `# ${fmName}`, '');
  if (body && body.trim()) {
    lines.push(body.trim(), '');
  } else {
    lines.push('Describe what this skill does, when to invoke it, and any prerequisites.', '');
  }
  return lines.join('\n');
}

router.post('/create', async (req, res) => {
  try {
    const { scope, projectPath, slug, name, description, body, content } = req.body || {};

    if (!safeSlug(slug)) {
      return res.status(400).json({ error: `Invalid slug "${slug}". Allowed: [a-zA-Z0-9][a-zA-Z0-9._-]{0,99}, no "..".` });
    }
    const wantProject = scope === 'project';
    let root;
    if (wantProject) {
      if (!projectPath || isGeneralCwd(projectPath)) {
        return res.status(400).json({ error: 'project scope requires a real project (general chat doesn\'t qualify)' });
      }
      root = projectSkillsRoot(projectPath);
    } else {
      root = userSkillsRoot();
    }
    const skillDir = path.join(root, slug);

    try {
      await fs.access(skillDir);
      return res.status(409).json({ error: `Skill already exists at ${skillDir}` });
    } catch {
      /* expected — does not exist */
    }

    await fs.mkdir(skillDir, { recursive: true });
    const finalContent =
      typeof content === 'string' && content.trim()
        ? content
        : buildInitialSkillContent({ slug, name, description, body });
    const skillFile = path.join(skillDir, 'SKILL.md');
    await fs.writeFile(skillFile, finalContent, 'utf8');

    const meta = await readSkillMeta(skillDir);
    res.json({
      ok: true,
      scope: wantProject ? 'project' : 'user',
      slug,
      skillPath: skillDir,
      skill: meta,
    });
  } catch (e) {
    console.error('[skills/create]', e);
    res.status(500).json({ error: 'Failed to create skill', message: e.message });
  }
});

router.post('/delete', async (req, res) => {
  try {
    const { skillPath, projectPath } = req.body || {};
    const cls = classifySkillPath(skillPath, projectPath);
    if (!cls.ok) return res.status(400).json({ error: cls.reason });

    try {
      await fs.rm(cls.skillDir, { recursive: true, force: true });
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
    }
    res.json({ ok: true, scope: cls.scope, slug: cls.slug });
  } catch (e) {
    console.error('[skills/delete]', e);
    res.status(500).json({ error: 'Failed to delete skill', message: e.message });
  }
});

// ---------------------------------------------------------------------------
// ClawHub: search & install
// ---------------------------------------------------------------------------

router.post('/clawhub/search', async (req, res) => {
  try {
    const { query, registry } = req.body || {};
    if (typeof query !== 'string' || query.trim().length === 0) {
      return res.json({ results: [] });
    }

    const args = ['--no-input'];
    if (registry) args.push('--registry', registry);
    args.push('search', query.trim());

    let stdout = '';
    try {
      const r = await execFileAsync('clawhub', args, { timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
      stdout = r.stdout || '';
    } catch (e) {
      if (e.code === 'ENOENT') {
        return res.status(503).json({ error: 'clawhub CLI not found in PATH. Install with `npm install -g clawhub`.' });
      }
      stdout = e.stdout || '';
      if (!stdout) {
        return res.status(500).json({ error: 'clawhub search failed', message: e.message });
      }
    }

    // clawhub search output looks like:
    //   "- Searching\n"
    //   "<slug>  <Display Name>  (<score>)\n"
    // Strip ANSI, drop chrome, parse the rest.
    // eslint-disable-next-line no-control-regex
    const ANSI = /\x1b\[[0-9;]*m/g;
    const results = [];
    for (const rawLine of stdout.split('\n')) {
      const line = rawLine.replace(ANSI, '').trim();
      if (!line) continue;
      if (line.startsWith('-') || line.toLowerCase().startsWith('searching')) continue;
      // Match `<slug>  <name>  (<score>)`
      const m = line.match(/^(\S+)\s+(.+?)\s+\(([\d.]+)\)\s*$/);
      if (m) {
        results.push({ slug: m[1], name: m[2], score: parseFloat(m[3]) });
      } else {
        // Fallback: no score, just slug
        const parts = line.split(/\s{2,}/);
        if (parts.length >= 1 && safeSlug(parts[0])) {
          results.push({ slug: parts[0], name: parts[1] || parts[0], score: null });
        }
      }
    }
    res.json({ results });
  } catch (e) {
    console.error('[skills/clawhub/search]', e);
    res.status(500).json({ error: 'Search failed', message: e.message });
  }
});

router.post('/clawhub/install', async (req, res) => {
  try {
    const { slug, version, force, scope, projectPath, registry } = req.body || {};

    if (!safeSlug(slug)) {
      return res.status(400).json({ error: `Invalid slug "${slug}".` });
    }

    const generalCwd = isGeneralCwd(projectPath);
    const effectiveProjectPath = generalCwd ? null : projectPath || null;
    const resolvedScope = scope === 'project' || scope === 'user' ? scope : effectiveProjectPath ? 'project' : 'user';

    let workdir;
    let dir;
    if (resolvedScope === 'project') {
      if (!effectiveProjectPath) {
        return res.status(400).json({ error: 'project scope requires a real project context' });
      }
      workdir = effectiveProjectPath;
      dir = path.join('.claude', 'skills');
    } else {
      workdir = path.join(os.homedir(), '.claude');
      dir = 'skills';
    }
    const installPath = path.join(workdir, dir, slug);

    const args = ['--no-input', '--workdir', workdir, '--dir', dir];
    if (registry) args.push('--registry', registry);
    args.push('install', slug);
    if (version) args.push('--version', version);
    if (force) args.push('--force');

    let stdout = '';
    let stderr = '';
    let runError = null;
    try {
      const r = await execFileAsync('clawhub', args, { timeout: 120_000, maxBuffer: 10 * 1024 * 1024 });
      stdout = r.stdout || '';
      stderr = r.stderr || '';
    } catch (e) {
      if (e.code === 'ENOENT') {
        return res.status(503).json({ error: 'clawhub CLI not found in PATH. Install with `npm install -g clawhub`.' });
      }
      runError = e;
      stdout = e.stdout || '';
      stderr = e.stderr || '';
    }

    let installed = false;
    let skill = null;
    try {
      await fs.access(path.join(installPath, 'SKILL.md'));
      installed = true;
      skill = await readSkillMeta(installPath);
      if (skill) skill.scope = resolvedScope;
    } catch {
      /* not installed */
    }

    const needsForce =
      !installed && !force && (stderr || stdout).match(/Use --force to install suspicious/i) !== null;

    res.json({
      ok: installed,
      slug,
      scope: resolvedScope,
      installPath,
      installed,
      skill,
      stdout: stdout.trim(),
      stderr: stderr.trim(),
      exitCode: runError ? (runError.code === undefined ? 1 : runError.code) : 0,
      needsForce,
    });
  } catch (e) {
    console.error('[skills/clawhub/install]', e);
    res.status(500).json({ error: 'Install failed', message: e.message });
  }
});

export default router;
