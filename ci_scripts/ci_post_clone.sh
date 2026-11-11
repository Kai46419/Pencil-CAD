#!/usr/bin/env bash
# Xcode Cloud: läuft direkt nach dem Klonen, vor dem Build (Apple sucht ci_scripts neben PencilCAD.xcodeproj).
# Holt die Bibliotheken, die nicht eingecheckt sind (Vendor/), und erzeugt das Projekt mit XcodeGen neu.
set -euo pipefail
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

# Vorgebaute Bibliotheken aus dem GitHub-Release „vendor“; was dort fehlt, wird hier gebaut (dauert deutlich länger)
if ! bash scripts/vendor-release.sh fetch; then
  if [ ! -d Vendor/OCCT.xcframework ]; then
    echo "OpenCASCADE wird in Xcode Cloud gebaut – mit „bash scripts/vendor-release.sh publish“ am Mac geht es künftig schneller."
    command -v cmake >/dev/null 2>&1 || brew install cmake
    bash scripts/build-occt-ios.sh
  fi
  if [ ! -d Vendor/PencilSheet.xcframework ]; then
    echo "Blechmodul wird in Xcode Cloud gebaut – mit „bash scripts/vendor-release.sh publish“ am Mac geht es künftig schneller."
    bash scripts/build-sheet-ios.sh
  fi
fi

# „Build N“ liest generate-project.sh aus den letzten Commit-Titeln – bei flachem Klon etwas Verlauf nachholen
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  git fetch --quiet --deepen=200 || true
fi

# CFBundleVersion = laufende Xcode-Cloud-Nummer (steigt mit jedem Build, wie TestFlight es verlangt).
# Die Nummer „Build N“ aus dem Commit-Titel steht weiter im Startbildschirm (App/BuildInfo.txt).
export PENCILCAD_BUNDLE_VERSION="${CI_BUILD_NUMBER:-1}"
bash scripts/generate-project.sh
