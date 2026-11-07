#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mivo-floating-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Keep production window types; replace only the application's entry point.
python3 - "$ROOT/Sources/HoldApp.swift" "$TEST_DIR/HoldApp.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index('@main\nstruct HoldMenuApp: App {')
end = source.index('struct OpenSettingsCommand: View {', start)
Path(sys.argv[2]).write_text(source[:start] + source[end:])
PY
swiftc -parse-as-library \
  -framework SwiftUI -framework AppKit -framework ApplicationServices \
  -framework CoreGraphics -framework IOKit \
  "$TEST_DIR/HoldApp.swift" "$ROOT/Tests/FloatingActionTests.swift" \
  -o "$TEST_DIR/FloatingActionTests"
"$TEST_DIR/FloatingActionTests"
