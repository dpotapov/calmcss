//go:build cgo

package calmnative

import (
	"flag"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixtureRoot is the directory whose .chtml/.html/.js files are fed to the
// compiler when running the orc-server-like bootstrap benchmark. Override
// with --calmcss.fixtures=/path/to/web to point at a real workload.
var fixtureRoot = flag.String("calmcss.fixtures", "", "directory with .chtml/.html/.js fixtures for bootstrap benchmarks")

// chunk is a name+content pair, mirroring what orc-server feeds into the
// compiler via PutChunk.
type chunk struct {
	name    string
	content []byte
}

// loadFixtures walks dir and returns every .chtml/.html/.js file as a chunk.
// Returns nil if dir is empty or not a directory; callers should skip the
// benchmark in that case.
func loadFixtures(tb testing.TB, dir string) []chunk {
	tb.Helper()
	if dir == "" {
		return nil
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return nil
	}
	var chunks []chunk
	root := os.DirFS(dir)
	err = fs.WalkDir(root, ".", func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() {
			return nil
		}
		ext := filepath.Ext(path)
		if ext != ".chtml" && ext != ".html" && ext != ".js" {
			return nil
		}
		content, readErr := fs.ReadFile(root, path)
		if readErr != nil {
			return readErr
		}
		chunks = append(chunks, chunk{name: "builtin:" + path, content: content})
		return nil
	})
	if err != nil {
		tb.Fatalf("walk fixtures: %v", err)
	}
	return chunks
}

// Synthetic fixtures roughly matching the orc-server web/ tree: ~120 files,
// total ~1MB, with the largest being a few hundred KB JS bundles.
type syntheticOpts struct {
	files     int
	avgBytes  int
	classPool []string
}

func defaultSynthetic() syntheticOpts {
	return syntheticOpts{
		files:    120,
		avgBytes: 8 * 1024,
		classPool: []string{
			"p-4", "p-2", "p-6", "px-4", "py-2", "pt-1", "pb-3",
			"m-2", "m-4", "mt-6", "mb-2", "mx-auto", "my-1",
			"text-sm", "text-lg", "text-xl", "text-base", "text-xs",
			"font-bold", "font-medium", "font-semibold", "font-normal",
			"text-blue-600", "text-blue-500", "text-gray-900", "text-gray-700",
			"text-red-500", "text-green-600", "text-yellow-500",
			"bg-white", "bg-gray-50", "bg-gray-100", "bg-blue-50", "bg-blue-600",
			"hover:bg-blue-50", "hover:text-blue-600", "hover:underline",
			"rounded", "rounded-md", "rounded-lg", "rounded-full",
			"shadow", "shadow-sm", "shadow-md", "shadow-lg",
			"border", "border-gray-200", "border-gray-300", "border-blue-500",
			"flex", "flex-col", "flex-row", "items-center", "justify-between", "justify-center",
			"grid", "grid-cols-2", "grid-cols-3", "gap-2", "gap-4",
			"w-full", "w-1/2", "h-full", "h-screen", "min-h-screen",
			"sm:px-6", "md:px-8", "lg:px-10", "md:flex-row", "lg:grid-cols-4",
			"focus:outline-none", "focus:ring-2", "focus:ring-blue-500",
			"disabled:opacity-50", "disabled:cursor-not-allowed",
		},
	}
}

func generateSynthetic(opts syntheticOpts) []chunk {
	chunks := make([]chunk, opts.files)
	classes := strings.Join(opts.classPool, " ")
	template := `<div class="` + classes + `">` + strings.Repeat("padding stub ", 20) + `</div>`
	body := strings.Repeat(template, opts.avgBytes/len(template)+1)
	body = body[:opts.avgBytes]
	for i := 0; i < opts.files; i++ {
		name := "synthetic/file_" + itoa(i) + ".chtml"
		chunks[i] = chunk{name: name, content: []byte(body)}
	}
	return chunks
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// BenchmarkBootstrap runs the full orc-server-style bootstrap: create a
// compiler, feed every chunk via PutChunk, then call Render. This is what
// CalmCSSService.Bootstrap does on web service startup.
func BenchmarkBootstrap(b *testing.B) {
	chunks := loadFixtures(b, *fixtureRoot)
	if chunks == nil {
		chunks = generateSynthetic(defaultSynthetic())
		b.Logf("using synthetic fixtures (%d chunks); pass --calmcss.fixtures=/path/to/web for real workload", len(chunks))
	} else {
		var total int
		for _, c := range chunks {
			total += len(c.content)
		}
		b.Logf("using fixtures from %s: %d chunks, %d bytes", *fixtureRoot, len(chunks), total)
	}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		c, err := NewCompiler()
		if err != nil {
			b.Fatal(err)
		}
		for _, ch := range chunks {
			if err := c.PutChunk(ch.name, ch.content); err != nil {
				b.Fatal(err)
			}
		}
		out, err := c.Render()
		if err != nil {
			b.Fatal(err)
		}
		if len(out) == 0 {
			b.Fatal("empty render")
		}
		c.Close()
	}
}

// BenchmarkBootstrapBreakdown reports separate timings for PutChunk loop vs
// Render so we can see where the time goes.
func BenchmarkBootstrapBreakdown(b *testing.B) {
	chunks := loadFixtures(b, *fixtureRoot)
	if chunks == nil {
		chunks = generateSynthetic(defaultSynthetic())
	}

	b.Run("PutChunkAll", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			c, err := NewCompiler()
			if err != nil {
				b.Fatal(err)
			}
			for _, ch := range chunks {
				if err := c.PutChunk(ch.name, ch.content); err != nil {
					b.Fatal(err)
				}
			}
			c.Close()
		}
	})

	b.Run("Render", func(b *testing.B) {
		c, err := NewCompiler()
		if err != nil {
			b.Fatal(err)
		}
		defer c.Close()
		for _, ch := range chunks {
			if err := c.PutChunk(ch.name, ch.content); err != nil {
				b.Fatal(err)
			}
		}
		b.ResetTimer()
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			out, err := c.Render()
			if err != nil {
				b.Fatal(err)
			}
			if len(out) == 0 {
				b.Fatal("empty render")
			}
		}
	})
}

// TestBootstrapTiming runs the full bootstrap once and prints per-stage wall
// time. Useful as a quick reproducer that does not require the testing.B
// framework. Run with `go test -run TestBootstrapTiming -v`.
func TestBootstrapTiming(t *testing.T) {
	chunks := loadFixtures(t, *fixtureRoot)
	if chunks == nil {
		chunks = generateSynthetic(defaultSynthetic())
	}
	var totalBytes int
	for _, c := range chunks {
		totalBytes += len(c.content)
	}
	t.Logf("workload: %d chunks, %d bytes total", len(chunks), totalBytes)

	t0 := time.Now()
	c, err := NewCompiler()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	t.Logf("NewCompiler: %v", time.Since(t0))

	t1 := time.Now()
	for _, ch := range chunks {
		if err := c.PutChunk(ch.name, ch.content); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("PutChunk x%d: %v", len(chunks), time.Since(t1))

	t2 := time.Now()
	out, err := c.Render()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("Render: %v (output %d bytes)", time.Since(t2), len(out))

	t.Logf("TOTAL bootstrap: %v", time.Since(t0))
}
