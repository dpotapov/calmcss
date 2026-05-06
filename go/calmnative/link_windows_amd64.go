//go:build cgo && windows && amd64

package calmnative

/*
#cgo LDFLAGS: -L${SRCDIR}/prebuilt/windows_amd64 -lcalmcss_cgo
*/
import "C"
