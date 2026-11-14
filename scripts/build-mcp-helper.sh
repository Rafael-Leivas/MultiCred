#!/bin/bash
# Builds the read-only help MCP server (multicred-mcp) as one universal binary.
#
# Each architecture is built on its own and joined with lipo. A single
# `swift build --arch arm64 --arch x86_64` switches SwiftPM to the Xcode build
# system, which on older toolchains (CI's macos-15) does not generate the
# `PackageResources` of `.embedInCode` resources (the bundled guide).
#
# Usage: scripts/build-mcp-helper.sh <output path>
set -euo pipefail

OUTPUT="${1:?usage: build-mcp-helper.sh <output path>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/MultiCredCore"

SLICES_DIR="$(mktemp -d)"
trap 'rm -rf "$SLICES_DIR"' EXIT
SLICES=()
for ARCH in arm64 x86_64; do
  echo "==> multicred-mcp ($ARCH)"
  # Build errors stay visible (set -e stops here); only the bin path query is quiet.
  swift build -c release --arch "$ARCH" --product multicred-mcp --package-path "$PACKAGE" 2>&1 | tail -n 25
  # Some toolchains use the same bin path for every arch: copy each slice now.
  cp "$(swift build -c release --arch "$ARCH" --show-bin-path --package-path "$PACKAGE")/multicred-mcp" "$SLICES_DIR/multicred-mcp-$ARCH"
  SLICES+=("$SLICES_DIR/multicred-mcp-$ARCH")
done

mkdir -p "$(dirname "$OUTPUT")"
lipo -create "${SLICES[@]}" -output "$OUTPUT"
lipo -info "$OUTPUT"
