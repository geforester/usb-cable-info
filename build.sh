#!/bin/bash
# Собирает «USB Cable.app» в /Applications и CLI-симлинк в ~/.local/bin.
# Разрешений (TCC) чтение IORegistry не требует, поэтому хватает ad-hoc подписи.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/USB Cable.app"
BIN_DIR="$HOME/.local/bin"
EXE=usb-cable
ID=com.geforester.usb-cable

mkdir -p "$APP/Contents/MacOS" "$BIN_DIR"

echo "==> Компиляция"
swiftc -O -framework AppKit \
    -o "$APP/Contents/MacOS/$EXE" "$ROOT/src/main.swift"

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$EXE</string>
    <key>CFBundleIdentifier</key>          <string>$ID</string>
    <key>CFBundleName</key>                <string>USB Cable</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <!-- Только иконка в строке меню, без дока. -->
    <key>LSUIElement</key>                 <true/>
</dict>
</plist>
PLISTEOF

codesign --force --sign - --identifier "$ID" "$APP"
ln -sf "$APP/Contents/MacOS/$EXE" "$BIN_DIR/$EXE"

echo "==> Готово: $APP"
echo "    cli: $BIN_DIR/$EXE --once"
