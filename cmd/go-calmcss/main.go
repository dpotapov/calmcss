package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../include -I${SRCDIR}/../../zig-out/include
#cgo LDFLAGS: ${SRCDIR}/../../zig-out/lib/libcalmcss_cgo.a
#include "calmcss.h"
*/
import "C"

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"unsafe"
)

func main() {
	var output string
	flag.StringVar(&output, "o", "", "output CSS file")
	flag.Parse()

	inputs := flag.Args()
	var content []byte
	var err error
	if len(inputs) == 0 {
		content, err = io.ReadAll(os.Stdin)
		if err != nil {
			exitf("read stdin: %v", err)
		}
	} else {
		var buf bytes.Buffer
		for _, path := range inputs {
			data, err := os.ReadFile(path)
			if err != nil {
				exitf("read %s: %v", path, err)
			}
			buf.WriteByte('\n')
			buf.Write(data)
		}
		content = buf.Bytes()
	}

	css, err := compile(content)
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

func compile(input []byte) ([]byte, error) {
	var inPtr *C.uint8_t
	if len(input) > 0 {
		inPtr = (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(input)))
	}
	needed := C.calm_compile(inPtr, C.size_t(len(input)), nil, 0)
	if needed == 0 {
		return nil, nil
	}
	out := make([]byte, int(needed))
	got := C.calm_compile(inPtr, C.size_t(len(input)), (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(out))), needed)
	if got > needed {
		return nil, fmt.Errorf("calm_compile result grew from %d to %d bytes", needed, got)
	}
	return out[:int(got)], nil
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "go-calmcss: "+format+"\n", args...)
	os.Exit(1)
}
