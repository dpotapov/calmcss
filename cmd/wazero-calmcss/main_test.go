package main

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestCompileWithWasm(t *testing.T) {
	wasmBytes, err := os.ReadFile("../../zig-out/wasm/calmcss.wasm")
	if err != nil {
		t.Fatal(err)
	}
	css, err := compileWithWasm(context.Background(), wasmBytes, []byte(`<div class="grid grid-cols-3 gap-4"></div>`))
	if err != nil {
		t.Fatal(err)
	}
	output := string(css)
	for _, expected := range []string{
		`.gap-4{gap:calc(var(--spacing) * 4)}`,
		`.grid{display:grid}`,
		`.grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr))}`,
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("missing %q in %s", expected, output)
		}
	}
}
