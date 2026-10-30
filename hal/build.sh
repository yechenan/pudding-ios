#!/bin/bash
# Build PandoraAudio.driver: an arm64 iOS AudioServerPlugIn bundle that talks to bsd/dev/PandoraAudio.cpp
# instead of going through VirtualAudio. Run on macOS (the CI workflow does).
#
#   bash hal/build.sh            -> out/PandoraAudio.driver
#
# The AudioServerPlugIn headers are not in the iOS SDK; the macOS SDK has them and the ABI is the same. They are
# copied into a local include root (build/inc/CoreAudio) instead of using -F, so the linker keeps using the iOS
# sysroot's frameworks and nothing from the macOS SDK ends up linked in.
set -euo pipefail
cd "$(dirname "$0")/.."

IOS=$(xcrun --sdk iphoneos --show-sdk-path)
MAC=$(xcrun --sdk macosx --show-sdk-path)
echo "== iOS SDK   $IOS"
echo "== macOS SDK $MAC"

SRC=""
for c in \
	"$MAC/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers" \
	"$MAC/System/Library/Frameworks/CoreAudio.framework/Headers" ; do
	if [ -f "$c/AudioServerPlugIn.h" ]; then SRC="$c"; break; fi
done
if [ -z "$SRC" ]; then
	echo "!! AudioServerPlugIn.h not found; searching the macOS SDK:"
	find "$MAC" -name 'AudioServerPlugIn.h' 2>/dev/null | head -5
	exit 1
fi
echo "== CoreAudio headers at $SRC"
ls "$SRC" | head -20

INC=build/inc
rm -rf "$INC"
mkdir -p "$INC/CoreAudio"
cp "$SRC"/*.h "$INC/CoreAudio/"
# keep the framework-style include working for the headers' own siblings
ls "$INC/CoreAudio/AudioServerPlugIn.h"

OUT=out/PandoraAudio.driver
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

clang -bundle \
	-target arm64-apple-ios16.0 \
	-isysroot "$IOS" \
	-I "$INC" \
	-O2 -Wall -Wno-unused-parameter \
	-o "$OUT/Contents/MacOS/PandoraAudio" \
	hal/PandoraAudioPlugin.c \
	-framework CoreFoundation -framework CoreAudio \
	-undefined dynamic_lookup

cp hal/Info.plist "$OUT/Contents/Info.plist"
codesign -f -s - --timestamp=none "$OUT" 2>/dev/null || codesign -f -s - "$OUT"

echo "== built $OUT"
file "$OUT/Contents/MacOS/PandoraAudio"
codesign -dvvv "$OUT" 2>&1 | grep -E "Identifier|CDHash|Signature" || true
