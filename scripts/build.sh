#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/PDF to Voice.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pdf-voice-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
ARCHS="${ARCHS:-arm64 x86_64}"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/BuildSupport/Info.plist" "$CONTENTS_DIR/Info.plist"
BINARIES=()
for TARGET_ARCH in ${=ARCHS}; do
  xcrun swiftc -parse-as-library -O -target "${TARGET_ARCH}-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/cache" \
    "$ROOT_DIR"/PDFToVoice/*.swift \
    -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework Vision -framework NaturalLanguage \
    -o "$BUILD_DIR/PDFToVoice-$TARGET_ARCH"
  BINARIES+=("$BUILD_DIR/PDFToVoice-$TARGET_ARCH")
done
xcrun lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/PDFToVoice"
python3 - "$ROOT_DIR/PDFToVoice/Assets.xcassets/AppIcon.appiconset" "$CONTENTS_DIR/Resources/AppIcon.icns" <<'ICON'
import struct, sys
from pathlib import Path
source, output = map(Path, sys.argv[1:])
representations = {"icp4": "icon_16x16.png", "icp5": "icon_32x32.png", "icp6": "icon_32x32@2x.png", "ic07": "icon_128x128.png", "ic08": "icon_256x256.png", "ic09": "icon_512x512.png", "ic10": "icon_512x512@2x.png", "ic11": "icon_16x16@2x.png", "ic12": "icon_32x32@2x.png", "ic13": "icon_128x128@2x.png", "ic14": "icon_256x256@2x.png"}
chunks = []
for kind, name in representations.items():
    data = (source / name).read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
ICON
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/PDFToVoice/PDFToVoice.entitlements" "$APP_DIR"
else
  codesign --force --sign - --entitlements "$ROOT_DIR/PDFToVoice/PDFToVoice.entitlements" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGNING_IDENTITY:-}" ]] || { print -u2 'Notarization requires SIGNING_IDENTITY.'; exit 1; }
  ditto -c -k --keepParent "$APP_DIR" "$BUILD_DIR/notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
fi
ditto -c -k --keepParent "$APP_DIR" "$ROOT_DIR/dist/PDF-to-Voice.zip"
print "$APP_DIR"
