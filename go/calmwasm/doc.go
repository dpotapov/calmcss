// Package calmwasm exposes CalmCSS through the freestanding WASM ABI without CGO.
//
// Callers provide the calmcss.wasm bytes, typically from zig-out/wasm/calmcss.wasm
// or a release artifact, and this package runs the module with wazero.
package calmwasm
