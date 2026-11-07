#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mivo-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile the production model without launching the SwiftUI application lifecycle.
sed '/^struct LogPanelView: View/,$d' "$ROOT/Sources/HoldApp.swift" > "$TEST_DIR/HoldModel.swift"
swiftc -parse-as-library \
  -framework SwiftUI -framework AppKit -framework ApplicationServices \
  -framework CoreGraphics -framework IOKit \
  "$TEST_DIR/HoldModel.swift" "$ROOT/Tests/HoldModelTests.swift" \
  -o "$TEST_DIR/HoldModelTests"
"$TEST_DIR/HoldModelTests"
