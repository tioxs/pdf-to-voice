#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pdf-voice-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/pdf-to-voice-test-cache" \
  "$ROOT_DIR/PDFToVoice/ReaderModel.swift" "$ROOT_DIR/tests/ReaderChecks.swift" \
  -framework AppKit -framework PDFKit -framework AVFoundation -framework Vision -framework NaturalLanguage \
  -o "$TEST_DIR/reader-checks"
"$TEST_DIR/reader-checks"
