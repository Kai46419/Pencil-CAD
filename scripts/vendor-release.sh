#!/usr/bin/env bash
# Vorgebaute Bibliotheken (Vendor/OCCT.xcframework, Vendor/PencilSheet.xcframework) als Anhänge des
# GitHub-Release „vendor“ ablegen bzw. von dort holen. Vendor/ ist nicht eingecheckt (zu groß); Xcode Cloud
# holt die Bibliotheken so in Sekunden, statt OpenCASCADE und das Blechmodul bei jedem Build neu zu bauen.
#
#   bash scripts/vendor-release.sh names     Dateinamen zum aktuellen Stand ausgeben
#   bash scripts/vendor-release.sh fetch     fehlende Bibliotheken herunterladen (Rückgabe 1, wenn eine fehlt)
#   bash scripts/vendor-release.sh publish   lokale Bibliotheken hochladen (braucht gh, öffentlich sichtbar)
#
# Das Blechmodul trägt einen Fingerabdruck der eingecheckten SheetKit-Quellen im Namen: ändert sich SheetKit,
# passt der alte Anhang nicht mehr und muss neu veröffentlicht werden (sonst baut Xcode Cloud es selbst).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${PENCILCAD_VENDOR_REPO:-Kai46419/Pencil-CAD}"
TAG=vendor
occt_tag="$(sed -n 's/^OCCT_TAG="\${OCCT_TAG:-\(.*\)}"$/\1/p' scripts/build-occt-ios.sh)"
sheet_print="$(git ls-files -s SheetKit | git hash-object --stdin | cut -c1-12)"
occt_zip="OCCT-${occt_tag}.xcframework.zip"
sheet_zip="PencilSheet-${sheet_print}.xcframework.zip"

fetch_one() {
  local zip="$1" dir="$2"
  if [ -d "Vendor/$dir" ]; then echo "Vendor/$dir ist schon da."; return 0; fi
  mkdir -p Vendor build
  echo "Lade $zip …"
  if ! curl -fsSL --retry 3 -o "build/$zip" "https://github.com/$REPO/releases/download/$TAG/$zip"; then
    echo "Nicht im Release „$TAG“: $zip"; rm -f "build/$zip"; return 1
  fi
  ditto -x -k "build/$zip" Vendor
  rm -f "build/$zip"
  [ -d "Vendor/$dir" ] || { echo "FEHLER: $zip enthält kein $dir"; return 1; }
}

case "${1:-}" in
  names)
    echo "$occt_zip"; echo "$sheet_zip" ;;
  fetch)
    missing=0
    fetch_one "$occt_zip" OCCT.xcframework || missing=1
    fetch_one "$sheet_zip" PencilSheet.xcframework || missing=1
    exit "$missing" ;;
  publish)
    command -v gh >/dev/null || { echo 'FEHLER: gh fehlt (brew install gh).'; exit 2; }
    [ -d Vendor/OCCT.xcframework ] && [ -d Vendor/PencilSheet.xcframework ] || { echo 'FEHLER: Vendor ist unvollständig.'; exit 2; }
    [ -z "$(git status --porcelain SheetKit)" ] || { echo 'FEHLER: SheetKit hat nicht eingecheckte Änderungen – erst committen.'; exit 2; }
    if [ -n "$(find SheetKit/src SheetKit/include SheetKit/Cargo.toml SheetKit/Cargo.lock -newer Vendor/PencilSheet.xcframework -print -quit 2>/dev/null)" ]; then
      echo 'FEHLER: SheetKit ist neuer als Vendor/PencilSheet.xcframework – erst ./scripts/build-sheet-ios.sh ausführen.'; exit 2
    fi
    mkdir -p build/vendor-release
    for pair in "$occt_zip:OCCT.xcframework" "$sheet_zip:PencilSheet.xcframework"; do
      zip="${pair%%:*}"; dir="${pair#*:}"
      echo "Packe $zip …"
      rm -f "build/vendor-release/$zip"
      ditto -c -k --keepParent "Vendor/$dir" "build/vendor-release/$zip"
    done
    if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
      gh release create "$TAG" --repo "$REPO" --title "Vorgebaute Bibliotheken" --latest=false \
        --notes "Vorgebaute Bibliotheken für Xcode Cloud (siehe scripts/vendor-release.sh): OpenCASCADE (LGPL 2.1 mit Ausnahme, Quellen: github.com/Open-Cascade-SAS/OCCT, gebaut mit scripts/build-occt-ios.sh) und das Blechmodul aus SheetKit (SolidCraft-Engine, MIT). Lizenzhinweise: App/Resources/ThirdPartyNotices.txt."
    fi
    gh release upload "$TAG" --repo "$REPO" --clobber "build/vendor-release/$occt_zip" "build/vendor-release/$sheet_zip"
    echo "Veröffentlicht: $occt_zip, $sheet_zip" ;;
  *)
    echo "Aufruf: bash scripts/vendor-release.sh names|fetch|publish"; exit 2 ;;
esac
