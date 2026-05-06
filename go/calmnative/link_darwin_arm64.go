//go:build cgo && darwin && arm64

package calmnative

/*
#cgo LDFLAGS: -L${SRCDIR}/prebuilt/darwin_arm64 -lcalmcss_cgo
*/
import "C"
