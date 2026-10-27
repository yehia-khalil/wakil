#!/usr/bin/env bash
# Assembles an unsigned Wakil.app from the SwiftPM product. Xcode is not
# required and is not used: 2a needs no shader compilation, signing or
# entitlements. Those arrive with 2b.
#
# THE RESOURCES DIRECTORY IS LOAD-BEARING. WakilWiring.binaryURL resolves a
# Go binary at <executable dir>/../Resources/<name> when it is running from a
# bundle, and it has NO fallback there: its checkout-marker walk stops at the
# first ancestor holding a go.mod or an app/Package.swift, and an installed
# Wakil.app has neither, so a binary missing from Contents/Resources is a
# binary the app cannot find at all. The bundle must be self-contained. A
# Swift test (AppWiringTests.binaryResolutionFindsTheBundleLayout) pins the
# resolution side of that contract, and a Go test (scripts/app_bundle_test.go)
# pins this script's side by running it against a fake toolchain.
#
# Five of the six are the MCP servers. `wakil` — the operator CLI — is here
# too, and was NOT until 2026-09-24, on the premise that "nothing in the app
# spawns it". That premise was false when it was written: `WindowSession`
# resolves `wakil` through `WakilWiring.binaryURL` and runs
# `wakil provider credentials` for every harness it builds, so a bundle
# without it opens every window with "no agent session: wakil binary not
# found".
#
# It went unseen because the resolution order hides it in a checkout: Resources
# first, then the checkout root's bin/. An `app/Wakil.app` run from this
# repository finds bin/wakil by the second route and works; the same bundle
# moved anywhere else has no agent at all. The e2e harness found it the first
# time a check drove the agent against a STAGED bundle, which is the only
# configuration in this repo that is outside the checkout.
#
# The objection this replaces is worth keeping in view: bundling the CLI ships
# a second entry point into the same data with none of the registry's
# journalling. That is a real cost, and the answer is not to omit a binary the
# app requires — it is that Contents/Resources is not on anyone's PATH, so it
# is not an entry point anybody reaches by typing.
#
# THE SAME CONTRACT NOW COVERS THE SWIFTPM RESOURCE BUNDLE. Since 2b-ii Task
# 2, WakilApp has its first SwiftPM resource — default.metallib, `.copy`'d
# into a generated Wakil_WakilApp.bundle — and VoidView.Coordinator loads it
# through `Bundle.module`, which has no fallback once it is out of a
# checkout either: it falls straight to a `fatalError`. SwiftPM's generated
# accessor looks for that bundle at
# `Bundle.main.bundleURL.appendingPathComponent("Wakil_WakilApp.bundle")`,
# and for a real macOS app bundle opened by LaunchServices,
# `Bundle.main.bundleURL` is the .app directory itself — NOT
# Contents/Resources, which is `Bundle.main.resourceURL` instead. So
# Wakil_WakilApp.bundle belongs at the top level of Wakil.app, a sibling of
# Contents, not inside Contents/Resources with the Go binaries. Confirmed by
# running the assembled binary directly with the resource bundle in each
# location: Contents/Resources produced `Fatal error: could not load
# resource bundle`, and the top level did not.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
APP="app/Wakil.app"
swift build --package-path app -c "$CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# app/.build/debug is a symlink to app/.build/arm64-apple-macosx/debug; cp
# follows it, so the path below resolves for both configurations without
# naming the architecture.
cp "app/.build/$CONFIG/WakilApp" "$APP/Contents/MacOS/Wakil"
for b in wakil wakil-ctx wakil-db wakil-git wakil-http wakil-pm wakil-recall wakil-files; do
  cp "bin/$b" "$APP/Contents/Resources/$b"
done
# See the header comment: this goes at the top level of $APP, not inside
# Contents/Resources — that is where Bundle.module actually looks. `cp -R`
# on a missing source fails under `set -euo pipefail`, the same way a
# missing Go binary above already fails this script rather than producing a
# bundle that looks complete.
cp -R "app/.build/$CONFIG/Wakil_WakilApp.bundle" "$APP/Wakil_WakilApp.bundle"
# **The drag row's type is exported here** (2c-iv, #308): `UTType(exportedAs:)` in
# DataSurface.swift names `com.wakil.drag-row`, and an exported type the bundle does not
# declare is one the system cannot look up — the grid-row drag's payload would travel under
# a type nothing registered.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Wakil</string>
  <key>CFBundleIdentifier</key><string>dev.wakil.app</string>
  <key>CFBundleExecutable</key><string>Wakil</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2a</string>
  <key>NSCameraUsageDescription</key><string>A web page in Wakil's browser asked to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Wakil listens while you hold ⌥, and when a web page in its browser asks and you allow it. Audio for speech never leaves this Mac.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
  <key>NSSpeechRecognitionUsageDescription</key><string>Wakil turns what you say while holding ⌥ into text, on this Mac.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.wakil.drag-row</string>
    <key>UTTypeDescription</key><string>A Wakil database row, being dragged</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
</dict></plist>
PLIST
echo "built $APP"
