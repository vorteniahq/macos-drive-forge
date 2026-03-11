#!/bin/zsh
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJ"
if [[ ! -f "$PROJ/.build/release/FlashForge" ]]; then
  swift build -c release
  cp .build/release/FlashForge dist/FlashForge.app/Contents/MacOS/FlashForge
fi
open "$PROJ/dist/FlashForge.app"
