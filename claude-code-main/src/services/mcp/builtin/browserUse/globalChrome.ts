import { join } from 'path'
import { homedir } from 'os'
import { createConnection } from 'net'
import type { ChildProcess } from 'child_process'

const CDP_PORT = 9222
const CDP_HOST = '127.0.0.1'

let chromeProcess: ChildProcess | null = null

function getUserDataDir(): string {
  const configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')
  return join(configDir, 'browser-use-profile')
}

function findChromePath(): string | undefined {
  const fs = require('fs') as typeof import('fs')
  const platform = process.platform
  const candidates =
    platform === 'darwin'
      ? [
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
          '/Applications/Chromium.app/Contents/MacOS/Chromium',
          '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        ]
      : ['/usr/bin/google-chrome', '/usr/bin/chromium-browser', '/usr/bin/chromium']

  for (const c of candidates) {
    if (fs.existsSync(c)) return c
  }
  return undefined
}

async function isCDPPortOpen(): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: CDP_HOST, port: CDP_PORT })
    socket.setTimeout(1500)
    socket.on('connect', () => {
      socket.destroy()
      resolve(true)
    })
    socket.on('error', () => resolve(false))
    socket.on('timeout', () => {
      socket.destroy()
      resolve(false)
    })
  })
}

/**
 * HTTP-level health check: GET /json/version must return 200 within 5s.
 * TCP port being open is necessary but not sufficient — Chrome can have the
 * port open but refuse new WebSocket connections when saturated.
 */
export async function isCDPHealthy(): Promise<boolean> {
  try {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 5000)
    const res = await fetch(`http://${CDP_HOST}:${CDP_PORT}/json/version`, {
      signal: controller.signal,
    })
    clearTimeout(timer)
    return res.ok
  } catch {
    return false
  }
}

function cleanSingletonLocks(dir: string) {
  const fs = require('fs') as typeof import('fs')
  for (const name of ['SingletonLock', 'SingletonCookie', 'SingletonSocket']) {
    const p = join(dir, name)
    try {
      if (fs.existsSync(p)) fs.unlinkSync(p)
    } catch { /* ignore */ }
  }
}

function launchChrome(executablePath: string, userDataDir: string): ChildProcess {
  const { spawn } = require('child_process') as typeof import('child_process')

  cleanSingletonLocks(userDataDir)

  const proc = spawn(executablePath, [
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=ProfilePicker',
  ], {
    stdio: 'ignore',
    detached: true,
  })
  proc.unref()
  proc.on('exit', () => {
    if (chromeProcess === proc) chromeProcess = null
  })
  return proc
}

async function waitForCDP(maxMs = 10_000): Promise<boolean> {
  const deadline = Date.now() + maxMs
  while (Date.now() < deadline) {
    if (await isCDPHealthy()) return true
    await new Promise((r) => setTimeout(r, 250))
  }
  return false
}

const CHROME_STOP_TIMEOUT_MS = 2500
const CHROME_STOP_POLL_MS = 100

async function stopLaunchedChrome(): Promise<void> {
  const proc = chromeProcess
  if (!proc) return
  chromeProcess = null
  try { proc.kill('SIGTERM') } catch { /* ignore */ }

  const deadline = Date.now() + CHROME_STOP_TIMEOUT_MS
  while (Date.now() < deadline) {
    try {
      if (proc.exitCode !== null || proc.signalCode) return
      if (proc.pid) process.kill(proc.pid, 0)
    } catch {
      return
    }
    await new Promise((r) => setTimeout(r, CHROME_STOP_POLL_MS))
  }

  try { proc.kill('SIGKILL') } catch { /* ignore */ }
}

/**
 * Ensures a global Chrome instance is running with remote debugging enabled.
 * Returns the CDP HTTP URL if successful, or null on failure.
 *
 * If another process owns the CDP port but is unhealthy, leave it untouched
 * and let browser-use fall back to Playwright-managed Chrome.
 */
export async function ensureGlobalChrome(): Promise<string | null> {
  if (await isCDPHealthy()) {
    return `http://${CDP_HOST}:${CDP_PORT}`
  }

  if (await isCDPPortOpen()) {
    console.warn(`[browser-use] Chrome CDP port ${CDP_PORT} is open but not healthy; leaving existing browser untouched`)
    return null
  }

  const executablePath = findChromePath()
  if (!executablePath) return null

  const userDataDir = getUserDataDir()
  const fs = await import('fs')
  fs.mkdirSync(userDataDir, { recursive: true })

  chromeProcess = launchChrome(executablePath, userDataDir)

  if (await waitForCDP()) {
    return `http://${CDP_HOST}:${CDP_PORT}`
  }

  return null
}

/**
 * Force-restart Chrome. Use when connectOverCDP fails despite port being open.
 */
export async function restartGlobalChrome(): Promise<string | null> {
  await stopLaunchedChrome()

  if (await isCDPPortOpen()) {
    console.warn(`[browser-use] Chrome CDP port ${CDP_PORT} is already in use; leaving existing browser untouched`)
    return null
  }

  const executablePath = findChromePath()
  if (!executablePath) return null

  const userDataDir = getUserDataDir()
  const fs = await import('fs')
  fs.mkdirSync(userDataDir, { recursive: true })

  chromeProcess = launchChrome(executablePath, userDataDir)

  if (await waitForCDP()) {
    return `http://${CDP_HOST}:${CDP_PORT}`
  }
  return null
}

export function getGlobalCDPUrl(): string {
  return `http://${CDP_HOST}:${CDP_PORT}`
}

export function shutdownGlobalChrome(): void {
  void stopLaunchedChrome()
}
