#!/bin/bash
# 获取并内置 7-Zip（官方 macOS 版），使 app 开箱即支持 RAR / ISO / CAB 等
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
SEVEN_VER="${SEVEN_VER:-2301}"
SEVEN_URL="https://www.7-zip.org/a/7z${SEVEN_VER}-mac.tar.xz"
TARGET="$VENDOR/7zz"

mkdir -p "$VENDOR"

if [ -x "$TARGET" ]; then
  echo "7-Zip 已存在：$TARGET"
  exit 0
fi

echo "==> 下载 7-Zip ${SEVEN_VER} (官方 macOS 版)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --max-time 300 -o "$TMP/7z.tar.xz" "$SEVEN_URL"
echo "   下载完成 $(du -h "$TMP/7z.tar.xz" | cut -f1)"

tar -xf "$TMP/7z.tar.xz" -C "$TMP"
[ -f "$TMP/7zz" ] || { echo "❌ 压缩包内未找到 7zz"; exit 1; }

install -m 755 "$TMP/7zz" "$TARGET"

# 保留官方许可声明（LGPL + BSD，捆绑分发必须附带）
for F in License.txt readme.txt; do
  [ -f "$TMP/$F" ] && cp "$TMP/$F" "$VENDOR/7zip-$F"
done

echo "==> 已内置：$TARGET"
"$TARGET" 2>&1 | head -1 || true
echo "   格式支持："
"$TARGET" i 2>/dev/null | grep -E "^\s+\.\.\.\S+\s+\d*\s*\d*\s*(Rar|Zip|7z|Cab|Iso)" | head -6 || true
