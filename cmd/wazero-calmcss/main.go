package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/dpotapov/calmcss/go/calmwasm"
)

func main() {
	var output string
	var wasmPath string
	flag.StringVar(&output, "o", "", "output CSS file")
	flag.StringVar(&wasmPath, "wasm", "zig-out/wasm/calmcss.wasm", "CalmCSS wasm binary")
	flag.Parse()

	input, err := readInputs(flag.Args())
	if err != nil {
		exitf("%v", err)
	}
	wasmBytes, err := os.ReadFile(wasmPath)
	if err != nil {
		exitf("read wasm %s: %v", wasmPath, err)
	}

	css, err := compileWithWasm(context.Background(), wasmBytes, input)
	if err != nil {
		exitf("%v", err)
	}
	if output != "" {
		if err := os.WriteFile(output, css, 0o644); err != nil {
			exitf("write %s: %v", output, err)
		}
		return
	}
	_, _ = os.Stdout.Write(css)
}

func readInputs(paths []string) ([]byte, error) {
	if len(paths) == 0 {
		return io.ReadAll(os.Stdin)
	}
	var buf bytes.Buffer
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", path, err)
		}
		buf.WriteByte('\n')
		buf.Write(data)
	}
	return buf.Bytes(), nil
}

func compileWithWasm(ctx context.Context, wasmBytes []byte, input []byte) ([]byte, error) {
	return calmwasm.Compile(ctx, wasmBytes, input)
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "wazero-calmcss: "+format+"\n", args...)
	os.Exit(1)
}
