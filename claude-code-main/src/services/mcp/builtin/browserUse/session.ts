import type { Browser, BrowserContext, Page } from 'playwright-core'

let browserInstance: Browser | null = null
let contextInstance: BrowserContext | null = null

export interface BrowserSession {
  browser: Browser
  context: BrowserContext
}

/**
 * Connects to an existing Chrome/Chromium via CDP, or launches a new one.
 * Prefers CDP_URL env var for remote connections. Falls back to launching
 * a local chromium-based browser.
 */
export async function getOrCreateSession(): Promise<BrowserSession> {
  if (browserInstance?.isConnected()) {
    return { browser: browserInstance, context: contextInstance! }
  }

  const { chromium } = await import('playwright-core')
  const cdpUrl = process.env.CDP_URL

  if (cdpUrl) {
    browserInstance = await chromium.connectOverCDP(cdpUrl)
  } else {
    const executablePath = findChromePath()
    browserInstance = await chromium.launch({
      headless: false,
      executablePath,
      args: ['--no-first-run', '--no-default-browser-check'],
    })
  }

  const contexts = browserInstance.contexts()
  contextInstance = contexts[0] ?? await browserInstance.newContext()

  browserInstance.on('disconnected', () => {
    browserInstance = null
    contextInstance = null
  })

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
  if (browserInstance) {
    await browserInstance.close().catch(() => {})
    browserInstance = null
    contextInstance = null
  }
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
