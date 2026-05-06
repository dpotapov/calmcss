# CalmCSS

CalmCSS is a small Tailwind CSS v4-compatible utility compiler written in Zig
0.16. It scans named content chunks, extracts utility candidates, and emits
minified CSS. The same core is exposed as:

- `calmcss`, a Zig CLI
- `libcalmcss.a`, a static C ABI library
- `calmcss.wasm`, a freestanding `wasm32` module with no WASI dependency
- `go-calmcss`, a Go CLI using CGO and the Zig static library
- `wazero-calmcss`, a Go CLI using the freestanding WASM module through wazero
- `web/index.html`, a browser editor that renders CSS on each edit

CalmCSS targets Tailwind v4-compatible output for its checked corpus, including
responsive and pseudo variants, arbitrary values, common core utilities, and
CSS-first `@theme` tokens and static `@utility` definitions for common
customization cases, functional `@utility ...-*` definitions for common
`--value(...)`/`--modifier(...)` forms, body-less CSS-first `@custom-variant`
definitions, plus
class-strategy equivalents for the official forms and typography plugins.
Compatibility is tracked with generated parity suites against Tailwind CSS
4.2.4 and the plugin packages.

The initial version of CalmCSS was created with GPT-5.5 assistance in about
11 hours.

## Build

```sh
zig build
```

Build outputs:

- `zig-out/bin/calmcss`
- `zig-out/lib/libcalmcss.a`
- `zig-out/lib/libcalmcss_cgo.a`
- `zig-out/include/calmcss.h`
- `zig-out/wasm/calmcss.wasm`

CalmCSS has two compatibility paths. The normal compiler path uses Zig code to
parse candidates and emit CSS algorithmically. The compatibility-snapshot path
adds generated lookup tables containing official Tailwind CSS output for a
checked corpus of core and plugin candidates. Those tables improve byte-for-byte
parity for covered edge cases, but they make the binaries much larger.

The installed static libraries and WASM module are built with `ReleaseSmall` and
omit those generated compatibility tables by default. They keep the algorithmic
emitters for common utilities, CSS-first theme/custom utility handling, and
class-strategy forms/typography equivalents. The native CLI includes the tables
by default for the broadest checked Tailwind parity.

Default `zig build` behavior:

| Output | Build mode | Compatibility tables |
| --- | --- | --- |
| `zig-out/bin/calmcss` | CLI | included |
| `zig-out/lib/libcalmcss.a` | static C library | omitted |
| `zig-out/lib/libcalmcss_cgo.a` | CGO-friendly static library | omitted |
| `zig-out/wasm/calmcss.wasm` | freestanding WASM | omitted |

Use `zig build -Dproduction-snapshots=true` when the installed C/WASM artifacts
should include the generated compatibility tables too. Use
`zig build -Dcompat-snapshots=false` to run the CLI using only the smaller
algorithmic compiler path.

## CLI

```sh
zig-out/bin/calmcss examples/input.html
zig-out/bin/calmcss -i examples/input.html -o zig-out/example.css
zig-out/bin/calmcss --chunk page.html=examples/input.html --config examples/calmcss.json
```

If no input file is provided, `calmcss` reads from stdin.

## Config

The compiler supports CSS-first Tailwind v4 `@theme` blocks in input chunks for
common token namespaces: colors, spacing, radius, font, easing, breakpoints,
text sizes, leading, and tracking. Static `@utility name { ... }` definitions
are also collected before class scanning, so custom classes can be used before
or after the CSS block that defines them. Functional `@utility name-* { ... }`
definitions support common `--value(...)` branches for theme values, numeric
bare values, arbitrary values, ratios, quoted literals, and `--modifier(...)`
slash modifiers, plus `--spacing(...)` shorthand in functional utilities.
CSS-first theme variables are emitted only when generated utilities reference
them.
Common `prefix(...)` CSS-first configurations are supported for prefixed
utility candidates and prefixed emitted theme variables.
Body-less `@custom-variant` selector and media definitions are supported for
common custom variant cases, along with selector-body and at-rule-body variants
that use `@slot`, including nested, mixed selector/media, and parallel branches.
Legacy `@variant` custom-variant aliases and authored CSS rules with nested
`@variant` blocks are supported for common built-in, arbitrary selector,
ARIA/data, container, and custom selector cases.
These custom selector variants also compose with `group-*` and `peer-*` forms. The
compiler intentionally avoids JavaScript configuration for portability. A JSON
or YAML file can be passed with
`--config`; strings in that file are scanned as another chunk, so `safelist`
entries work without a JS runtime.

```json
{
  "content": ["examples/**/*.html"],
  "safelist": ["prose", "form-input", "form-checkbox"],
  "plugins": ["forms", "typography"]
}
```

## WASM ABI

The freestanding WASM module exports the same chunk-oriented ABI as the static
library:

- `calm_create() -> handle`
- `calm_destroy(handle)`
- `calm_clear(handle)`
- `calm_put_chunk(handle, name_ptr, name_len, content_ptr, content_len)`
- `calm_render(handle) -> css_len`
- `calm_result_ptr(handle) -> ptr`
- `calm_result_len(handle) -> len`
- `calm_alloc(len) -> ptr`
- `calm_free(ptr, len)`

Each chunk represents one file. Reusing the same chunk name replaces its content,
so runtimes can update a single file and re-render the final CSS.

## Go Wrappers

Build the Zig artifacts first, then build the Go CLIs. `libcalmcss_cgo.a` is a
Darwin-friendly archive rebuilt from the Zig static library for Apple's linker;
on other platforms it is a copy of `libcalmcss.a`.

```sh
zig build
go build ./cmd/go-calmcss
go build ./cmd/wazero-calmcss
```

Run them:

```sh
go run ./cmd/go-calmcss examples/input.html
go run ./cmd/wazero-calmcss -wasm zig-out/wasm/calmcss.wasm examples/input.html
```

## Browser Demo

After `zig build`, serve the repository root and open `web/index.html`:

```sh
python3 -m http.server 8080
```

The page loads `zig-out/wasm/calmcss.wasm`, keeps one `editor.html` chunk, and
updates the preview as the HTML changes. The preview iframe also loads
`web/theme.css` and `web/preflight.css`, browser-usable copies of Tailwind's
default theme variables and Preflight reset, so utility rules that reference CSS
custom properties render against the same baseline as a normal Tailwind page.

## Test and Conformance

```sh
zig build test
npm run conformance
npm run parity:plugins
go test ./...
```

See `TESTING.md` for the full parity matrix, render checks, and optional
Tailwind source corpus checks.

## Benchmarks

```sh
bench/bench.sh examples/input.html
```

The benchmark compares native Zig, Go+CGO, and Go+wazero paths over repeated
compilations, includes a Tailwind JS baseline using `tailwindcss@4.2.4`, reports
peak RSS on macOS through `/usr/bin/time -l`, and prints artifact sizes.

Sample result from `CALMCSS_BENCH_LOOPS=100 bench/bench.sh examples/input.html`
on macOS arm64:

| Implementation | Runtime path | Time | Speedup vs official | Peak RSS | Artifact size |
| --- | --- | ---: | ---: | ---: | ---: |
| Tailwind CSS 4.2.4 | Node.js official compiler | 105.330 ms/run | 1.00x | 76.73 MiB | standalone CLI: 73.1 MiB |
| CalmCSS | Zig native CLI | 9.402 ms/run | 11.20x | 3.25 MiB | 1.94 MiB |
| CalmCSS | Go + CGO static library | 10.446 ms/run | 10.08x | 8.58 MiB | 2.66 MiB CLI, 778 KiB lib |
| CalmCSS | Go + wazero + WASM | 110.194 ms/run | 0.96x | 44.16 MiB | 6.50 MiB CLI, 481 KiB WASM |

Speedup is calculated as official Tailwind JS time divided by implementation
time, so values above `1.00x` are faster than the official implementation.

## Motivation

CalmCSS is built for servers with plugin-based architectures where plugins can
add HTML snippets at runtime. A server can keep one chunk per plugin or template,
replace only the chunks that changed, and regenerate the utility CSS without
embedding Node.js or a JavaScript configuration runtime.

## License and Attribution

CalmCSS is MIT licensed. CalmCSS is an independent implementation inspired by
Tailwind CSS. The bundled default theme variables and Preflight reset rules are
adapted from Tailwind CSS, which is MIT licensed by Tailwind Labs, Inc.
