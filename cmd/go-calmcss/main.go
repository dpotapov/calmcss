package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/calmcss/calmcss/go/calmnative"
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
	return calmnative.Compile(input)
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "go-calmcss: "+format+"\n", args...)
	os.Exit(1)
}
