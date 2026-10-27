#!/bin/bash
# Fetch the upstream projects this repository builds on, pinned to the commits
# we validated. Everything lands in ./upstream and is git-ignored.
#
#   scripts/fetch-upstream.sh [--patches-only]
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_A_LIVE=${DATA_A_LIVE:-https://github.com/ShueiTSuki/data-a-live}
PIN=${DATA_A_LIVE_PIN:-81b71b1}     # 0240: GPI DMA I2C, the fuel gauge read

mkdir -p upstream
if [ ! -d upstream/data-a-live/.git ]; then
	git clone --filter=blob:none --no-checkout "$DATA_A_LIVE" upstream/data-a-live
fi
git -C upstream/data-a-live fetch --quiet origin "$PIN" || git -C upstream/data-a-live fetch --quiet origin
git -C upstream/data-a-live checkout --quiet "$PIN"
echo "data-a-live at $(git -C upstream/data-a-live rev-parse --short HEAD)"

if [ "${1:-}" = "--patches-only" ]; then
	echo "patches: $(ls upstream/data-a-live/xnu/patches/*.patch | wc -l) upstream + $(ls xnu/patches/*.patch | wc -l) ours"
	exit 0
fi

for repo in dipa-studio/ios-sweet blacktop/darwin-xnu-build; do
	name=${repo#*/}
	[ -d "upstream/$name/.git" ] || git clone --depth 1 "https://github.com/$repo" "upstream/$name"
	echo "$name at $(git -C upstream/$name rev-parse --short HEAD)"
done
