//go:build cgo

package calmnative

/*
#include "calmcss.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// ErrClosed is returned when a compiler is used after Close.
var ErrClosed = errors.New("calmcss native compiler is closed")

var zeroByte byte

// Version returns the CalmCSS library version.
func Version() string {
	return C.GoString(C.calm_version())
}

// Compile compiles one anonymous input chunk into minified CSS.
func Compile(input []byte) ([]byte, error) {
	var inPtr *C.uint8_t
	if len(input) > 0 {
		inPtr = (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(input)))
	} else {
		inPtr = (*C.uint8_t)(unsafe.Pointer(&zeroByte))
	}

	needed := C.calm_compile(inPtr, C.size_t(len(input)), nil, 0)
	if needed == 0 {
		return nil, nil
	}

	out := make([]byte, int(needed))
	got := C.calm_compile(inPtr, C.size_t(len(input)), bytePtr(out), needed)
	if got > needed {
		return nil, fmt.Errorf("calm_compile result grew from %d to %d bytes", needed, got)
	}
	return out[:int(got)], nil
}

// Compiler keeps named input chunks and renders CSS from the current chunk set.
//
// A Compiler is not safe for concurrent use.
type Compiler struct {
	ptr    *C.calmcss_compiler
	closed bool
}

// NewCompiler creates a reusable CalmCSS compiler.
func NewCompiler() (*Compiler, error) {
	ptr := C.calm_create()
	if ptr == nil {
		return nil, errors.New("calm_create returned null")
	}
	return &Compiler{ptr: ptr}, nil
}

// Close releases native compiler memory. It is safe to call Close more than once.
func (c *Compiler) Close() {
	if c == nil || c.closed {
		return
	}
	C.calm_destroy(c.ptr)
	c.ptr = nil
	c.closed = true
}

// Clear removes all chunks from the compiler.
func (c *Compiler) Clear() error {
	if c == nil || c.closed {
		return ErrClosed
	}
	C.calm_clear(c.ptr)
	return nil
}

// PutChunk adds or replaces a named input chunk.
func (c *Compiler) PutChunk(name string, content []byte) error {
	if c == nil || c.closed {
		return ErrClosed
	}

	nameBytes := []byte(name)
	rc := C.calm_put_chunk(
		c.ptr,
		bytePtr(nameBytes),
		C.size_t(len(nameBytes)),
		bytePtr(content),
		C.size_t(len(content)),
	)
	if rc == 0 {
		return nil
	}
	if rc == -2 {
		return errors.New("calm_put_chunk failed to allocate memory")
	}
	return fmt.Errorf("calm_put_chunk failed with code %d", int(rc))
}

// Render renders the current chunk set into minified CSS.
func (c *Compiler) Render() ([]byte, error) {
	if c == nil || c.closed {
		return nil, ErrClosed
	}

	n := C.calm_render(c.ptr)
	if n == 0 {
		return nil, nil
	}

	ptr := C.calm_result_ptr(c.ptr)
	got := C.calm_result_len(c.ptr)
	if ptr == nil || got == 0 {
		return nil, errors.New("calm_render returned data without a result pointer")
	}
	data := unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(got))
	return append([]byte(nil), data...), nil
}

func bytePtr(data []byte) *C.uint8_t {
	if len(data) == 0 {
		return (*C.uint8_t)(unsafe.Pointer(&zeroByte))
	}
	return (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(data)))
}
