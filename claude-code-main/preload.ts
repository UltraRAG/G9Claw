import { plugin } from 'bun';
import { existsSync, readFileSync, readdirSync, statSync } from 'fs';
import { execSync } from 'child_process';
import { resolve, dirname } from 'path';

plugin({
  name: 'bun-bundle-stub',
  setup(build) {
    build.module('bun:bundle', () => ({
      exports: {
        feature: (_name: string) => false,
      },
      loader: 'object',
    }));

    build.onLoad({ filter: /\.md$/ }, async (args) => ({
      contents: `export default ${JSON.stringify(await Bun.file(args.path).text())}`,
      loader: 'js',
    }));
  },
});

(globalThis as any).MACRO = {
  VERSION: '1.0.100',
  BUILD_TIME: new Date().toISOString(),
  PACKAGE_URL: '@anthropic-ai/claude-code',
  NATIVE_PACKAGE_URL: '@anthropic-ai/claude-code-native',
  FEEDBACK_CHANNEL: 'claude-code-dev',
  ISSUES_EXPLAINER: '',
  VERSION_CHANGELOG: '',
};

// ── Embedded CCR (Claude Code Router) — Zero-port mode ──────────────────────
// Intercepts fetch() in-process. No HTTP server, no port, no network overhead.
// Skip with CCR_DISABLED=1 or when ANTHROPIC_BASE_URL is already set externally.
const CCR_SENTINEL = 'http://ccr.local';

if (
  process.env.CCR_DISABLED !== '1' &&
  process.env.CCR_DISABLED !== 'true' &&
  !process.env.ANTHROPIC_BASE_URL
) {
  const DIR = dirname(new URL(import.meta.url).pathname);
  const configPath = resolve(DIR, 'ccr-config.json');

  if (existsSync(configPath)) {
    const routerDir = resolve(DIR, 'src/router');
    const cjsPath = resolve(routerDir, 'server.cjs');
    const buildScript = resolve(routerDir, 'build.mjs');

    function newestMtime(dir: string, ext = '.ts'): number {
      let newest = 0;
      try {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
          const full = `${dir}/${entry.name}`;
          if (entry.isDirectory()) newest = Math.max(newest, newestMtime(full, ext));
          else if (entry.name.endsWith(ext)) newest = Math.max(newest, statSync(full).mtimeMs);
        }
      } catch {}
      return newest;
    }

    if (existsSync(resolve(routerDir, 'src/server.ts')) && existsSync(buildScript)) {
      const cjsMtime = existsSync(cjsPath) ? statSync(cjsPath).mtimeMs : 0;
      const srcMtime = Math.max(
        newestMtime(resolve(routerDir, 'src')),
        newestMtime(resolve(routerDir, 'shared')),
      );
      if (srcMtime > cjsMtime || cjsMtime === 0) {
        console.log('[CCR] Source newer than bundle — rebuilding...');
        execSync('node build.mjs', { cwd: routerDir, stdio: 'inherit' });
        console.log('[CCR] Rebuild complete');
      }
    }

    if (existsSync(cjsPath)) {
      try {
        const config = JSON.parse(readFileSync(configPath, 'utf-8'));
        const CCR = require(cjsPath);
        const Server = CCR.default;

        const server = new Server({
          initialConfig: {
            providers: config.Providers,
            Router: config.Router,
            tokenStats: config.tokenStats,
            API_TIMEOUT_MS: config.API_TIMEOUT_MS,
            HOST: config.HOST || '127.0.0.1',
            PORT: 0,
            LOG: config.LOG ?? false,
          },
          logger: config.LOG !== false && process.env.CCR_LOG === '1',
        });

        await server.init();

        CCR.installFetchInterceptor(CCR_SENTINEL, {
          configService: server.configService,
          providerService: server.providerService,
          transformerService: server.transformerService,
          tokenizerService: server.tokenizerService,
          logger: process.env.CCR_LOG === '1' ? undefined : {
            info: () => {},
            warn: (...a: any[]) => console.warn('[CCR]', ...a),
            error: (...a: any[]) => console.error('[CCR]', ...a),
            debug: () => {},
          },
        });

        process.env.ANTHROPIC_BASE_URL = CCR_SENTINEL;
        process.env.ANTHROPIC_API_KEY ??= 'dummy-key-for-ccr';
        console.log('[CCR] Router ready (zero-port mode, fetch interceptor)');

        (globalThis as any).__ccrServer = server;
        (globalThis as any).__ccrModule = CCR;
      } catch (err: any) {
        console.warn(`[CCR] Failed to start embedded router: ${err.message}`);
        console.warn('[CCR] Continuing without router — requests go directly to Anthropic API');
      }
    }
  }
}
