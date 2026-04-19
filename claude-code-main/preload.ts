import { plugin } from 'bun';

// Stub the bun:bundle module which is only available at build/bundle time.
// feature() returns false for most flags so gated code paths are skipped at
// runtime. Keep the daemon fast-path enabled in source mode so local dev can
// exercise `claude daemon ...` without a bundled build.
plugin({
  name: 'bun-bundle-stub',
  setup(build) {
    build.module('bun:bundle', () => ({
      exports: {
        feature: (name: string) => name === 'DAEMON',
      },
      loader: 'object',
    }));

    // Load .md files as text (normally handled by Bun's bundler text loader)
    build.onLoad({ filter: /\.md$/ }, async (args) => ({
      contents: `export default ${JSON.stringify(await Bun.file(args.path).text())}`,
      loader: 'js',
    }));
  },
});

// Define MACRO globals that are normally inlined at build time.
(globalThis as any).MACRO = {
  VERSION: '1.0.100',
  BUILD_TIME: new Date().toISOString(),
  PACKAGE_URL: '@anthropic-ai/claude-code',
  NATIVE_PACKAGE_URL: '@anthropic-ai/claude-code-native',
  FEEDBACK_CHANNEL: 'claude-code-dev',
  ISSUES_EXPLAINER: '',
  VERSION_CHANGELOG: '',
};
