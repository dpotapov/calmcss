import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'
import { spawnFile } from './process.mjs'

const candidates = JSON.parse(await readFile('test/plugin_candidates.json', 'utf8'))
const maxDiffs = Number.parseInt(process.env.CALMCSS_PARITY_DIFFS ?? '20', 10)

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const pluginCss = '@plugin "@tailwindcss/forms";@plugin "@tailwindcss/typography";@tailwind utilities;'
const dir = await mkdtemp(join(tmpdir(), 'calmcss-plugin-parity-'))
let pass = 0
let fail = 0
const diffs = []

try {
  for (const candidate of candidates) {
    const tailwind = await compile(pluginCss, { loadModule })
    const expected = normalizeCss(optimize(tailwind.build([candidate]), { minify: true }).code)
    const inputPath = join(dir, `${safeName(candidate)}.html`)
    await writeFile(inputPath, `<div class="${candidate}"></div>`)
    const actual = normalizeCss((await spawnFile('./zig-out/bin/calmcss', [inputPath])).stdout)
    if (actual === expected) {
      pass += 1
    } else {
      fail += 1
      if (diffs.length < maxDiffs) diffs.push({ candidate, expected, actual })
    }
  }
} finally {
  await rm(dir, { recursive: true, force: true })
}

const total = pass + fail
const pct = total === 0 ? 100 : (pass / total) * 100
console.log(`CalmCSS/forms+typography parity: ${pass}/${total} (${pct.toFixed(2)}%)`)
if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.candidate}`)
    console.log(`  tailwind: ${diff.expected.slice(0, 600) || '<empty>'}${diff.expected.length > 600 ? '...' : ''}`)
    console.log(`  calmcss:  ${diff.actual.slice(0, 600) || '<empty>'}${diff.actual.length > 600 ? '...' : ''}`)
  }
}

if (pct < Number.parseFloat(process.env.CALMCSS_PARITY_MIN ?? '99')) {
  process.exitCode = 1
}

async function loadModule(id, base, resourceHint) {
  void base
  void resourceHint
  const module = await import(id)
  return { path: id, base: '', module: module.default ?? module }
}

function normalizeCss(css) {
  return css
    .replace(/\/\*! tailwindcss[^*]*\*\//g, '')
    .replace(/\s+/g, '')
    .replace(/\s*([{}:;,>+~])\s*/g, '$1')
    .replace(/;}/g, '}')
    .trim()
}

function safeName(candidate) {
  return candidate.replace(/[^a-zA-Z0-9_-]+/g, '_')
}
