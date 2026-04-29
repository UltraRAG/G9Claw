import { join } from 'path'
import { homedir } from 'os'
import type { Browser, BrowserContext, Page } from 'playwright-core'
import { ensureGlobalChrome, restartGlobalChrome, isCDPHealthy } from './globalChrome.js'

const CDP_CONNECT_TIMEOUT = 60_000
const MAX_CDP_RETRIES = 2

let browserInstance: Browser | null = null
let contextInstance: BrowserContext | null = null
let isPersistent = false

export interface BrowserSession {
  browser: Browser | null
  context: BrowserContext
}

function getUserDataDir(): string {
  const configDir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')
  return join(configDir, 'browser-use-profile')
}

function resetSingletons() {
  browserInstance = null
  contextInstance = null
  isPersistent = false
}

function isContextAlive(): boolean {
  if (!contextInstance) return false
  try {
    contextInstance.pages()
    return true
  } catch {
    return false
  }
}

async function connectCDP(chromium: typeof import('playwright-core').chromium, cdpUrl: string): Promise<void> {
  browserInstance = await chromium.connectOverCDP(cdpUrl, { timeout: CDP_CONNECT_TIMEOUT })
  const contexts = browserInstance.contexts()
  contextInstance = contexts[0] ?? await browserInstance.newContext()
  isPersistent = false
  browserInstance.on('disconnected', () => resetSingletons())
}

export async function getOrCreateSession(): Promise<BrowserSession> {
  if (contextInstance && (isPersistent || browserInstance?.isConnected())) {
    if (!isContextAlive()) {
      resetSingletons()
    } else {
      return { browser: browserInstance, context: contextInstance }
    }
  }

  const { chromium } = await import('playwright-core')
  const cdpUrl = process.env.CDP_URL

  const resolvedCdpUrl = cdpUrl ?? await ensureGlobalChrome()

  if (resolvedCdpUrl) {
    let lastErr: unknown
    for (let attempt = 0; attempt <= MAX_CDP_RETRIES; attempt++) {
      // Health check before expensive connectOverCDP
      if (attempt > 0 || !(await isCDPHealthy())) {
        const freshUrl = await restartGlobalChrome()
        if (!freshUrl) break
      }
      try {
        await connectCDP(chromium, resolvedCdpUrl)
        return { browser: browserInstance, context: contextInstance }
      } catch (err) {
        lastErr = err
        resetSingletons()
      }
    }
    // All CDP retries exhausted — fall through to persistent context fallback
    console.warn(`[browser-use] CDP connect failed after ${MAX_CDP_RETRIES + 1} attempts, falling back to local launch`, lastErr)
  }

  // Fallback: launch persistent context directly
  isPersistent = true
  const executablePath = findChromePath()
  const userDataDir = getUserDataDir()

  const { mkdirSync, unlinkSync, existsSync } = await import('fs')
  mkdirSync(userDataDir, { recursive: true })

  for (const lockFile of ['SingletonLock', 'SingletonCookie', 'SingletonSocket']) {
    const lockPath = join(userDataDir, lockFile)
    if (existsSync(lockPath)) {
      try { unlinkSync(lockPath) } catch { /* ignore */ }
    }
  }

  contextInstance = await chromium.launchPersistentContext(userDataDir, {
    headless: false,
    executablePath,
    args: [
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=ProfilePicker',
    ],
  })
  browserInstance = contextInstance.browser()
  contextInstance.on('close', () => resetSingletons())

  return { browser: browserInstance, context: contextInstance }
}

export async function getActivePage(): Promise<Page> {
  try {
    const { context } = await getOrCreateSession()
    const pages = context.pages()
    return pages[pages.length - 1] ?? await context.newPage()
  } catch {
    resetSingletons()
    const { context } = await getOrCreateSession()
    return context.pages()[0] ?? await context.newPage()
  }
}

export async function getPageByTargetId(targetId: string): Promise<Page | null> {
  const { context } = await getOrCreateSession()
  for (const page of context.pages()) {
    const cdpSession = await context.newCDPSession(page)
    try {
      const info = await cdpSession.send('Target.getTargetInfo')
      if (info.targetInfo.targetId === targetId) {
        return page
      }
    } catch {
      // skip
    } finally {
      await cdpSession.detach().catch(() => {})
    }
  }
  return null
}

export async function closeSession(): Promise<void> {
  if (isPersistent && contextInstance) {
    await contextInstance.close().catch(() => {})
  } else if (browserInstance) {
    await browserInstance.close().catch(() => {})
  }
  resetSingletons()
}

function findChromePath(): string | undefined {
  const platform = process.platform
  if (platform === 'darwin') {
    const candidates = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    ]
    for (const c of candidates) {
      try {
        const fs = require('fs') as typeof import('fs')
        if (fs.existsSync(c)) return c
      } catch { /* ignore */ }
    }
  } else if (platform === 'linux') {
    const candidates = [
      '/usr/bin/google-chrome',
      '/usr/bin/chromium-browser',
      '/usr/bin/chromium',
    ]
    for (const c of candidates) {
      try {
        const fs = require('fs') as typeof import('fs')
        if (fs.existsSync(c)) return c
      } catch { /* ignore */ }
    }
  }
  return undefined
}
