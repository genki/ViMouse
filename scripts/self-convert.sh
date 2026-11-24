#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT/build/cli"
BIN="$BUILD_DIR/self-convert"

mkdir -p "$BUILD_DIR"

if [ ! -x "$BIN" ] || [ "$ROOT/Tools/SelfConvertCLI.swift" -nt "$BIN" ] || [ "$ROOT/ViMouse/JapaneseConversion.swift" -nt "$BIN" ] || [ "$ROOT/ViMouse/SelfConversionSettings.swift" -nt "$BIN" ]; then
  xcrun swiftc \
    "$ROOT/ViMouse/InputHook.swift" \
    "$ROOT/ViMouse/SelfConversionSettings.swift" \
    "$ROOT/ViMouse/JapaneseConversion.swift" \
    "$ROOT/Tools/SelfConvertCLI.swift" \
    -o "$BIN"
fi

exec "$BIN" "$@"
