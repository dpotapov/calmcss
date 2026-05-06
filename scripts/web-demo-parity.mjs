import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { readFile, mkdtemp, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { extname, normalize } from 'node:path'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compile } from 'tailwindcss'
import { spawnFile } from './process.mjs'

const casesPath = process.env.CALMCSS_RENDER_CASES ?? 'test/render_cases.json'
const cases = JSON.parse(await readFile(casesPath, 'utf8'))
const chromePath = findChrome()
const maxDiffs = Number.parseInt(process.env.CALMCSS_RENDER_DIFFS ?? '20', 10)

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const themePath = fileURLToPath(import.meta.resolve('tailwindcss/theme.css'))
const preflightPath = fileURLToPath(import.meta.resolve('tailwindcss/preflight.css'))
const officialThemeCss = await readFile(themePath, 'utf8')
const officialPreflightCss = await readFile(preflightPath, 'utf8')
const server = await startStaticServer()
const browser = await startBrowser(chromePath)

let pass = 0
let fail = 0
const diffs = []

try {
  for (const testCase of cases) {
    const candidates = extractCandidates(testCase.html)
    const tailwind = await compile(`${officialThemeCss}\n${officialPreflightCss}\n@tailwind utilities;`)
    const officialCss = tailwind.build(candidates)
    const demo = await renderDemo(browser, server.url, testCase)
    const official = await renderOfficial(browser, testCase, officialCss, demo.viewportWidths)
    const caseDiffs = compareResults(testCase, official, demo.styles)

    if (caseDiffs.length === 0) {
      pass += 1
    } else {
      fail += 1
      for (const diff of caseDiffs) {
        if (diffs.length < maxDiffs) diffs.push(diff)
      }
    }
  }
} finally {
  await browser.close()
  await server.close()
}

const total = pass + fail
const pct = total === 0 ? 100 : (pass / total) * 100
console.log(`CalmCSS web demo render parity: ${pass}/${total} (${pct.toFixed(2)}%)`)
if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.caseName} @ ${diff.width}px / ${diff.label} / ${diff.property}`)
    console.log(`  selector: ${diff.selector}`)
    console.log(`  tailwind: ${diff.expected}`)
    console.log(`  web demo: ${diff.actual}`)
  }
}

if (fail > 0) {
  process.exitCode = 1
}

async function renderOfficial(browser, testCase, css, viewportWidths) {
  const results = {}
  for (const width of testCase.widths) {
    const renderWidth = viewportWidths?.[width] ?? width
    await browser.send('Emulation.setDeviceMetricsOverride', {
      width: renderWidth,
      height: testCase.height ?? 1000,
      deviceScaleFactor: 1,
      mobile: false,
    })
    await browser.send('Page.navigate', { url: pageUrl(testCase.html, css) })
    await waitForLoad(browser.send)
    results[width] = await collectStyles(browser, testCase.checks)
  }
  return results
}

async function renderDemo(browser, baseUrl, testCase) {
  const results = {}
  const viewportWidths = {}
  for (const width of testCase.widths) {
    await browser.send('Emulation.setDeviceMetricsOverride', {
      width,
      height: testCase.height ?? 1000,
      deviceScaleFactor: 1,
      mobile: false,
    })
    await browser.send('Page.navigate', { url: `${baseUrl}/web/index.html` })
    await waitForLoad(browser.send)
    await waitForDemoReady(browser)
    await browser.send('Runtime.evaluate', {
      expression: `
        (() => {
          const input = document.querySelector("#html");
          input.value = ${JSON.stringify(testCase.html)};
          input.dispatchEvent(new Event("input", { bubbles: true }));
        })()
      `,
    })
    await waitForDemoRender(browser, testCase)
    const viewport = await browser.send('Runtime.evaluate', {
      expression: 'document.querySelector("#preview").contentWindow.innerWidth',
      returnByValue: true,
    })
    viewportWidths[width] = viewport.result.result.value
    results[width] = await collectStyles(browser, testCase.checks, 'document.querySelector("#preview").contentDocument')
  }
  return { styles: results, viewportWidths }
}

async function collectStyles(browser, checks, documentExpression = 'document') {
  const evaluation = await browser.send('Runtime.evaluate', {
    expression: `JSON.stringify((${collectComputedStyles.toString()})(${documentExpression}, ${JSON.stringify(checks)}))`,
    returnByValue: true,
  })
  if (evaluation.exceptionDetails) {
    throw new Error(evaluation.exceptionDetails.text)
  }
  return JSON.parse(evaluation.result.result.value)
}

function collectComputedStyles(doc, checks) {
  const out = {}
  for (const check of checks) {
    const element = doc.querySelector(check.selector)
    if (!element) {
      out[check.label] = { __missing: check.selector }
      continue
    }
    const style = doc.defaultView.getComputedStyle(element)
    const values = {}
    for (const property of check.properties) {
      values[property] = style.getPropertyValue(property)
    }
    out[check.label] = values
  }
  return out
}

function compareResults(testCase, official, demo) {
  const diffs = []
  for (const width of testCase.widths) {
    for (const check of testCase.checks) {
      const expectedValues = official[width][check.label]
      const actualValues = demo[width][check.label]
      if (expectedValues?.__missing || actualValues?.__missing) {
        if (expectedValues?.__missing !== actualValues?.__missing) {
          diffs.push({
            caseName: testCase.name,
            width,
            label: check.label,
            selector: check.selector,
            property: '__missing',
            expected: expectedValues?.__missing ?? '<present>',
            actual: actualValues?.__missing ?? '<present>',
          })
        }
        continue
      }
      for (const property of check.properties) {
        if (expectedValues[property] !== actualValues[property]) {
          diffs.push({
            caseName: testCase.name,
            width,
            label: check.label,
            selector: check.selector,
            property,
            expected: expectedValues[property],
            actual: actualValues[property],
          })
        }
      }
    }
  }
  return diffs
}

function extractCandidates(html) {
  const out = new Set()
  for (const match of html.matchAll(/\bclass(?:Name)?\s*=\s*(["'])([\s\S]*?)\1/g)) {
    addCandidates(out, match[2])
  }
  for (const match of html.matchAll(/\bclass(?:Name)?\s*=\s*([^\s"'`=<>]+)/g)) {
    addCandidates(out, match[1])
  }
  return [...out]
}

function addCandidates(out, value) {
  for (const candidate of value.split(/\s+/)) {
    if (candidate.length > 0) out.add(candidate)
  }
}

async function startBrowser(chrome) {
  const port = 18000 + Math.floor(Math.random() * 20000)
  const userDataDir = await mkdtemp(join(tmpdir(), 'calmcss-chrome-'))
  const child = spawn(chrome, [
    '--headless=new',
    '--disable-gpu',
    '--disable-extensions',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    'about:blank',
  ], { stdio: 'ignore' })

  await waitForChrome(port)
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
  const page = pages.find((entry) => entry.type === 'page') ?? pages[0]
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => {
    ws.onopen = resolve
    ws.onerror = reject
  })

  let id = 0
  const pending = new Map()
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data)
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message)
      pending.delete(message.id)
    }
  }
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const message = { id: ++id, method, params }
      pending.set(message.id, resolve)
      ws.send(JSON.stringify(message))
    })

  await send('Page.enable')
  await send('Runtime.enable')

  return {
    send,
    async close() {
      ws.close()
      child.kill('SIGTERM')
      await new Promise((resolve) => child.once('exit', resolve))
      await rm(userDataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
    },
  }
}

async function startStaticServer() {
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1')
      const pathname = decodeURIComponent(url.pathname)
      const relative = pathname === '/' ? 'web/index.html' : pathname.slice(1)
      const normalized = normalize(relative)
      if (normalized.startsWith('..') || normalized.startsWith('/')) {
        response.writeHead(403)
        response.end('forbidden')
        return
      }
      const body = await readFile(normalized)
      response.writeHead(200, { 'content-type': contentType(normalized) })
      response.end(body)
    } catch {
      response.writeHead(404)
      response.end('not found')
    }
  })

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  }
}

function contentType(path) {
  switch (extname(path)) {
    case '.html':
      return 'text/html; charset=utf-8'
    case '.css':
      return 'text/css; charset=utf-8'
    case '.wasm':
      return 'application/wasm'
    case '.js':
      return 'application/javascript; charset=utf-8'
    default:
      return 'application/octet-stream'
  }
}

async function waitForChrome(port) {
  for (let i = 0; i < 80; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`)
      if (response.ok) return
    } catch {}
    await sleep(100)
  }
  throw new Error('Chrome did not start')
}

async function waitForLoad(send) {
  for (let i = 0; i < 80; i++) {
    const response = await send('Runtime.evaluate', {
      expression: 'document.readyState',
      returnByValue: true,
    })
    if (response.result.result.value === 'complete') return
    await sleep(100)
  }
  throw new Error('Page did not finish loading')
}

async function waitForDemoReady(browser) {
  for (let i = 0; i < 80; i++) {
    const response = await browser.send('Runtime.evaluate', {
      expression: 'document.querySelector("#status")?.textContent',
      returnByValue: true,
    })
    const value = response.result.result.value
    if (value && value !== 'loading') {
      if (value === 'demo unavailable') {
        const error = await browser.send('Runtime.evaluate', {
          expression: 'document.querySelector("#css")?.textContent',
          returnByValue: true,
        })
        throw new Error(`web demo unavailable: ${error.result.result.value}`)
      }
      return
    }
    await sleep(100)
  }
  throw new Error('Demo did not become ready')
}

async function waitForDemoRender(browser, testCase) {
  for (let i = 0; i < 80; i++) {
    const response = await browser.send('Runtime.evaluate', {
      expression: `
        (() => {
          const status = document.querySelector("#status")?.textContent ?? "";
          const doc = document.querySelector("#preview")?.contentDocument;
          const selectors = ${JSON.stringify([...new Set(testCase.checks.map((check) => check.selector))])};
          return /bytes$/.test(status) &&
            !!doc?.querySelector("style") &&
            selectors.every((selector) => !!doc.querySelector(selector));
        })()
      `,
      returnByValue: true,
    })
    if (response.result.result.value === true) return
    await sleep(100)
  }
  throw new Error('Demo did not render preview')
}

function pageUrl(html, css) {
  const page = `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>${html}</body></html>`
  return `data:text/html;charset=utf-8,${encodeURIComponent(page)}`
}

function findChrome() {
  const candidates = [
    process.env.CHROME_BIN,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean)
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  throw new Error('Could not find Chrome/Chromium. Set CHROME_BIN to run web demo parity.')
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
