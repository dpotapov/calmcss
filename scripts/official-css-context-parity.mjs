import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'
import { spawnFile } from './process.mjs'
import { loadTailwindStylesheet } from './tailwind-stylesheet-loader.mjs'

const tailwindSrcRoot = process.env.CALMCSS_TAILWIND_SRC_ROOT
const defaultFiles = tailwindSrcRoot
  ? [
      join(tailwindSrcRoot, 'index.test.ts'),
      join(tailwindSrcRoot, 'variants.test.ts'),
      join(tailwindSrcRoot, 'at-import.test.ts'),
    ]
  : []

const files = (process.env.CALMCSS_OFFICIAL_CONTEXT_FILES ?? defaultFiles.join(','))
  .split(',')
  .map((file) => file.trim())
  .filter(Boolean)
const limit = Number.parseInt(process.env.CALMCSS_OFFICIAL_CONTEXT_LIMIT ?? '0', 10)
const maxDiffs = Number.parseInt(process.env.CALMCSS_PARITY_DIFFS ?? '20', 10)
const allowFail = process.env.CALMCSS_OFFICIAL_CONTEXT_ALLOW_FAIL === '1'

if (files.length === 0) {
  throw new Error(
    'Set CALMCSS_TAILWIND_SRC_ROOT or CALMCSS_OFFICIAL_CONTEXT_FILES before running official CSS-context parity',
  )
}
for (const file of files) {
  if (!existsSync(file)) throw new Error(`Tailwind test file not found: ${file}`)
}

await spawnFile('zig', ['build'], { stdio: 'inherit' })

const cases = []
for (const file of files) {
  const source = await readFile(file, 'utf8')
  collectStaticCompileCssCases(cases, file, source)
}

const selected = limit > 0 ? cases.slice(0, limit) : cases
const dir = await mkdtemp(join(tmpdir(), 'calmcss-official-css-context-'))
let pass = 0
let fail = 0
let skip = 0
const diffs = []

try {
  for (const [index, testCase] of selected.entries()) {
    let expected
    try {
      const tailwind = await compile(testCase.css, { loadStylesheet: loadTailwindStylesheet })
      expected = normalizeCss(optimize(tailwind.build(testCase.candidates), { minify: true }).code)
    } catch {
      skip += 1
      continue
    }

    const inputPath = join(dir, `case-${index}.html`)
    await writeFile(
      inputPath,
      `<style>${testCase.css}</style><div class="${testCase.candidates.join(' ')}"></div>`,
    )

    const run = spawnSync('./zig-out/bin/calmcss', [inputPath], { encoding: 'utf8' })
    const actualCss = run.status === 0 ? run.stdout : `<exit ${run.status}> ${run.stderr || run.stdout}`
    const actual = normalizeCss(actualCss)
    let optimizedActual = actual
    if (run.status === 0) {
      try {
        optimizedActual = normalizeCss(optimize(actualCss, { minify: true }).code)
      } catch {}
    }

    if (run.status === 0 && (actual === expected || optimizedActual === expected)) {
      pass += 1
    } else {
      fail += 1
      if (diffs.length < maxDiffs) {
        diffs.push({ ...testCase, expected, actual })
      }
    }
  }
} finally {
  await rm(dir, { recursive: true, force: true })
}

const total = pass + fail + skip
const comparable = pass + fail
const pct = comparable === 0 ? 100 : (pass / comparable) * 100
console.log(
  `CalmCSS/Tailwind official CSS-context parity: ${pass}/${comparable} comparable (${pct.toFixed(2)}%), skipped ${skip}/${total}, mined ${cases.length}`,
)

if (diffs.length > 0) {
  console.log('')
  for (const diff of diffs) {
    console.log(`not ok - ${diff.name}`)
    console.log(`  file: ${diff.file}`)
    console.log(`  candidates: ${diff.candidates.join(' ')}`)
    console.log(`  tailwind:   ${clip(diff.expected) || '<empty>'}`)
    console.log(`  calmcss:    ${clip(diff.actual) || '<empty>'}`)
  }
}

if (fail > 0 && !allowFail) {
  process.exitCode = 1
}

function collectStaticCompileCssCases(out, file, source) {
  let search = 0
  while (true) {
    const call = source.indexOf('compileCss(', search)
    if (call === -1) break
    const open = call + 'compileCss'.length
    const close = scanParen(source, open)
    search = close == null ? call + 'compileCss('.length : close + 1
    if (close == null) continue

    const args = splitTopLevelArgs(source.slice(open + 1, close))
    if (args.length < 2) continue

    const css = resolveCssArgument(source, call, args[0])
    if (css == null) continue
    if (css.includes('${')) continue

    const candidatesSource = args[1].trim()
    if (!candidatesSource.startsWith('[')) continue

    let candidates
    try {
      candidates = Function(`return (${candidatesSource})`)()
    } catch {
      continue
    }
    if (!Array.isArray(candidates) || !candidates.every((candidate) => typeof candidate === 'string')) continue

    out.push({
      file,
      name: nearestTestName(source, call) ?? `${file}:${call}`,
      css,
      candidates,
    })
  }
}

function resolveCssArgument(source, call, rawArg) {
  const arg = rawArg.trim()
  const inline = templateValue(arg)
  if (inline != null) return inline

  let stringValue
  try {
    stringValue = Function(`return (${arg})`)()
  } catch {}
  if (typeof stringValue === 'string') return stringValue

  if (!/^[A-Za-z_$][\w$]*$/.test(arg)) return null
  const declarations = source.slice(0, call)
  const declarationPattern = new RegExp(`(?:let|const|var)\\s+${escapeRegExp(arg)}\\s*=\\s*`, 'g')
  let match
  let last = null
  while ((match = declarationPattern.exec(declarations)) != null) last = match
  if (last == null) return null

  const valueStart = last.index + last[0].length
  const tail = declarations.slice(valueStart)
  return templateValue(tail)
}

function templateValue(source) {
  const value = source.trimStart()
  if (value.startsWith('css`')) {
    const end = scanTemplate(value, 'css`'.length)
    return end == null ? null : value.slice('css`'.length, end)
  }
  if (value.startsWith('String.raw`')) {
    const end = scanTemplate(value, 'String.raw`'.length)
    return end == null ? null : value.slice('String.raw`'.length, end)
  }
  if (value.startsWith('`')) {
    const end = scanTemplate(value, 1)
    return end == null ? null : value.slice(1, end)
  }
  return null
}

function splitTopLevelArgs(input) {
  const args = []
  let start = 0
  let parenDepth = 0
  let bracketDepth = 0
  let braceDepth = 0
  let quote = null
  for (let i = 0; i <= input.length; i += 1) {
    const atEnd = i === input.length
    if (!atEnd) {
      const char = input[i]
      if (quote) {
        if (char === '\\') {
          i += 1
          continue
        }
        if (char === quote) quote = null
        continue
      }
      if (char === '"' || char === "'" || char === '`') {
        quote = char
        continue
      }
      if (char === '(') parenDepth += 1
      else if (char === ')') parenDepth -= 1
      else if (char === '[') bracketDepth += 1
      else if (char === ']') bracketDepth -= 1
      else if (char === '{') braceDepth += 1
      else if (char === '}') braceDepth -= 1
      if (char !== ',' || parenDepth !== 0 || bracketDepth !== 0 || braceDepth !== 0) continue
    }
    args.push(input.slice(start, i))
    start = i + 1
  }
  return args
}

function scanTemplate(source, start) {
  for (let i = start; i < source.length; i += 1) {
    if (source[i] === '\\') {
      i += 1
      continue
    }
    if (source[i] === '`') return i
  }
  return null
}

function scanParen(source, open) {
  if (source[open] !== '(') return null
  let depth = 1
  let quote = null
  for (let i = open + 1; i < source.length; i += 1) {
    const char = source[i]
    if (quote) {
      if (char === '\\') {
        i += 1
        continue
      }
      if (char === quote) quote = null
      continue
    }
    if (char === '"' || char === "'" || char === '`') {
      quote = char
      continue
    }
    if (char === '(') depth += 1
    else if (char === ')') {
      depth -= 1
      if (depth === 0) return i
    }
  }
  return null
}

function scanBracket(source, start) {
  let depth = 0
  let quote = null
  for (let i = start; i < source.length; i += 1) {
    const char = source[i]
    if (quote) {
      if (char === '\\') i += 1
      else if (char === quote) quote = null
      continue
    }
    if (char === '"' || char === "'" || char === '`') {
      quote = char
      continue
    }
    if (char === '[') depth += 1
    else if (char === ']') {
      depth -= 1
      if (depth === 0) return i + 1
    }
  }
  return null
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function nearestTestName(source, position) {
  const before = source.slice(Math.max(0, position - 1000), position)
  const matches = [...before.matchAll(/(?:test|it)\(['"]([^'"]+)/g)]
  return matches.at(-1)?.[1]
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

function clip(value) {
  return value.length > 500 ? `${value.slice(0, 500)}...` : value
}
