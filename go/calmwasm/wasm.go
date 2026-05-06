package calmwasm

import (
	"context"
	"errors"
	"fmt"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

// ErrClosed is returned when a compiler is used after Close.
var ErrClosed = errors.New("calmcss wasm compiler is closed")

// Compile compiles one anonymous input chunk into minified CSS.
func Compile(ctx context.Context, wasmBytes []byte, input []byte) ([]byte, error) {
	compiler, err := NewCompiler(ctx, wasmBytes)
	if err != nil {
		return nil, err
	}
	defer compiler.Close(ctx)

	if err := compiler.PutChunk(ctx, "stdin", input); err != nil {
		return nil, err
	}
	return compiler.Render(ctx)
}

// Compiler keeps a WASM module instance and renders CSS from named chunks.
//
// A Compiler is not safe for concurrent use.
type Compiler struct {
	runtime wazero.Runtime
	module  api.Module
	memory  api.Memory

	putChunk  api.Function
	render    api.Function
	resultPtr api.Function
	resultLen api.Function
	destroy   api.Function
	alloc     api.Function
	free      api.Function

	handle uint64
	closed bool
}

// NewCompiler creates a reusable CalmCSS compiler from a freestanding WASM module.
func NewCompiler(ctx context.Context, wasmBytes []byte) (*Compiler, error) {
	runtime := wazero.NewRuntime(ctx)
	module, err := runtime.Instantiate(ctx, wasmBytes)
	if err != nil {
		_ = runtime.Close(ctx)
		return nil, fmt.Errorf("instantiate calmcss wasm: %w", err)
	}

	compiler := &Compiler{
		runtime:   runtime,
		module:    module,
		memory:    module.Memory(),
		putChunk:  module.ExportedFunction("calm_put_chunk"),
		render:    module.ExportedFunction("calm_render"),
		resultPtr: module.ExportedFunction("calm_result_ptr"),
		resultLen: module.ExportedFunction("calm_result_len"),
		destroy:   module.ExportedFunction("calm_destroy"),
		alloc:     module.ExportedFunction("calm_alloc"),
		free:      module.ExportedFunction("calm_free"),
	}
	create := module.ExportedFunction("calm_create")
	if create == nil || compiler.putChunk == nil || compiler.render == nil ||
		compiler.resultPtr == nil || compiler.resultLen == nil || compiler.destroy == nil ||
		compiler.alloc == nil || compiler.free == nil || compiler.memory == nil {
		_ = runtime.Close(ctx)
		return nil, errors.New("wasm module does not expose the CalmCSS ABI")
	}

	result, err := create.Call(ctx)
	if err != nil {
		_ = runtime.Close(ctx)
		return nil, fmt.Errorf("calm_create: %w", err)
	}
	if result[0] == 0 {
		_ = runtime.Close(ctx)
		return nil, errors.New("calm_create returned null")
	}
	compiler.handle = result[0]
	return compiler, nil
}

// Close releases the WASM compiler and runtime. It is safe to call Close more than once.
func (c *Compiler) Close(ctx context.Context) error {
	if c == nil || c.closed {
		return nil
	}
	if c.destroy != nil && c.handle != 0 {
		_, _ = c.destroy.Call(ctx, c.handle)
	}
	c.closed = true
	return c.runtime.Close(ctx)
}

// Clear removes all chunks from the compiler.
func (c *Compiler) Clear(ctx context.Context) error {
	if c == nil || c.closed {
		return ErrClosed
	}
	clear := c.module.ExportedFunction("calm_clear")
	if clear == nil {
		return errors.New("wasm module does not expose calm_clear")
	}
	_, err := clear.Call(ctx, c.handle)
	if err != nil {
		return fmt.Errorf("calm_clear: %w", err)
	}
	return nil
}

// PutChunk adds or replaces a named input chunk.
func (c *Compiler) PutChunk(ctx context.Context, name string, content []byte) error {
	if c == nil || c.closed {
		return ErrClosed
	}

	namePtr, err := c.writeBytes(ctx, []byte(name))
	if err != nil {
		return err
	}
	defer c.freeBytes(ctx, namePtr, len(name))

	contentPtr, err := c.writeBytes(ctx, content)
	if err != nil {
		return err
	}
	defer c.freeBytes(ctx, contentPtr, len(content))

	result, err := c.putChunk.Call(ctx, c.handle, uint64(namePtr), uint64(len(name)), uint64(contentPtr), uint64(len(content)))
	if err != nil {
		return fmt.Errorf("calm_put_chunk: %w", err)
	}
	if len(result) > 0 {
		code := int32(uint32(result[0]))
		if code != 0 {
			return fmt.Errorf("calm_put_chunk failed with code %d", code)
		}
	}
	return nil
}

// Render renders the current chunk set into minified CSS.
func (c *Compiler) Render(ctx context.Context) ([]byte, error) {
	if c == nil || c.closed {
		return nil, ErrClosed
	}

	sizeResult, err := c.render.Call(ctx, c.handle)
	if err != nil {
		return nil, fmt.Errorf("calm_render: %w", err)
	}
	if sizeResult[0] == 0 {
		return nil, nil
	}

	ptrResult, err := c.resultPtr.Call(ctx, c.handle)
	if err != nil {
		return nil, fmt.Errorf("calm_result_ptr: %w", err)
	}
	lenResult, err := c.resultLen.Call(ctx, c.handle)
	if err != nil {
		return nil, fmt.Errorf("calm_result_len: %w", err)
	}
	ptr := uint32(ptrResult[0])
	n := uint32(lenResult[0])
	data, ok := c.memory.Read(ptr, n)
	if !ok {
		return nil, errors.New("wasm result range is outside exported memory")
	}
	return append([]byte(nil), data...), nil
}

func (c *Compiler) writeBytes(ctx context.Context, data []byte) (uint32, error) {
	result, err := c.alloc.Call(ctx, uint64(len(data)))
	if err != nil {
		return 0, fmt.Errorf("calm_alloc: %w", err)
	}
	ptr := uint32(result[0])
	if ptr == 0 && len(data) > 0 {
		return 0, errors.New("calm_alloc returned null")
	}
	if !c.memory.Write(ptr, data) {
		c.freeBytes(ctx, ptr, len(data))
		return 0, errors.New("wasm allocation range is outside exported memory")
	}
	return ptr, nil
}

func (c *Compiler) freeBytes(ctx context.Context, ptr uint32, n int) {
	_, _ = c.free.Call(ctx, uint64(ptr), uint64(n))
}
