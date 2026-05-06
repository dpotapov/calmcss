package main

import (
	"strings"
	"testing"
)

func TestCompile(t *testing.T) {
	css, err := compile([]byte(`<div class="p-4 text-blue-600 hover:bg-blue-50"></div>`))
	if err != nil {
		t.Fatal(err)
	}
	output := string(css)
	for _, expected := range []string{
		`.p-4{padding:calc(var(--spacing) * 4)}`,
		`.text-blue-600{color:var(--color-blue-600);}`,
		`.hover\:bg-blue-50:hover{background-color:var(--color-blue-50);}`,
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("missing %q in %s", expected, output)
		}
	}
}
