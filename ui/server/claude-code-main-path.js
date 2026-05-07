/**
 * Resolve local Claude Code (leaked / dev tree) for the Agent SDK subprocess.
 * When found, the SDK spawns Bun with preload + cli.tsx instead of the bundled cli.js.
 *
 * Configure:
 *   CLAUDE_CODE_MAIN_DIR=/absolute/path/to/claude-code-main
 *   (alias) CLOUDCLI_CLAUDE_CODE_MAIN
 *
 * Opt out (use bundled Claude Code from npm):
 *   CLOUDCLI_USE_BUNDLED_CLAUDE_CODE=1
 *
 * If unset, also tries ../../claude-code-main relative to this package root
 * (sibling layout: edgeclaw-opc/ui + edgeclaw-opc/claude-code-main).
 */

import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let didLogSpawn = false;
let didLogPlugins = false;

function packageRootDir() {
  return path.resolve(__dirname, '..');
}

function resolveBunExecutable() {
  const candidates = [
    process.env.BUN_BIN,
    process.env.BUN,
    process.env.BUN_INSTALL ? path.join(process.env.BUN_INSTALL, 'bin', 'bun') : null,
    path.join(os.homedir(), '.bun', 'bin', 'bun'),
    '/opt/homebrew/bin/bun',
    '/usr/local/bin/bun',
    'bun',
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (candidate === 'bun') {
      return candidate;
    }
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return 'bun';
}

export function resolveClaudeCodeMainRoot() {
  if (process.env.CLOUDCLI_USE_BUNDLED_CLAUDE_CODE === '1' || process.env.CLOUDCLI_USE_BUNDLED_CLAUDE_CODE === 'true') {
    return null;
  }

  const fromEnv = process.env.CLAUDE_CODE_MAIN_DIR || process.env.CLOUDCLI_CLAUDE_CODE_MAIN;
  if (fromEnv) {
    const root = path.resolve(fromEnv.trim());
    if (fs.existsSync(path.join(root, 'src', 'entrypoints', 'cli.tsx'))) {
      return root;
    }
    return null;
  }

  const sibling = path.resolve(packageRootDir(), '..', 'claude-code-main');
  if (fs.existsSync(path.join(sibling, 'src', 'entrypoints', 'cli.tsx'))) {
    return sibling;
  }

  return null;
}

export function resolveBundledPluginDirs() {
  const repoRoot = path.resolve(packageRootDir(), '..');
  const defaultPluginDirs = [
    path.join(repoRoot, 'packages', 'turnkey-cc-plugin'),
    path.join(repoRoot, 'packages', 'edgeclaw-rag-plugin'),
  ];

  let pluginDirs;
  if (!Object.prototype.hasOwnProperty.call(process.env, 'PLUGIN_DIR')) {
    pluginDirs = defaultPluginDirs;
  } else if (process.env.PLUGIN_DIR && process.env.PLUGIN_DIR.trim()) {
    pluginDirs = [path.resolve(process.env.PLUGIN_DIR.trim())];
  } else {
    pluginDirs = [];
  }

  const validPluginDirs = pluginDirs.filter(pluginDir => fs.existsSync(path.join(pluginDir, '.claude-plugin', 'plugin.json')));

  if (!didLogPlugins) {
    didLogPlugins = true;
    if (validPluginDirs.length > 0) {
      console.log(`[cloudcli] Claude Agent SDK bundled plugins: ${validPluginDirs.join(', ')}`);
    } else if (pluginDirs.length > 0) {
      console.warn(`[cloudcli] No valid bundled plugins found from: ${pluginDirs.join(', ')}`);
    } else {
      console.log('[cloudcli] Bundled plugin loading disabled by PLUGIN_DIR=');
    }
  }

  return validPluginDirs;
}

/**
 * @returns {{ pathToClaudeCodeExecutable: string, executable: 'bun', executableArgs: string[] } | null}
 */
export function getLeakedClaudeSdkSpawnOptions() {
  const root = resolveClaudeCodeMainRoot();
  if (!root) {
    return null;
  }

  const cli = path.join(root, 'src', 'entrypoints', 'cli.tsx');
  const preload = path.join(root, 'preload.ts');

  if (!fs.existsSync(cli)) {
    return null;
  }

  const executableArgs = ['run'];
  if (fs.existsSync(preload)) {
    executableArgs.push('--preload', preload);
  }

  const executable = resolveBunExecutable();

  if (!didLogSpawn) {
    didLogSpawn = true;
    console.log(`[cloudcli] Claude Agent SDK → local tree: ${root} (${executable} ${executableArgs.join(' ')} → cli.tsx)`);
  }

  return {
    pathToClaudeCodeExecutable: cli,
    executable,
    executableArgs,
  };
}
