//go:build cgo

package calmnative

import (
	"strings"
	"testing"
)

func TestCompile(t *testing.T) {
	css, err := Compile([]byte(`<div class="p-4 text-blue-600 hover:bg-blue-50"></div>`))
	if err != nil {
		t.Fatal(err)
	}
	assertContains(t, string(css), []string{
		`.p-4{padding:calc(var(--spacing) * 4)}`,
		`.text-blue-600{color:var(--color-blue-600);}`,
		`.hover\:bg-blue-50:hover{background-color:var(--color-blue-50);}`,
	})
}

func TestCompilerChunks(t *testing.T) {
	compiler, err := NewCompiler()
	if err != nil {
		t.Fatal(err)
	}
	defer compiler.Close()

	if err := compiler.PutChunk("index.html", []byte(`<div class="p-4"></div>`)); err != nil {
		t.Fatal(err)
	}
	css, err := compiler.Render()
	if err != nil {
		t.Fatal(err)
	}
	assertContains(t, string(css), []string{`.p-4{padding:calc(var(--spacing) * 4)}`})

	if err := compiler.PutChunk("index.html", []byte(`<div class="m-2"></div>`)); err != nil {
		t.Fatal(err)
	}
	css, err = compiler.Render()
	if err != nil {
		t.Fatal(err)
	}
	output := string(css)
	assertContains(t, output, []string{`.m-2{margin:calc(var(--spacing)*2);}`})
	if strings.Contains(output, ".p-4") {
		t.Fatalf("replaced chunk still emitted old utility: %s", output)
	}
}

func assertContains(t *testing.T, output string, expected []string) {
	t.Helper()
	for _, item := range expected {
		if !strings.Contains(output, item) {
			t.Fatalf("missing %q in %s", item, output)
		}
	}
}
