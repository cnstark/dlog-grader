#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/DLogGrader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ ! -d "$SDK" ]]; then SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -swift-version 6 -O -target arm64-apple-macosx15.0 -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework ServiceManagement -framework AVFoundation -framework Metal -framework CoreVideo -framework VideoToolbox -lsqlite3 \
  Sources/*.swift -o "$APP/Contents/MacOS/DLogGrader"

if xcrun --find metal >/dev/null 2>&1 && xcrun --find metallib >/dev/null 2>&1; then
  for shader in LUTKernel HDRKernel; do
    xcrun metal -c "Sources/$shader.metal" -o ".build/$shader.air"
    xcrun metallib ".build/$shader.air" -o "$APP/Contents/Resources/$shader.metallib"
  done
else
  # Command Line Tools installations may omit Metal's offline compiler.
  # The app compiles this bundled shader source through MTLDevice.makeLibrary(source:).
  cp Sources/LUTKernel.metal Sources/HDRKernel.metal "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DLogGrader</string>
  <key>CFBundleDisplayName</key><string>DLogGrader</string>
  <key>CFBundleIdentifier</key><string>com.dloggrader.app</string>
  <key>CFBundleExecutable</key><string>DLogGrader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "已生成 $APP"
