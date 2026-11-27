#!/usr/bin/env bash
# Build the single shipping artifact: the arm64-v8a release APK.
# No debug/profile build, no other ABI, no other flavor is produced.
set -euo pipefail
cd "$(dirname "$0")"

flutter build apk --release --flavor play -t lib/main_cloud.dart \
  --split-per-abi --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/symbols

echo "APK: build/app/outputs/flutter-apk/app-arm64-v8a-play-release.apk"
echo "symbols: build/symbols (keep them to symbolicate crash reports)"
