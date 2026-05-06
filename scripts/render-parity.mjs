import { spawn } from 'node:child_process'
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
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
const calmThemeCss = await readFile('web/theme.css', 'utf8')
const calmPreflightCss = await readFile('web/preflight.css', 'utf8')
const tempDir = await mkdtemp(join(tmpdir(), 'calmcss-render-parity-'))

let pass = 0
let fail = 0
const diffs = []

try {
  for (const testCase of cases) {
    const candidates = extractCandidates(testCase.html)
    const tailwind = await compile(`${officialThemeCss}\n${officialPreflightCss}\n@tailwind utilities;`)
    const officialCss = tailwind.build(candidates)

    const inputPath = join(tempDir, `${safeName(testCase.name)}.html`)
    await writeFile(inputPath, testCase.html)
    const calmUtilityCss = (await spawnFile('./zig-out/bin/calmcss', [inputPath])).stdout
    const calmCss = `${calmThemeCss}\n${calmPreflightCss}\n${calmUtilityCss}`

    const official = await renderCase(chromePath, testCase, officialCss)
    const calm = await renderCase(chromePath, testCase, calmCss)
    const caseDiffs = compareResults(testCase, official, calm)

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
  await rm(tempDir, { recursive: true, force: true })
}

const total = pass + fail
const pct = total === 0 ? 100 : (pass / total) * 100
console.log(`CalmCSS/Tailwind render parity: ${pass}/${total} (${pct.toFixed(2)}%)`)
if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.caseName} @ ${diff.width}px / ${diff.label} / ${diff.property}`)
    console.log(`  selector: ${diff.selector}`)
    console.log(`  tailwind: ${diff.expected}`)
    console.log(`  calmcss:  ${diff.actual}`)
  }
}

if (fail > 0) {
  process.exitCode = 1
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

async function renderCase(chrome, testCase, css) {
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

  try {
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

    const results = {}
    for (const width of testCase.widths) {
      await send('Emulation.setDeviceMetricsOverride', {
        width,
        height: testCase.height ?? 1000,
        deviceScaleFactor: 1,
        mobile: false,
      })
      await send('Page.navigate', { url: pageUrl(testCase.html, css) })
      await waitForLoad(send)
      const evaluation = await send('Runtime.evaluate', {
        expression: `JSON.stringify((${collectComputedStyles.toString()})(${JSON.stringify(testCase.checks)}))`,
        returnByValue: true,
      })
      if (evaluation.exceptionDetails) {
        throw new Error(evaluation.exceptionDetails.text)
      }
      results[width] = JSON.parse(evaluation.result.result.value)
    }

    ws.close()
    return results
  } finally {
    child.kill('SIGTERM')
    await new Promise((resolve) => child.once('exit', resolve))
    await rm(userDataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
  }
}

function collectComputedStyles(checks) {
  const out = {}
  for (const check of checks) {
    const element = document.querySelector(check.selector)
    if (!element) {
      out[check.label] = { __missing: check.selector }
      continue
    }
    const style = getComputedStyle(element)
    const values = {}
    for (const property of check.properties) {
      values[property] = style.getPropertyValue(property)
    }
    out[check.label] = values
  }
  return out
}

function compareResults(testCase, official, calm) {
  const diffs = []
  for (const width of testCase.widths) {
    for (const check of testCase.checks) {
      const expectedValues = official[width][check.label]
      const actualValues = calm[width][check.label]
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
  throw new Error('Could not find Chrome/Chromium. Set CHROME_BIN to run render parity.')
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function safeName(name) {
  return name.replace(/[^a-zA-Z0-9_-]+/g, '_')
}
