package main

import (
	"path/filepath"
	"strings"

	Const "github.com/metacubex/mihomo/constant"
)

// 订阅校验会把 file / http 类 proxy-provider 与 rule-provider 的 path 在内存里改写成
// <workDir>/<subpath> 的绝对路径（fetch.go 的 patchProvidersPath），让 ParseRawConfig 读到预取的文件。
// workDir 有两种来源：
//   - 导入 / 更新订阅：files/mihomo/processing（单例沙箱，含 proxies/、rules/、providers/ 或自定义相对路径）；
//   - 编辑器保存 / 变换校验：files/mihomo/imported/<uuid> 或 runtime/<uuid>。
// 它们都在 geodata（mihomo 的 home dir）之外。上游构建带 cmfa tag 时 IsSafePath 直接放行；
// 本定制去掉了 cmfa，于是这些路径都会报 "path is not subpath of home directory or SAFE_PATHS"。
// 这里只放行 processing/、imported/<uuid>/、runtime/<uuid>/ 沙箱内的子路径，目录本身及 .. 穿越仍然拒绝。
// 写回磁盘的 config.yaml 仍是相对路径，运行时由 mihomo 按 home dir 解析，不受影响。
func init() {
	Const.ExtraSafePathFunc = isValidationProvidersPath
}

func isValidationProvidersPath(path string) bool {
	home := Const.Path.HomeDir()
	if home == "" {
		return false
	}
	// home 是 files/mihomo/geodata，processing/、imported/、runtime/ 同在 files/mihomo/ 下
	root := filepath.Dir(home)
	rel, err := filepath.Rel(root, filepath.Clean(path))
	if err != nil || !filepath.IsLocal(rel) {
		return false
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	switch {
	case len(parts) >= 2 && parts[0] == "processing":
		// processing/<subpath>（如 proxies/<hash>、rules/<hash>、providers/<file> 或自定义相对路径）
		return true
	case len(parts) >= 3 && (parts[0] == "imported" || parts[0] == "runtime") && parts[1] != "":
		// imported/<uuid>/<subpath> 或 runtime/<uuid>/<subpath>
		return true
	}
	return false
}
