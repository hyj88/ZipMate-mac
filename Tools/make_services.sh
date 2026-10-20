#!/bin/bash
# 生成 Finder「服务」右键菜单项
set -euo pipefail
APP="$1"
SVC="$APP/Contents/Services"
BIN="$(cd "$(dirname "$APP")/.." && pwd)/ZipMate.app/Contents/MacOS/ZipMate"
EXEC="$(cd "$(dirname "$APP")" && pwd)/ZipMate.app/Contents/MacOS/ZipMate"

mkdir -p "$SVC/压缩为 ZIP.service/Contents/Resources"

cat > "$SVC/压缩为 ZIP.service/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMessage</key>            <string>zipmate_compress_zip</string>
            <key>NSMenuItem</key>           <dict><key>default</key><string>压缩为 ZIP</string></dict>
            <key>NSIconName</key>           <string>ArchiveBox</string>
            <key>NSsendFileTypes</key>      <array><string>public.item</string></array>
        </dict>
    </array>
    <key>CFBundlePackageType</key>       <string>BNDL</string>
    <key>CFBundleIdentifier</key>        <string>com.zipmate.service.zip</string>
    <key>CFBundleName</key>              <string>ZipMateZipService</string>
</dict>
</plist>
PLIST

cat > "$SVC/压缩为 ZIP.service/Contents/Resources/ZipMateZipService.scpt" <<SCPT
on run zipmate_compress_zip(input, parameters)
	set theItems to input
	set outPaths to {}
	repeat with i in theItems
		set end of outPaths to POSIX path of (i as alias)
	end repeat
	set thePath to outPaths as string
	do shell script "$EXEC --quick-compress-zip " & quoted form of thePath
	return ""
end run
SCPT

echo "services -> $SVC"
