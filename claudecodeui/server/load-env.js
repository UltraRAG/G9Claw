// Load environment variables from the repository root .env before other imports execute.
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const REPO_ROOT = path.resolve(__dirname, '../..');
const ROOT_ENV_PATH = path.join(REPO_ROOT, '.env');
const REQUIRED_EDGECLAW_ENV_KEYS = [
  'EDGECLAW_API_BASE_URL',
  'EDGECLAW_API_KEY',
  'EDGECLAW_MODEL',
];
const DEFAULT_PROXY_PORT = '18080';
const DEFAULT_CONTEXT_WINDOW = '160000';

function normalizeEnvValue(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function parseEnvFile(content) {
  const parsed = {};

  content.split('\n').forEach(line => {
    const trimmedLine = line.trim();
    if (!trimmedLine || trimmedLine.startsWith('#')) {
      return;
    }

    const [key, ...valueParts] = trimmedLine.split('=');
    const normalizedKey = key?.trim();
    if (!normalizedKey || valueParts.length === 0) {
      return;
    }

    parsed[normalizedKey] = valueParts.join('=').trim();
  });

  return parsed;
}

function loadRootEnvFileIntoProcess() {
  try {
    const envFile = fs.readFileSync(ROOT_ENV_PATH, 'utf8');
    const parsedEnv = parseEnvFile(envFile);

    for (const [key, value] of Object.entries(parsedEnv)) {
      if (!process.env[key]) {
        process.env[key] = value;
      }
    }

    return true;
  } catch {
    return false;
  }
}

function applyDerivedRuntimeEnv() {
  const baseUrl = normalizeEnvValue(process.env.EDGECLAW_API_BASE_URL);
  const apiKey = normalizeEnvValue(process.env.EDGECLAW_API_KEY);
  const model = normalizeEnvValue(process.env.EDGECLAW_MODEL);
  const proxyPort =
    normalizeEnvValue(process.env.EDGECLAW_PROXY_PORT) || DEFAULT_PROXY_PORT;
  const contextWindow =
    normalizeEnvValue(process.env.CONTEXT_WINDOW) ||
    normalizeEnvValue(process.env.VITE_CONTEXT_WINDOW) ||
    DEFAULT_CONTEXT_WINDOW;

  process.env.PROXY_PORT = proxyPort;
  process.env.ANTHROPIC_BASE_URL = `http://127.0.0.1:${proxyPort}`;
  process.env.CONTEXT_WINDOW = contextWindow;
  process.env.VITE_CONTEXT_WINDOW = contextWindow;

  if (baseUrl) {
    process.env.OPENAI_BASE_URL = baseUrl;
  }
  if (apiKey) {
    process.env.OPENAI_API_KEY = apiKey;
    process.env.ANTHROPIC_API_KEY = apiKey;
  }
  if (model) {
    process.env.OPENAI_MODEL = model;
    process.env.ANTHROPIC_MODEL = model;
  }
}

export function getRepoRootDir() {
  return REPO_ROOT;
}

export function getRootEnvPath() {
  return ROOT_ENV_PATH;
}

export function hasRootEnvFile() {
  return fs.existsSync(ROOT_ENV_PATH);
}

export function getMissingEdgeClawEnvKeys() {
  return REQUIRED_EDGECLAW_ENV_KEYS.filter(
    key => !normalizeEnvValue(process.env[key]),
  );
}

export function assertRequiredEdgeClawEnv() {
  const missingKeys = getMissingEdgeClawEnvKeys();
  if (missingKeys.length === 0) {
    return;
  }

  throw new Error(
    `Missing required EdgeClaw configuration: ${missingKeys.join(', ')}. ` +
      `Set them in ${ROOT_ENV_PATH} or export them before starting CloudCLI.`,
  );
}

export function loadRootEdgeClawEnv() {
  const loadedFromFile = loadRootEnvFileIntoProcess();
  applyDerivedRuntimeEnv();

  if (!process.env.DATABASE_PATH) {
    process.env.DATABASE_PATH = path.join(os.homedir(), '.cloudcli', 'auth.db');
  }

  return loadedFromFile;
}

loadRootEdgeClawEnv();
