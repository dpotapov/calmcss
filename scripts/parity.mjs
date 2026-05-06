import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'
import { spawnFile } from './process.mjs'

const candidatesPath = process.env.CALMCSS_PARITY_CANDIDATES ?? 'test/parity_candidates.json'
const candidates = JSON.parse(await readFile(candidatesPath, 'utf8'))
const limit = Number.parseInt(process.env.CALMCSS_PARITY_LIMIT ?? `${candidates.length}`, 10)
const selected = candidates.slice(0, limit)
const maxDiffs = Number.parseInt(process.env.CALMCSS_PARITY_DIFFS ?? '20', 10)

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const themePath = fileURLToPath(import.meta.resolve('tailwindcss/theme.css'))
const themeCss = await readFile(themePath, 'utf8')
const tailwindInput = `${themeCss}\n@tailwind utilities;`
const dir = await mkdtemp(join(tmpdir(), 'calmcss-parity-'))

let pass = 0
let fail = 0
const diffs = []

try {
  for (const candidate of selected) {
    const tailwind = await compile(tailwindInput)
    const expected = normalizeCss(optimize(tailwind.build([candidate]), { minify: true }).code)
    const inputPath = join(dir, `${safeName(candidate)}.html`)
    await writeFile(inputPath, candidate)
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
console.log(`CalmCSS/Tailwind parity: ${pass}/${total} (${pct.toFixed(2)}%)`)
if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.candidate}`)
    console.log(`  tailwind: ${diff.expected || '<empty>'}`)
    console.log(`  calmcss:  ${diff.actual || '<empty>'}`)
  }
}

if (pct < Number.parseFloat(process.env.CALMCSS_PARITY_MIN ?? '99')) {
  process.exitCode = 1
}

function normalizeCss(css) {
  return css
    .replace(/\/\*! tailwindcss[^*]*\*\//g, '')
    .replace(/:root,:host\{[^{}]*\}/g, '')
    .replace(/\s+/g, '')
    .replace(/\s*([{}:;,>+~])\s*/g, '$1')
    .replace(/calc\(var\((--[\w-]+)\)\*([^)]+)\)/g, 'calc(var($1)*$2)')
    .replace(/;}/g, '}')
    .trim()
}

function safeName(candidate) {
  return candidate.replace(/[^a-zA-Z0-9_-]+/g, '_')
}
