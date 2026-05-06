package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/tetratelabs/wazero"
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
	runtime := wazero.NewRuntime(ctx)
	defer runtime.Close(ctx)

	mod, err := runtime.Instantiate(ctx, wasmBytes)
	if err != nil {
		return nil, fmt.Errorf("instantiate calmcss wasm: %w", err)
	}

	create := mod.ExportedFunction("calm_create")
	putChunk := mod.ExportedFunction("calm_put_chunk")
	render := mod.ExportedFunction("calm_render")
	resultPtr := mod.ExportedFunction("calm_result_ptr")
	resultLen := mod.ExportedFunction("calm_result_len")
	destroy := mod.ExportedFunction("calm_destroy")
	alloc := mod.ExportedFunction("calm_alloc")
	free := mod.ExportedFunction("calm_free")
	memory := mod.Memory()
	if create == nil || putChunk == nil || render == nil || resultPtr == nil || resultLen == nil || destroy == nil || alloc == nil || free == nil || memory == nil {
		return nil, fmt.Errorf("wasm module does not expose the CalmCSS ABI")
	}

	ctxResult, err := create.Call(ctx)
	if err != nil {
		return nil, fmt.Errorf("calm_create: %w", err)
	}
	compiler := ctxResult[0]
	defer destroy.Call(ctx, compiler)

	namePtr, err := writeWasmBytes(ctx, alloc, free, memory, []byte("stdin"))
	if err != nil {
		return nil, err
	}
	defer free.Call(ctx, uint64(namePtr), uint64(len("stdin")))
	inputPtr, err := writeWasmBytes(ctx, alloc, free, memory, input)
	if err != nil {
		return nil, err
	}
	defer free.Call(ctx, uint64(inputPtr), uint64(len(input)))

	if _, err := putChunk.Call(ctx, compiler, uint64(namePtr), uint64(len("stdin")), uint64(inputPtr), uint64(len(input))); err != nil {
		return nil, fmt.Errorf("calm_put_chunk: %w", err)
	}
	sizeResult, err := render.Call(ctx, compiler)
	if err != nil {
		return nil, fmt.Errorf("calm_render: %w", err)
	}
	if sizeResult[0] == 0 {
		return nil, nil
	}
	ptrResult, err := resultPtr.Call(ctx, compiler)
	if err != nil {
		return nil, fmt.Errorf("calm_result_ptr: %w", err)
	}
	lenResult, err := resultLen.Call(ctx, compiler)
	if err != nil {
		return nil, fmt.Errorf("calm_result_len: %w", err)
	}
	ptr := uint32(ptrResult[0])
	n := uint32(lenResult[0])
	data, ok := memory.Read(ptr, n)
	if !ok {
		return nil, fmt.Errorf("wasm result range is outside exported memory")
	}
	return append([]byte(nil), data...), nil
}

func writeWasmBytes(ctx context.Context, alloc, free wazeroapi, memory wazeroMemory, data []byte) (uint32, error) {
	result, err := alloc.Call(ctx, uint64(len(data)))
	if err != nil {
		return 0, fmt.Errorf("calm_alloc: %w", err)
	}
	ptr := uint32(result[0])
	if ptr == 0 && len(data) > 0 {
		return 0, fmt.Errorf("calm_alloc returned null")
	}
	if !memory.Write(ptr, data) {
		_, _ = free.Call(ctx, uint64(ptr), uint64(len(data)))
		return 0, fmt.Errorf("wasm allocation range is outside exported memory")
	}
	return ptr, nil
}

type wazeroapi interface {
	Call(context.Context, ...uint64) ([]uint64, error)
}

type wazeroMemory interface {
	Write(uint32, []byte) bool
	Read(uint32, uint32) ([]byte, bool)
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "wazero-calmcss: "+format+"\n", args...)
	os.Exit(1)
}
