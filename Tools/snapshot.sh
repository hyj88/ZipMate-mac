#!/bin/bash
# 离屏渲染 UI 快照 —— 不需要屏幕录制权限，可用于 CI
# 用法：./Tools/snapshot.sh [输出目录]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/Screenshots}"
mkdir -p "$OUT"

DEV=""
for d in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  [ -d "$d/Contents/Developer" ] && DEV="$d/Contents/Developer" && break
done
[ -z "$DEV" ] && { echo "❌ 需要完整 Xcode（SwiftUI 宏插件）"; exit 1; }

SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
PLUG="$DEV/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
BIN="$ROOT/.build/shotter"

mkdir -p "$ROOT/.build"

echo "==> 编译快照工具"
"$SWIFTC" -O -swift-version 5 -sdk "$SDK" \
  -load-plugin-library "$PLUG" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  -o "$BIN" \
  "$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/UI/*.swift "$ROOT/Tools/snapshot/main.swift"

echo "==> 渲染"
"$BIN" "$OUT"
echo "✅ 截图已保存到 $OUT"
