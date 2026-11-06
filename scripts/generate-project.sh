#!/usr/bin/env bash
# Erzeugt PencilCAD.xcodeproj mit XcodeGen (brew install xcodegen).
# Mit OpenCASCADE, wenn Vendor/OCCT.xcframework existiert, sonst im Fallback-Modus.
set -euo pipefail
cd "$(dirname "$0")/.."

open_project=false
case "${1:-}" in
  "") ;;
  --open) open_project=true ;;
  *) echo "Aufruf: bash scripts/generate-project.sh [--open]"; exit 2 ;;
esac
command -v xcodegen >/dev/null || { echo 'FEHLER: XcodeGen fehlt (brew install xcodegen).'; exit 2; }

# Signierung: Team und Bundle-ID überleben so das Neuerzeugen des Projekts.
# Eigene Werte optional in signing.env (nicht eingecheckt):
#   PENCILCAD_TEAM=ABCDE12345
#   PENCILCAD_BUNDLE_ID=de.meinname.pencilcad
if [ -f signing.env ]; then
  set -a; . ./signing.env; set +a
fi
if [[ -z "${PENCILCAD_TEAM:-}" && -f PencilCAD.xcodeproj/project.pbxproj ]]; then
  PENCILCAD_TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);/\1/p' PencilCAD.xcodeproj/project.pbxproj | head -n1)"
fi
if [ -z "${PENCILCAD_TEAM:-}" ]; then
  # Team-ID aus dem Apple-Development-Zertifikat im Schlüsselbund lesen (entsteht, sobald Xcode einmal signiert hat)
  PENCILCAD_TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | head -n1 || true)"
fi
export PENCILCAD_TEAM="${PENCILCAD_TEAM:-}"
export PENCILCAD_BUNDLE_ID="${PENCILCAD_BUNDLE_ID:-de.kai46419.pencilcad}"
if [ -n "$PENCILCAD_TEAM" ]; then
  echo "Signierung: Team $PENCILCAD_TEAM, Bundle-ID $PENCILCAD_BUNDLE_ID"
else
  echo "Signierung: kein Team gefunden. Für ein echtes iPad einmal in Xcode unter Signing & Capabilities"
  echo "ein Team wählen und dieses Skript erneut starten (oder PENCILCAD_TEAM in signing.env eintragen)."
fi

# Versionsnummer für den Startbildschirm: Build = Nummer aus dem letzten Commit-Titel „Build N: …“
# (Kai: gleiche Nummer wie in den Nachrichten), ohne solchen Titel die Anzahl der Commits; dazu Commit und Datum
export PENCILCAD_BUILD="${PENCILCAD_BUILD:-7}"
build_info="$(cat App/BuildInfo.txt 2>/dev/null || true)"
if [[ -e .git ]]; then
  titled="$(git log -200 --format=%s 2>/dev/null | grep -m1 -oE '^Build [0-9]+' | grep -oE '[0-9]+' || true)"
  export PENCILCAD_BUILD="${titled:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
  build_info="$(git log -1 --format='%h · %cd' --date=format:'%d.%m.%Y %H:%M' 2>/dev/null || true)"
  printf '%s\n' "${build_info:-unbekannter Stand}" > App/BuildInfo.txt
fi
echo "Version: Build $PENCILCAD_BUILD (${build_info:-ohne Git})"

if [ -d Vendor/OCCT.xcframework ]; then
  # Blechmodul (SheetKit): nur einbinden, wenn das xcframework gebaut ist – nie automatisch bauen
  if [ -d Vendor/PencilSheet.xcframework ]; then
    echo "OpenCASCADE und Blechmodul gefunden – Projekt mit Kernel und Blech."
    # Hinweis, wenn die Rust-Quellen neuer sind als das gebaute Modul
    if [ -n "$(find SheetKit/src SheetKit/include SheetKit/Cargo.toml SheetKit/Cargo.lock -newer Vendor/PencilSheet.xcframework -print -quit 2>/dev/null)" ]; then
      echo "Hinweis: SheetKit wurde seit dem letzten Bau geändert – ./scripts/build-sheet-ios.sh erneut ausführen."
    fi
    xcodegen generate --spec project-occt-sheet.yml
  else
    echo "OpenCASCADE gefunden – Projekt mit Kernel (ohne Blechmodul)."
    echo "Blechmodul: ./scripts/build-sheet-ios.sh ausführen, danach dieses Skript erneut starten."
    xcodegen generate --spec project-occt.yml
  fi
else
  echo "Kein Vendor/OCCT.xcframework – Projekt im Fallback-Modus (nur Skizze und Neuer Körper)."
  xcodegen generate --spec project.yml
fi

# Prüfen, dass jede Quelldatei im Projekt gelandet ist
missing=0
while IFS= read -r file; do
  if ! grep -q "$(basename "$file")" PencilCAD.xcodeproj/project.pbxproj; then
    echo "FEHLT im Projekt: $file"
    missing=1
  fi
done < <(find App -type f \( -name '*.swift' -o -name '*.mm' -o -name '*.metal' \))

if [ "$missing" -ne 0 ]; then
  echo "Projekt unvollständig. Bitte diese Ausgabe an Claude schicken."
  exit 1
fi
echo "Projekt vollständig: $(find App -type f \( -name '*.swift' -o -name '*.mm' -o -name '*.metal' \) | wc -l | tr -d ' ') Quelldateien."
if $open_project; then open PencilCAD.xcodeproj; fi
