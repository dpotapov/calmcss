# CalmCSS Native Prebuilt Libraries

These archives are generated from the Zig static C ABI library so Go users can
consume `github.com/calmcss/calmcss/go/calmnative` without installing Zig.

Regenerate them from the repository root with:

```sh
scripts/build-go-native-prebuilt.sh
```

The script currently builds:

- `darwin_arm64/libcalmcss_cgo.a`
- `linux_amd64/libcalmcss_cgo.a`
- `linux_arm64/libcalmcss_cgo.a`
- `windows_amd64/libcalmcss_cgo.a`
- `windows_arm64/libcalmcss_cgo.a`
