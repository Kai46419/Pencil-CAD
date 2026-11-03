#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${PENCILCAD_TEST_BUILD_DIR:-$PWD/.build/typecheck-ios}"
mkdir -p "$build_dir"
sources=()
while IFS= read -r -d '' file; do
  sources+=("$file")
done < <(find App -type f -name '*.swift' -print0)
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swiftc -typecheck -swift-version 5 -DDEBUG -target arm64-apple-ios17.0-simulator \
  -sdk "$sdk" -module-cache-path "$build_dir/ModuleCache" \
  -import-objc-header App/Kernel/PencilCAD-Bridging-Header.h "${sources[@]}"
printf 'PASS: iOS typecheck (%s Swift files). No linking or runtime test.\n' "${#sources[@]}"
