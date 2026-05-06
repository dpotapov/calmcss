import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'
import { spawnFile } from './process.mjs'

const root = process.env.CALMCSS_TAILWIND_SRC_ROOT
const maxCandidates = Number.parseInt(process.env.CALMCSS_OFFICIAL_SET_MAX_CANDIDATES ?? '20', 10)
const maxDiffs = Number.parseInt(process.env.CALMCSS_PARITY_DIFFS ?? '20', 10)

if (!root) {
  throw new Error(
    'Set CALMCSS_TAILWIND_SRC_ROOT to a Tailwind CSS source root, for example /path/to/tailwindcss/packages/tailwindcss/src',
  )
}
if (!existsSync(root)) {
  throw new Error(`Tailwind source tree not found: ${root}`)
}

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const blocks = []
for (const file of await listTests(root)) {
  const text = await readFile(file, 'utf8')
  for (const block of candidateBlocks(text)) {
    const candidates = quotedStrings(block).filter(
      (candidate) =>
        candidate.length > 0 &&
        candidate.length < 140 &&
        !/[\s{};]/.test(candidate),
    )
    const unique = [...new Set(candidates)]
    if (unique.length >= 2 && unique.length <= maxCandidates) {
      blocks.push({ file, candidates: unique })
    }
  }
}

const themePath = fileURLToPath(import.meta.resolve('tailwindcss/theme.css'))
const themeCss = await readFile(themePath, 'utf8')
const tailwindInput = `${themeCss}\n@tailwind utilities;`
const dir = await mkdtemp(join(tmpdir(), 'calmcss-official-set-parity-'))

let pass = 0
let fail = 0
let skippedEmpty = 0
const diffs = []

try {
  for (const [idx, block] of blocks.entries()) {
    const tailwind = await compile(tailwindInput)
    const expected = normalizeCss(optimize(tailwind.build(block.candidates), { minify: true }).code)
    if (expected.length === 0) {
      skippedEmpty += 1
      continue
    }

    const inputPath = join(dir, `case-${idx}.html`)
    await writeFile(inputPath, `<div class="${block.candidates.join(' ')}"></div>`)
    const actualCss = (await spawnFile('./zig-out/bin/calmcss', [inputPath])).stdout
    const actual = normalizeCss(actualCss)
    const optimizedActual = normalizeCss(optimize(actualCss, { minify: true }).code)

    if (actual === expected || optimizedActual === expected) {
      pass += 1
    } else {
      fail += 1
      if (diffs.length < maxDiffs) {
        diffs.push({ ...block, expected, actual })
      }
    }
  }
} finally {
  await rm(dir, { recursive: true, force: true })
}

const checked = pass + fail
const pct = checked === 0 ? 100 : (pass / checked) * 100
console.log(
  `CalmCSS/Tailwind official set parity: ${pass}/${checked} (${pct.toFixed(2)}%), skipped empty ${skippedEmpty}/${blocks.length}`,
)

if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.file}`)
    console.log(`  candidates: ${diff.candidates.join(' ')}`)
    console.log(`  tailwind:   ${diff.expected.slice(0, 800)}${diff.expected.length > 800 ? '...' : ''}`)
    console.log(`  calmcss:    ${diff.actual.slice(0, 800)}${diff.actual.length > 800 ? '...' : ''}`)
  }
}

if (fail > 0) {
  process.exitCode = 1
}

async function listTests(dir) {
  const out = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...await listTests(path))
    else if (entry.name.endsWith('.test.ts')) out.push(path)
  }
  return out
}

function candidateBlocks(text) {
  const blocks = []
  for (const re of [/run\(\s*\[([\s\S]*?)\]\s*\)/g, /compileCss\([\s\S]*?,\s*\[([\s\S]*?)\]/g]) {
    for (const match of text.matchAll(re)) blocks.push(match[1])
  }
  return blocks
}

function quotedStrings(text) {
  const out = []
  for (const match of text.matchAll(/(['"])((?:\\.|(?!\1)[^\\\n])*)\1/g)) {
    out.push(match[2].replace(/\\(['"])/g, '$1'))
  }
  return out
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
