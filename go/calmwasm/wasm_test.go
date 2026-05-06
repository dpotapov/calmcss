package calmwasm

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestCompile(t *testing.T) {
	wasmBytes := readTestWASM(t)
	css, err := Compile(context.Background(), wasmBytes, []byte(`<div class="grid grid-cols-3 gap-4"></div>`))
	if err != nil {
		t.Fatal(err)
	}
	assertContains(t, string(css), []string{
		`.gap-4{gap:calc(var(--spacing)*4);}`,
		`.grid{display:grid;}`,
		`.grid-cols-3{grid-template-columns:repeat(3,minmax(0,1fr));}`,
	})
}

func TestCompilerChunks(t *testing.T) {
	compiler, err := NewCompiler(context.Background(), readTestWASM(t))
	if err != nil {
		t.Fatal(err)
	}
	defer compiler.Close(context.Background())

	if err := compiler.PutChunk(context.Background(), "index.html", []byte(`<div class="p-4"></div>`)); err != nil {
		t.Fatal(err)
	}
	css, err := compiler.Render(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	assertContains(t, string(css), []string{`.p-4{padding:calc(var(--spacing)*4);}`})

	if err := compiler.PutChunk(context.Background(), "index.html", []byte(`<div class="m-2"></div>`)); err != nil {
		t.Fatal(err)
	}
	css, err = compiler.Render(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	output := string(css)
	assertContains(t, output, []string{`.m-2{margin:calc(var(--spacing)*2);}`})
	if strings.Contains(output, ".p-4") {
		t.Fatalf("replaced chunk still emitted old utility: %s", output)
	}
}

func readTestWASM(t *testing.T) []byte {
	t.Helper()
	wasmBytes, err := os.ReadFile("../../zig-out/wasm/calmcss.wasm")
	if err != nil {
		t.Fatal(err)
	}
	return wasmBytes
}

func assertContains(t *testing.T, output string, expected []string) {
	t.Helper()
	for _, item := range expected {
		if !strings.Contains(output, item) {
			t.Fatalf("missing %q in %s", item, output)
		}
	}
}
