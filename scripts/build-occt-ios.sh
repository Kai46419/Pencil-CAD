#!/usr/bin/env bash
# Baut OpenCASCADE als statische Bibliothek für iPad (Gerät + Simulator, arm64)
# und packt sie nach Vendor/OCCT.xcframework.
#
# Voraussetzungen: Xcode, cmake (brew install cmake), git.
# Gebaut werden nur die Module FoundationClasses, ModelingData und ModelingAlgorithms.
# DataExchange (STEP) folgt in Phase 3, Visualization brauchen wir nicht (eigener Metal-Renderer).
set -euo pipefail

OCCT_TAG="${OCCT_TAG:-V7_8_1}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-17.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/occt"
SRC="$WORK/src"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK" "$ROOT/Vendor"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

build_platform() {
  local sdk="$1" name="$2"
  local build_dir="$WORK/build-$name"
  local install_dir="$WORK/install-$name"

  cmake -S "$SRC" -B "$build_dir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_LIBRARY_TYPE=Static \
    -DINSTALL_DIR="$install_dir" \
    -DBUILD_MODULE_FoundationClasses=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF \
    -DBUILD_MODULE_DataExchange=OFF \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_DOC_Overview=OFF \
    -DUSE_FREETYPE=OFF \
    -DUSE_TK=OFF

  cmake --build "$build_dir" --config Release --parallel "$JOBS"
  cmake --install "$build_dir" --config Release

  # Alle Teilbibliotheken zu einer libOCCT.a zusammenfassen
  local libs
  libs=$(find "$install_dir" -name "libTK*.a")
  libtool -static -o "$install_dir/libOCCT.a" $libs
}

build_platform iphoneos device
build_platform iphonesimulator simulator

HEADERS_DEVICE="$(dirname "$(find "$WORK/install-device" -name Standard_Macro.hxx | head -n1)")"
HEADERS_SIM="$(dirname "$(find "$WORK/install-simulator" -name Standard_Macro.hxx | head -n1)")"

rm -rf "$ROOT/Vendor/OCCT.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/install-device/libOCCT.a" -headers "$HEADERS_DEVICE" \
  -library "$WORK/install-simulator/libOCCT.a" -headers "$HEADERS_SIM" \
  -output "$ROOT/Vendor/OCCT.xcframework"

echo "Fertig: Vendor/OCCT.xcframework"
echo "Jetzt ./scripts/generate-project.sh ausführen."
