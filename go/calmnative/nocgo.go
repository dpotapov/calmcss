//go:build !cgo

package calmnative

import "errors"

// ErrClosed is returned when a compiler is used after Close.
var ErrClosed = errors.New("calmcss native compiler is closed")

var errCGODisabled = errors.New("calmcss native package requires CGO_ENABLED=1")

// Version returns the CalmCSS library version.
func Version() string {
	return ""
}

// Compile compiles one anonymous input chunk into minified CSS.
func Compile([]byte) ([]byte, error) {
	return nil, errCGODisabled
}

// Compiler keeps named input chunks and renders CSS from the current chunk set.
type Compiler struct{}

// NewCompiler creates a reusable CalmCSS compiler.
func NewCompiler() (*Compiler, error) {
	return nil, errCGODisabled
}

// Close releases native compiler memory.
func (*Compiler) Close() {}

// Clear removes all chunks from the compiler.
func (*Compiler) Clear() error {
	return errCGODisabled
}

// PutChunk adds or replaces a named input chunk.
func (*Compiler) PutChunk(string, []byte) error {
	return errCGODisabled
}

// Render renders the current chunk set into minified CSS.
func (*Compiler) Render() ([]byte, error) {
	return nil, errCGODisabled
}
