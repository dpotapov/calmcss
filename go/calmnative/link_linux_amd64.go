//go:build cgo && linux && amd64

package calmnative

/*
#cgo LDFLAGS: -L${SRCDIR}/prebuilt/linux_amd64 -lcalmcss_cgo -lm
*/
import "C"
