#!/bin/bash
# Compiles and runs the hotkey helper's unit tests (macOS with swiftc).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -o "$OUT/gate-tests" \
  "$ROOT/helper/Gate.swift" "$ROOT/helper/Wav.swift" "$ROOT/helper/AppleScriptCall.swift" "$ROOT/helper/KeyLayout.swift" \
  "$ROOT/tests/helper/GateTests.swift"
"$OUT/gate-tests"
