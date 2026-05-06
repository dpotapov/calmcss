import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { compile } from 'tailwindcss'
import { optimize } from '@tailwindcss/node'

const fixture = process.argv[2]
if (!fixture) {
  console.error('usage: node scripts/tailwind-bench.mjs <fixture.html>')
  process.exit(2)
}

const content = await readFile(fixture, 'utf8')
const candidates = extractCandidates(content)
const themePath = fileURLToPath(import.meta.resolve('tailwindcss/theme.css'))
const themeCss = await readFile(themePath, 'utf8')
const { build } = await compile(`${themeCss}\n@tailwind utilities;`)
const css = optimize(build(candidates), { minify: true }).code
process.stdout.write(css)

function extractCandidates(content) {
  const seen = new Set()
  for (const token of content.match(/[A-Za-z0-9_!:/.[\]()%#,+=$*~<>-]+/g) ?? []) {
    if (token.includes('-') || token.includes(':') || token.includes('[') || knownStatic(token)) {
      seen.add(token.replace(/^[.#<>]+|[.,;<>]+$/g, ''))
    }
  }
  return [...seen].sort()
}

function knownStatic(token) {
  return [
    'block',
    'flex',
    'grid',
    'hidden',
    'inline',
    'prose',
    'relative',
    'absolute',
    'fixed',
    'sticky',
    'container',
  ].includes(token)
}
