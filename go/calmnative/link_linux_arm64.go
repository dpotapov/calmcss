//go:build cgo && linux && arm64

package calmnative

/*
#cgo LDFLAGS: -L${SRCDIR}/prebuilt/linux_arm64 -lcalmcss_cgo -lm
*/
import "C"
