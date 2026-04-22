/**
 * Embedded CCR (Claude Code Router) — zero-port mode.
 *
 * Loads the pre-built CCR bundle from the sibling claude-code-main tree,
 * initializes services in-process (no HTTP server, no port), and exposes
 * direct access to CCR services for the Express routes.
 *
 * Config resolution order:
 *   1. <claudecodeui>/ccr-config.json  (local override)
 *   2. <claude-code-main>/ccr-config.json  (upstream default)
 *
 * Env vars:
 *   CCR_ENABLED  – set to "0" or "false" to skip (default: enabled)
 */

import { createRequire } from 'module';
import { execSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { resolveClaudeCodeMainRoot } from './claude-code-main-path.js';

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

let ccrInstance = null;
let ccrModule = null;
let ccrServices = null;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

function getLocalConfigPath() {
  return path.resolve(__dirname, '..', 'ccr-config.json');
}

export function loadCCRConfig(ccrRoot) {
  const localPath = getLocalConfigPath();
  if (fs.existsSync(localPath)) {
    return JSON.parse(fs.readFileSync(localPath, 'utf-8'));
  }
  if (ccrRoot) {
    const remotePath = path.join(ccrRoot, 'ccr-config.json');
    if (fs.existsSync(remotePath)) {
      return JSON.parse(fs.readFileSync(remotePath, 'utf-8'));
    }
  }
  return null;
}

export function saveCCRConfig(config) {
  const json = JSON.stringify(config, null, 2) + '\n';
  const localPath = getLocalConfigPath();
  fs.writeFileSync(localPath, json, 'utf-8');

  // Sync to claude-code-main so proxy.ts / gateway pick up the same config
  const ccrRoot = resolveClaudeCodeMainRoot();
  if (ccrRoot) {
    const upstreamPath = path.join(ccrRoot, 'ccr-config.json');
    try {
      fs.writeFileSync(upstreamPath, json, 'utf-8');
      console.log(`[CCR] Config synced → ${upstreamPath}`);
    } catch (err) {
      console.warn(`[CCR] Failed to sync config to ${upstreamPath}: ${err.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Auto-build from source
// ---------------------------------------------------------------------------

function newestMtime(dir, ext = '.ts') {
  let newest = 0;
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        newest = Math.max(newest, newestMtime(full, ext));
      } else if (entry.name.endsWith(ext)) {
        newest = Math.max(newest, fs.statSync(full).mtimeMs);
      }
    }
  } catch { /* directory may not exist */ }
  return newest;
}

function tryAutoBuildFromSource(routerDir) {
  const sourceEntry = path.join(routerDir, 'src', 'server.ts');
  const buildScript = path.join(routerDir, 'build.mjs');
  const outputCjs = path.join(routerDir, 'server.cjs');

  if (!fs.existsSync(sourceEntry) || !fs.existsSync(buildScript)) return false;

  const cjsMtime = fs.existsSync(outputCjs) ? fs.statSync(outputCjs).mtimeMs : 0;
  const srcMtime = Math.max(
    newestMtime(path.join(routerDir, 'src')),
    newestMtime(path.join(routerDir, 'shared')),
  );

  if (cjsMtime >= srcMtime && cjsMtime > 0) return false;

  console.log('[CCR] Source newer than bundle — rebuilding...');
  try {
    execSync('node build.mjs', { cwd: routerDir, stdio: 'pipe', timeout: 30000 });
    console.log('[CCR] Rebuild complete');
    return true;
  } catch (err) {
    console.warn(`[CCR] Auto-build failed: ${err.message}`);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

export async function startEmbeddedCCR(options = {}) {
  const ccrRoot = resolveClaudeCodeMainRoot();
  const config = loadCCRConfig(ccrRoot);
  if (!config) {
    throw new Error('No ccr-config.json found (checked local + claude-code-main)');
  }

  const routerDir = ccrRoot ? path.join(ccrRoot, 'src', 'router') : null;
  if (routerDir) tryAutoBuildFromSource(routerDir);

  const serverCjsPath = routerDir
    ? path.join(routerDir, 'server.cjs')
    : null;
  if (!serverCjsPath || !fs.existsSync(serverCjsPath)) {
    throw new Error(`server.cjs not found${routerDir ? ' at ' + serverCjsPath : ''}`);
  }

  ccrModule = require(serverCjsPath);
  const Server = ccrModule.default;

  ccrInstance = new Server({
    initialConfig: {
      providers: config.Providers,
      Router: config.Router,
      tokenStats: config.tokenStats,
      API_TIMEOUT_MS: config.API_TIMEOUT_MS || 120000,
      HOST: '127.0.0.1',
      PORT: 0,
      LOG: config.LOG ?? true,
    },
    logger: config.LOG !== false,
  });

  // init() only — no listen(), no port
  await ccrInstance.init();

  ccrServices = {
    configService: ccrInstance.configService,
    providerService: ccrInstance.providerService,
    transformerService: ccrInstance.transformerService,
    tokenizerService: ccrInstance.tokenizerService,
    logger: {
      info: () => {},
      warn: (...a) => console.warn('[CCR]', ...a),
      error: (...a) => console.error('[CCR]', ...a),
      debug: () => {},
    },
  };

  // Set ANTHROPIC_BASE_URL so CC subprocesses (spawned by claudecodeui)
  // also go through CCR. They'll use the sentinel URL which the fetch
  // interceptor (installed in their preload.ts) will handle.
  // For subprocesses that don't have the interceptor, this is harmless —
  // the sentinel URL will fail, and CC falls back to direct API.
  process.env.ANTHROPIC_BASE_URL = 'http://ccr.local';

  return { port: null, baseUrl: null, reused: false, zeroPorts: true };
}

export function getCCRBaseUrl() {
  return ccrServices ? 'http://ccr.local' : null;
}

export function getCCRPort() {
  return null;
}

export function getCCRModule() {
  return ccrModule;
}

export function getCCRServices() {
  return ccrServices;
}

export function getCCRInstance() {
  return ccrInstance;
}

export async function restartCCR() {
  await shutdownCCR();
  return startEmbeddedCCR();
}

export async function shutdownCCR() {
  if (ccrModule) {
    try {
      const { getGlobalStatsCollector } = ccrModule;
      const collector = getGlobalStatsCollector?.();
      if (collector) {
        collector.stopAutoFlush();
        await collector.flush();
      }
    } catch { /* best effort */ }
  }

  ccrInstance = null;
  ccrServices = null;
}
