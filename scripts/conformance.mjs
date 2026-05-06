import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnFile } from './process.mjs'

const cases = JSON.parse(await readFile('test/conformance_cases.json', 'utf8'))
await spawnFile('zig', ['build'], { stdio: 'inherit' })

let failures = 0
const dir = await mkdtemp(join(tmpdir(), 'calmcss-conformance-'))
try {
  for (const testCase of cases) {
    const input = join(dir, `${slug(testCase.name)}.html`)
    await writeFile(input, testCase.html)
    const { stdout } = await spawnFile('./zig-out/bin/calmcss', [input])
    const normalized = normalizeCss(stdout)
    for (const expected of testCase.contains) {
      const normalizedExpected = normalizeCss(expected)
      if (!normalized.includes(normalizedExpected)) {
        failures += 1
        console.error(`not ok - ${testCase.name}`)
        console.error(`  missing: ${expected}`)
      }
    }
  }
} finally {
  await rm(dir, { recursive: true, force: true })
}

if (failures > 0) {
  process.exitCode = 1
} else {
  console.log(`ok - ${cases.length} CalmCSS conformance cases`)
}

function slug(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
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
