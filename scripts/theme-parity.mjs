import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'
import { spawnFile } from './process.mjs'

const casesPath = process.env.CALMCSS_THEME_CASES ?? 'test/theme_cases.json'
const cases = JSON.parse(await readFile(casesPath, 'utf8'))
const maxDiffs = Number.parseInt(process.env.CALMCSS_PARITY_DIFFS ?? '20', 10)

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const dir = await mkdtemp(join(tmpdir(), 'calmcss-theme-parity-'))
let pass = 0
let fail = 0
const diffs = []

try {
  for (const testCase of cases) {
    if (!Array.isArray(testCase.candidates)) {
      throw new Error(`theme parity case "${testCase.name}" must define a candidates array`)
    }
    if (typeof testCase.css !== 'string') {
      throw new Error(`theme parity case "${testCase.name}" must define css`)
    }

    const tailwind = await compile(testCase.css)
    const expected = normalizeCss(optimize(tailwind.build(testCase.candidates), { minify: true }).code)
    const inputPath = join(dir, `${safeName(testCase.name)}.html`)
    await writeFile(inputPath, `<style>${testCase.css}</style><div class="${testCase.candidates.join(' ')}"></div>`)

    const actualCss = (await spawnFile('./zig-out/bin/calmcss', [inputPath])).stdout
    const actual = normalizeCss(actualCss)
    const optimizedActual = normalizeCss(optimize(actualCss, { minify: true }).code)

    if (actual === expected || optimizedActual === expected) {
      pass += 1
    } else {
      fail += 1
      if (diffs.length < maxDiffs) {
        diffs.push({ name: testCase.name, candidates: testCase.candidates, expected, actual })
      }
    }
  }
} finally {
  await rm(dir, { recursive: true, force: true })
}

const total = pass + fail
const pct = total === 0 ? 100 : (pass / total) * 100
console.log(`CalmCSS/Tailwind theme parity: ${pass}/${total} (${pct.toFixed(2)}%)`)

if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.name}`)
    console.log(`  candidates: ${diff.candidates.join(' ')}`)
    console.log(`  tailwind:   ${diff.expected || '<empty>'}`)
    console.log(`  calmcss:    ${diff.actual || '<empty>'}`)
  }
}

if (fail > 0) {
  process.exitCode = 1
}

function normalizeCss(css) {
  return css
    .replace(/\/\*! tailwindcss[^*]*\*\//g, '')
    .replace(/\s+/g, '')
    .replace(/\s*([{}:;,>+~])\s*/g, '$1')
    .replace(/calc\(var\((--[\w-]+)\)\*([^)]+)\)/g, 'calc(var($1)*$2)')
    .replace(/;}/g, '}')
    .trim()
}

function safeName(name) {
  return name.replace(/[^a-zA-Z0-9_-]+/g, '_')
}
