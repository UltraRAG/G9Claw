import { join } from 'path'
import { homedir } from 'os'
import type { Browser, BrowserContext, Page } from 'playwright-core'

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

/**
 * Connects to an existing Chrome/Chromium via CDP, or launches a persistent
 * browser context locally. The persistent context stores cookies and
 * localStorage across sessions in ~/.claude/browser-use-profile/.
 */
export async function getOrCreateSession(): Promise<BrowserSession> {
  if (contextInstance && (isPersistent || browserInstance?.isConnected())) {
    return { browser: browserInstance, context: contextInstance }
  }

  const { chromium } = await import('playwright-core')
  const cdpUrl = process.env.CDP_URL

  if (cdpUrl) {
    isPersistent = false
    browserInstance = await chromium.connectOverCDP(cdpUrl)
    const contexts = browserInstance.contexts()
    contextInstance = contexts[0] ?? await browserInstance.newContext()

    browserInstance.on('disconnected', () => {
      browserInstance = null
      contextInstance = null
    })
  } else {
    isPersistent = true
    const executablePath = findChromePath()
    const userDataDir = getUserDataDir()

    const { mkdirSync, unlinkSync, existsSync } = await import('fs')
    mkdirSync(userDataDir, { recursive: true })

    // Clean up stale lock files left by crashed Chrome instances
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

    contextInstance.on('close', () => {
      browserInstance = null
      contextInstance = null
      isPersistent = false
    })
  }

  return { browser: browserInstance, context: contextInstance }
}

export async function getActivePage(): Promise<Page> {
  const { context } = await getOrCreateSession()
  const pages = context.pages()
  return pages[pages.length - 1] ?? await context.newPage()
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
  browserInstance = null
  contextInstance = null
  isPersistent = false
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
