#!/bin/bash
# Build PandoraAudio.driver: an arm64 iOS AudioServerPlugIn bundle that talks to bsd/dev/PandoraAudio.cpp
# instead of going through VirtualAudio. Run on macOS (the CI workflow does).
#
#   bash hal/build.sh            -> out/PandoraAudio.driver
#
# The AudioServerPlugIn headers are not part of the iOS SDK; the macOS SDK has them and the ABI is the same,
# so the iOS sysroot gets the macOS CoreAudio headers on the include path.
set -euo pipefail
cd "$(dirname "$0")/.."

IOS=$(xcrun --sdk iphoneos --show-sdk-path)
MAC=$(xcrun --sdk macosx --show-sdk-path)
CA="$MAC/System/Library/Frameworks/CoreAudio.framework/Headers"

OUT=out/PandoraAudio.driver
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

clang -bundle \
	-target arm64-apple-ios16.0 \
	-isysroot "$IOS" \
	-I "$CA" \
	-I "$MAC/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers" \
	-O2 -Wall -Wno-unused-parameter \
	-o "$OUT/Contents/MacOS/PandoraAudio" \
	hal/PandoraAudioPlugin.c \
	-framework CoreFoundation -framework CoreAudio \
	-undefined dynamic_lookup

cp hal/Info.plist "$OUT/Contents/Info.plist"
# ad-hoc: the phone needs the CDHash in its trust cache (tools/addtrustcache.py), not a real certificate
codesign -f -s - --timestamp=none "$OUT" 2>/dev/null || codesign -f -s - "$OUT"

echo "== built $OUT"
file "$OUT/Contents/MacOS/PandoraAudio"
codesign -dvvv "$OUT" 2>&1 | grep -E "Identifier|CDHash|Signature" || true
lipo -info "$OUT/Contents/MacOS/PandoraAudio" || true
