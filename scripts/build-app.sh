#!/bin/bash
# リリースビルドして Mado.app を組み立てる
# UNIVERSAL=1 で arm64 + x86_64 の universal binary を作る(CI 用)
# VERSION=x.y.z で Info.plist のバージョンを指定(CI ではタグから注入。未指定は 0.0.0-dev)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BUILD_DIR=".build/apple/Products/Release"
else
    swift build -c release
    BUILD_DIR=".build/release"
fi

APP="build/Mado.app"
BIN="$BUILD_DIR/Mado"
BUNDLE="$BUILD_DIR/Mado_Mado.bundle"
# SearchCore の e5 CoreML モデル/トークナイザを含むリソースバンドル
CORE_BUNDLE="$BUILD_DIR/Mado_SearchCore.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Mado"
cp -R "$BUNDLE" "$APP/Contents/Resources/"
# SearchCore のリソース(意味検索モデル)も同梱。無いと e5 が読めず NLEmbedding に退化する。
if [ -d "$CORE_BUNDLE" ]; then
    cp -R "$CORE_BUNDLE" "$APP/Contents/Resources/"
else
    echo "WARN: $CORE_BUNDLE が見つからない(意味検索が NLEmbedding にフォールバックします)"
fi

# アプリアイコン: assets/icon-1024.png から .icns を生成
ICON_SRC="assets/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
        d=$((s * 2))
        sips -z "$d" "$d" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mado</string>
    <key>CFBundleDisplayName</key><string>Mado</string>
    <key>CFBundleIdentifier</key><string>dev.takeshita.mado</string>
    <key>CFBundleExecutable</key><string>Mado</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Install: cp -R $APP /Applications/"
