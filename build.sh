#!/bin/bash
# 构建 ZipMate.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
APP="$ROOT/dist/ZipMate.app"

echo "==> 清理"
rm -rf "$BUILD" "$ROOT/dist"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 准备 7-Zip（内置以支持 RAR/ISO/CAB）"
"$ROOT/Tools/fetch_7zip.sh"

echo "==> 编译"
# 优先使用完整 Xcode（含 SwiftUI 宏插件），回退到 CommandLineTools
DEV=""
for d in /Applications/Xcode.app /Applications/Xcode-beta.app \
         /Applications/Xcode-16.app /Applications/Xcode-15.app; do
  if [ -x "$d/Contents/Developer/usr/bin/swiftc" ] || [ -x "$d/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    DEV="$d/Contents/Developer"; break
  fi
done

SWIFTC="xcrun swiftc"
SDK="$(xcrun --show-sdk-path)"
MACOS_PLUGIN="-load-plugin-library $DEV/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"

if [ -n "$DEV" ] && [ -f "$DEV/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  echo "   使用 Xcode SDK：$DEV"
  SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
  echo "   使用 CommandLineTools SDK"
  MACOS_PLUGIN=""
fi

"$SWIFTC" -O -swift-version 5 \
  -sdk "$SDK" \
  $MACOS_PLUGIN \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/ZipMate" \
  "$ROOT"/Sources/Core/*.swift \
  "$ROOT"/Sources/UI/*.swift \
  "$ROOT"/Sources/App/*.swift

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>ZipMate</string>
    <key>CFBundleDisplayName</key>           <string>ZipMate 压缩大师</string>
    <key>CFBundleExecutable</key>            <string>ZipMate</string>
    <key>CFBundleIdentifier</key>            <string>com.zipmate.app</string>
    <key>CFBundleVersion</key>               <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>    <string>1.0.0</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>ApplePersistenceIgnoreState</key>    <true/>
    <key>LSUIElement</key>                   <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>压缩包 / 归档</string>
            <key>CFBundleTypeRole</key>      <string>Editor</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>org.gnu.gnu-zip-tar-gzip</string>
                <string>org.gnu.bzip2-archive</string>
                <string>org.tukaani.xz-archive</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>zip</string><string>7z</string><string>rar</string>
                <string>tar</string><string>gz</string><string>gzip</string>
                <string>bz2</string><string>bzip2</string><string>xz</string>
                <string>zst</string><string>zstd</string>
                <string>tgz</string><string>tbz</string><string>tbz2</string>
                <string>txz</string><string>tzst</string>
            </array>
        </dict>
    </array>
    <key>NSAppleEventsUsageDescription</key>
    <string>ZipMate 需要读取 Finder 中选中的文件以便一键压缩。</string>
</dict>
</plist>
PLIST

echo "==> 内置 7-Zip 到 Contents/Helpers"
mkdir -p "$APP/Contents/Helpers"
install -m 755 "$ROOT/vendor/7zz" "$APP/Contents/Helpers/7zz"
cp "$ROOT"/vendor/7zip-*.txt "$APP/Contents/Helpers/" 2>/dev/null || true
# 剥离 7zz 的签名（嵌套可执行文件需与外层 app 一起签名）
codesign --remove-signature "$APP/Contents/Helpers/7zz" 2>/dev/null || true
echo "   7zz: $(du -h "$APP/Contents/Helpers/7zz" | cut -f1)"

echo "==> 生成图标"
python3 "$ROOT/Tools/make_icon.py" "$APP/Contents/Resources/AppIcon.icns" || echo "  (图标生成失败，使用系统默认)"

echo "==> 生成 Finder 服务菜单"
"$ROOT/Tools/make_services.sh" "$APP" || echo "  (服务菜单生成失败，不影响主功能)"

echo "==> 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (未签名，首次打开可能需右键打开)"

echo "==> 注册 LaunchServices"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" || true

echo ""
echo "✅ 构建完成：$APP"
echo "   运行：open \"$APP\""
