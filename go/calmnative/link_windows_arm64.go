//go:build cgo && windows && arm64

package calmnative

/*
#cgo LDFLAGS: -L${SRCDIR}/prebuilt/windows_arm64 -lcalmcss_cgo
*/
import "C"
