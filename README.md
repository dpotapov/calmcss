# CalmCSS

CalmCSS is a small Tailwind CSS v4-compatible utility compiler written in Zig
0.16. It scans named content chunks, extracts utility candidates, and emits
minified CSS. The same core is exposed as:

- `calmcss`, a Zig CLI
- `libcalmcss.a`, a static C ABI library
- `calmcss.wasm`, a freestanding `wasm32` module with no WASI dependency
- `go/calmnative`, a Go library using CGO and the Zig static library
- `go/calmwasm`, a Go library using the freestanding WASM module through wazero
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

CalmCSS combines Zig emitters with generated Tailwind parity data derived from
official Tailwind CSS output for checked core and plugin candidates. Every build
output includes the same parity data, so the CLI, C libraries, CGO archive, and
WASM module have the same checked class behavior.

Default `zig build` behavior:

| Output | Build mode |
| --- | --- |
| `zig-out/bin/calmcss` | CLI |
| `zig-out/lib/libcalmcss.a` | static C library |
| `zig-out/lib/libcalmcss_cgo.a` | CGO-friendly static library |
| `zig-out/wasm/calmcss.wasm` | freestanding WASM |

## CLI

```sh
zig-out/bin/calmcss examples/input.html
zig-out/bin/calmcss -i examples/input.html -o zig-out/example.css
zig-out/bin/calmcss --chunk page.html=examples/input.html --chunk component.html=examples/component.html
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
compiler intentionally avoids JavaScript configuration for portability and v4
parity. Put customization in CSS using directives like `@theme`, `@utility`,
`@source`, and `@plugin`. Compatibility syntax that Tailwind v4 still accepts,
such as `@tailwind utilities` and `theme(...)`, is kept for parity, but new
examples should use CSS imports and CSS-first theme variables.

```css
@import "tailwindcss";

@theme {
  --font-display: Inter, sans-serif;
  --background-image-gradient-text: linear-gradient(276deg, #ff008f, #4d3384);
}

@source inline("prose form-input form-checkbox");
@plugin "@tailwindcss/typography";
@plugin "@tailwindcss/forms";
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

## Go Libraries

CalmCSS exposes two importable Go packages with the same basic shape:

- `github.com/dpotapov/calmcss/go/calmnative` uses CGO and links the Zig static
  library. Prebuilt static archives are bundled for Linux amd64/arm64, macOS
  arm64, and Windows amd64/arm64, so users on those targets do not need to
  install Zig. CGO must still be enabled and a C linker/compiler must be
  available.
- `github.com/dpotapov/calmcss/go/calmwasm` does not use CGO. It runs
  `calmcss.wasm` with wazero, and callers pass the WASM bytes explicitly.

Native CGO package:

```go
package main

import (
	"os"

	"github.com/dpotapov/calmcss/go/calmnative"
)

func main() {
	css, err := calmnative.Compile([]byte(`<div class="p-4 text-blue-600"></div>`))
	if err != nil {
		panic(err)
	}
	_ = os.WriteFile("calm.css", css, 0o644)
}
```

WASM package:

```go
package main

import (
	"context"
	"os"

	"github.com/dpotapov/calmcss/go/calmwasm"
)

func main() {
	ctx := context.Background()
	wasmBytes, err := os.ReadFile("calmcss.wasm")
	if err != nil {
		panic(err)
	}

	css, err := calmwasm.Compile(ctx, wasmBytes, []byte(`<div class="grid gap-4"></div>`))
	if err != nil {
		panic(err)
	}
	_ = os.WriteFile("calm.css", css, 0o644)
}
```

Both packages also expose a reusable `Compiler` with `PutChunk`, `Render`,
`Clear`, and `Close` for long-running processes.

## Go CLIs

`go-calmcss` uses the CGO package with bundled native archives, while
`wazero-calmcss` uses the no-CGO WASM package. Build the Zig artifacts first
when running the WASM CLI from this repository so `zig-out/wasm/calmcss.wasm`
exists.

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

Regenerate the bundled native archives after changing the Zig ABI library:

```sh
scripts/build-go-native-prebuilt.sh
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
| Tailwind CSS 4.2.4 | Node.js official compiler | 107.880 ms/run | 1.00x | 79.08 MiB | standalone CLI: 73.1 MiB |
| CalmCSS | Zig native CLI | 12.181 ms/run | 8.86x | 2.44 MiB | 1.25 MiB |
| CalmCSS | Go + CGO static library | 16.721 ms/run | 6.45x | 10.42 MiB | 3.69 MiB CLI, 1.48 MiB lib |
| CalmCSS | Go + wazero + WASM | 125.425 ms/run | 0.86x | 48.06 MiB | 6.50 MiB CLI, 1.14 MiB WASM |

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
