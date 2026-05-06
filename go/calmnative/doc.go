// Package calmnative exposes CalmCSS through its CGO-backed static C ABI.
//
// This package requires CGO, but it does not require downstream users to install
// Zig on supported targets. Prebuilt CalmCSS static libraries are bundled for
// linux/amd64, linux/arm64, darwin/arm64, windows/amd64, and windows/arm64.
package calmnative
