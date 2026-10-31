#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 3 ]]; then
  echo "用法: bash Tests/gpu-smoke.sh 输入视频 LUT.cube|--hdr 输出.mp4" >&2
  exit 2
fi
bash build.sh
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ ! -d "$SDK" ]]; then SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -swift-version 6 -O -target arm64-apple-macosx15.0 -sdk "$SDK" \
  -module-cache-path "$PWD/.build/module-cache" \
  -framework AVFoundation -framework Metal -framework CoreVideo -framework VideoToolbox \
  Sources/MetalLUTExporter.swift Sources/ProcessRunner.swift Tests/GPUSmoke.swift \
  -o dist/DLogGrader.app/Contents/MacOS/GPUTest
"$PWD/dist/DLogGrader.app/Contents/MacOS/GPUTest" "$1" "$3" "$2" /opt/homebrew/bin/ffmpeg
probe=$(/opt/homebrew/bin/ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,pix_fmt,width,height,r_frame_rate,color_primaries,color_transfer,color_space -of default=noprint_wrappers=1 "$3")
printf '%s\n' "$probe"
if [[ "$2" == "--hdr" ]]; then
  [[ "$probe" == *"color_primaries=bt2020"* && "$probe" == *"color_transfer=arib-std-b67"* && "$probe" == *"color_space=bt2020nc"* ]] || {
    echo "HDR 色彩标签不正确" >&2
    exit 1
  }
fi
