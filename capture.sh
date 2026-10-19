#!/usr/bin/env bash
# Capture desktop and mobile screenshots of an already-running preview.
# Exit 75 for temporary navigation/browser infrastructure failures; exit 1 for
# script or rendering defects. Capture output is written outside the source.
set -euo pipefail

: "${CAPTURE_URL:?Set CAPTURE_URL to the running preview URL.}"
: "${CAPTURE_DIR:?Set CAPTURE_DIR to the evidence output directory.}"

timed() { /usr/bin/time -p "$@"; }

timed mkdir -p "$CAPTURE_DIR"

timed node --input-type=module - <<'NODE'
import { mkdirSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'

const url = process.env.CAPTURE_URL
const output = process.env.CAPTURE_DIR
if (!url || !output) {
  console.error('[capture] CAPTURE_URL and CAPTURE_DIR are required')
  process.exit(1)
}

const runtime = join(process.env.HOME || '', '.local/share/omgithub-playwright')
const require = createRequire(join(runtime, 'package.json'))
const { chromium } = require('playwright')
try {
  require(join(runtime, 'wip-screenshots.cjs')).instrument({ chromium })
} catch (error) {
  console.error('[capture] WIP screenshot instrumentation unavailable:', error.message)
}

let config
try {
  const name = process.platform === 'darwin' ? 'metal.json' : 'linux.json'
  config = JSON.parse(readFileSync(join(runtime, name), 'utf8'))
} catch (error) {
  console.error('[capture] Unable to read Playwright launch configuration:', error.message)
  process.exit(1)
}

if (process.platform === 'linux' && !process.env.DISPLAY) {
  try {
    process.env.DISPLAY = ':' + readFileSync(join(runtime, 'display'), 'utf8').trim()
  } catch {
    console.error('[capture] Unable to read Xvfb display; continuing with defaults')
  }
}

const now = () => performance.now()
const timed = async (label, action) => {
  const started = now()
  try {
    return await action()
  } finally {
    console.error(`[capture] ${label}: ${(now() - started).toFixed(0)}ms`)
  }
}
const transient = error => Object.assign(error, { exitCode: 75 })

try {
  mkdirSync(output, { recursive: true })
} catch (error) {
  console.error('[capture] Unable to create CAPTURE_DIR:', error.message)
  process.exit(1)
}

let browser
let exitCode = 0
try {
  browser = await timed('launch browser', () =>
    chromium.launch({ ...config.browser.launchOptions, timeout: 30000 })
  ).catch(error => { throw transient(error) })

  for (const [name, width, height] of [['desktop', 1440, 900], ['mobile', 390, 844]]) {
    const page = await timed(`open ${name} page`, () =>
      browser.newPage({ viewport: { width, height } })
    ).catch(error => { throw transient(error) })

    page.setDefaultTimeout(30000)
    page.setDefaultNavigationTimeout(45000)
    page.on('pageerror', error => console.error(`[capture] page error (${name}): ${error.message}`))

    const response = await timed(`navigate ${name}`, () =>
      page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
    ).catch(error => { throw transient(error) })

    if (!response) throw transient(new Error(`No navigation response from ${url}`))
    if (!response.ok()) {
      const status = response.status()
      const error = new Error(`HTTP ${status} loading ${url}`)
      error.exitCode = [408, 429, 500, 502, 503, 504].includes(status) ? 75 : 1
      throw error
    }

    await timed(`wait for rendered content (${name})`, async () => {
      await page.waitForLoadState('load', { timeout: 45000 })
      await page.waitForFunction(() => {
        const body = document.body
        if (!body) return false
        const text = (body.innerText || '').trim()
        return text.length > 0 || Boolean(body.querySelector('img, canvas, svg, video'))
      }, null, { timeout: 30000 })
      await page.waitForFunction(
        () => !document.fonts || document.fonts.status === 'loaded',
        null,
        { timeout: 15000 }
      )
      await page.evaluate(() => new Promise(resolve =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))
      ))
    }).catch(error => {
      const code = browser.isConnected() ? 1 : 75
      throw Object.assign(error, { exitCode: code })
    })

    await timed(`settle ${name}`, () => page.waitForTimeout(1200))

    const path = join(output, `final-${name}.png`)
    await timed(`screenshot ${name}`, () =>
      page.screenshot({ path, timeout: 30000, animations: 'disabled' })
    ).catch(error => {
      if (error.name === 'TimeoutError' || !browser.isConnected()) throw transient(error)
      throw error
    })
    console.error(`[capture] wrote ${path}`)

    await timed(`close ${name} page`, () => page.close()).catch(error => {
      if (!browser.isConnected()) throw transient(error)
      throw error
    })
  }
} catch (error) {
  console.error('[capture]', error.message || error)
  exitCode = error.exitCode || 1
} finally {
  if (browser) {
    await timed('close browser', () => browser.close()).catch(error => {
      console.error('[capture] close browser:', error.message)
      if (exitCode === 0) exitCode = 75
    })
  }
}

process.exit(exitCode)
NODE

timed test -s "$CAPTURE_DIR/final-desktop.png"
timed test -s "$CAPTURE_DIR/final-mobile.png"
