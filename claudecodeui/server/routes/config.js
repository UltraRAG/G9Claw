import express from 'express';
import fsPromises from 'fs/promises';
import os from 'os';
import path from 'path';
import { spawn } from 'child_process';
import {
  applyConfigToProcessEnv,
  buildDefaultEdgeClawConfig,
  buildCcrConfig,
  buildGatewayConfig,
  configToYaml,
  expandTilde,
  getEdgeClawConfigPath,
  maskSecrets,
  parseConfigYaml,
  preserveMaskedSecrets,
  readEdgeClawConfigFile,
  validateEdgeClawConfig,
  writeEdgeClawConfig,
} from '../services/edgeclawConfig.js';
import { closeMemoryServices } from '../services/memoryService.js';
import { restartCCR, saveCCRConfig, shutdownCCR } from '../embedded-ccr.js';

const router = express.Router();

function serializeConfigResponse(record, reloadResult = null) {
  const validation = validateEdgeClawConfig(record.config);
  const maskedConfig = maskSecrets(record.config);
  return {
    exists: record.exists,
    path: record.configPath,
    raw: configToYaml(maskedConfig),
    config: maskedConfig,
    validation: {
      valid: validation.valid,
      errors: validation.errors,
      warnings: validation.warnings,
    },
    ...(reloadResult ? { reload: reloadResult } : {}),
  };
}

async function writeGatewayYaml(config) {
  const gatewayHome = expandTilde(config.gateway?.home || path.join(os.homedir(), '.edgeclaw', 'gateway'));
  await fsPromises.mkdir(gatewayHome, { recursive: true });
  const yamlPath = path.join(gatewayHome, 'config.yaml');
  const { stringify } = await import('yaml');
  await fsPromises.writeFile(yamlPath, stringify(buildGatewayConfig(config), { lineWidth: 0 }), 'utf8');
  return yamlPath;
}

async function reloadEdgeClawConfig(config) {
  const result = {
    processEnv: { reloaded: false },
    memory: { reloaded: false },
    router: { reloaded: false, skipped: false },
    gateway: { reloaded: false, skipped: false },
    proxy: { reloaded: false, skipped: false },
  };

  applyConfigToProcessEnv(config);
  result.processEnv.reloaded = true;

  closeMemoryServices();
  result.memory.reloaded = true;

  if (config.router?.enabled) {
    saveCCRConfig(buildCcrConfig(config));
    try {
      await restartCCR();
      result.router.reloaded = true;
    } catch (error) {
      result.router.reloaded = false;
      result.router.error = error instanceof Error ? error.message : String(error);
    }
  } else {
    try {
      await shutdownCCR();
      result.router.reloaded = true;
    } catch (error) {
      result.router.reloaded = false;
      result.router.error = error instanceof Error ? error.message : String(error);
    }
    result.router.reason = 'router.enabled is false';
  }

  if (config.gateway?.enabled) {
    try {
      result.gateway.configPath = await writeGatewayYaml(config);
      result.gateway.reloaded = true;
      result.gateway.note = 'gateway YAML regenerated; running gateway processes must reconnect or be restarted by their owner';
    } catch (error) {
      result.gateway.reloaded = false;
      result.gateway.error = error instanceof Error ? error.message : String(error);
    }
  } else {
    result.gateway.skipped = true;
    result.gateway.reason = 'gateway.enabled is false';
  }

  result.proxy = await new Promise((resolve) => {
    const handled = process.emit('edgeclaw:restart-proxy', (error) => {
      if (error) {
        resolve({ reloaded: false, error: error instanceof Error ? error.message : String(error) });
      } else {
        resolve({ reloaded: true });
      }
    });
    if (!handled) {
      resolve({ reloaded: false, skipped: true, reason: 'proxy restart hook is not registered in this process' });
    }
  });

  return result;
}

router.get('/', (_req, res) => {
  try {
    const record = readEdgeClawConfigFile();
    res.json(serializeConfigResponse(record));
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : String(error) });
  }
});

router.post('/validate', (req, res) => {
  try {
    const raw = typeof req.body?.raw === 'string' ? req.body.raw : '';
    const config = raw ? parseConfigYaml(raw) : req.body?.config;
    const validation = validateEdgeClawConfig(config);
    res.status(validation.valid ? 200 : 400).json(validation);
  } catch (error) {
    res.status(400).json({ valid: false, errors: [error instanceof Error ? error.message : String(error)], warnings: [] });
  }
});

router.put('/', async (req, res) => {
  try {
    const existing = readEdgeClawConfigFile().config;
    const incoming = typeof req.body?.raw === 'string'
      ? parseConfigYaml(req.body.raw)
      : req.body?.config;
    if (!incoming || typeof incoming !== 'object') {
      return res.status(400).json({ error: 'config or raw YAML is required' });
    }

    const config = preserveMaskedSecrets(incoming, existing);
    const saved = await writeEdgeClawConfig(config);
    const reloadResult = await reloadEdgeClawConfig(saved.config);
    res.json(serializeConfigResponse({ exists: true, configPath: saved.configPath, raw: saved.raw, config: saved.config }, reloadResult));
  } catch (error) {
    if (error?.validation) {
      return res.status(400).json({ error: error.message, validation: error.validation });
    }
    res.status(500).json({ error: error instanceof Error ? error.message : String(error) });
  }
});

router.post('/reload', async (_req, res) => {
  try {
    const record = readEdgeClawConfigFile();
    const validation = validateEdgeClawConfig(record.config);
    if (!validation.valid) {
      return res.status(400).json({ error: 'Invalid config', validation });
    }
    const reloadResult = await reloadEdgeClawConfig(record.config);
    res.json(serializeConfigResponse(record, reloadResult));
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : String(error) });
  }
});

router.post('/open', async (_req, res) => {
  const configPath = getEdgeClawConfigPath();
  try {
    await fsPromises.mkdir(path.dirname(configPath), { recursive: true });
    try {
      await fsPromises.access(configPath);
    } catch {
      await fsPromises.writeFile(configPath, configToYaml(buildDefaultEdgeClawConfig()), 'utf8');
    }

    const command = process.platform === 'darwin'
      ? 'open'
      : process.platform === 'win32'
        ? 'cmd'
        : 'xdg-open';
    const args = process.platform === 'darwin'
      ? ['-R', configPath]
      : process.platform === 'win32'
        ? ['/c', 'start', '', configPath]
        : [path.dirname(configPath)];
    const child = spawn(command, args, { stdio: 'ignore', detached: true });
    child.unref();
    res.json({ success: true, path: configPath });
  } catch (error) {
    res.json({ success: false, path: configPath, error: error instanceof Error ? error.message : String(error) });
  }
});

export default router;
