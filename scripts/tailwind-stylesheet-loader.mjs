import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

export const tailwindFullImport = '@import "tailwindcss";'
export const tailwindUtilitiesImport = '@import "tailwindcss/utilities";'
export const tailwindThemeUtilitiesImport =
  '@import "tailwindcss/theme";\n@import "tailwindcss/utilities";'

export const themeCss = await readFile(fileURLToPath(import.meta.resolve('tailwindcss/theme.css')), 'utf8')
export const preflightCss = await readFile(
  fileURLToPath(import.meta.resolve('tailwindcss/preflight.css')),
  'utf8',
)

export async function loadTailwindStylesheet(id, base) {
  if (id === 'tailwindcss/utilities') {
    return { base, content: '@tailwind utilities;' }
  }
  if (id === 'tailwindcss/preflight' || id === 'tailwindcss/preflight.css') {
    return { base, content: preflightCss }
  }
  if (id === 'tailwindcss/theme' || id === 'tailwindcss/theme.css') {
    return { base, content: themeCss }
  }
  if (id === 'tailwindcss') {
    return {
      base,
      content:
        '@import "tailwindcss/theme" layer(theme);@import "tailwindcss/preflight" layer(base);@import "tailwindcss/utilities" layer(utilities);',
    }
  }
  throw new Error(`Unsupported Tailwind stylesheet import: ${id}`)
}
