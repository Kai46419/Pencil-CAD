#!/usr/bin/env bash
# Erzeugt PencilCAD.xcodeproj mit XcodeGen (brew install xcodegen).
# Mit OpenCASCADE, wenn Vendor/OCCT.xcframework existiert, sonst im Fallback-Modus.
# Ein laufendes Xcode wird vorher beendet und das Projekt danach geöffnet.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -x Xcode >/dev/null; then
  echo "Xcode läuft – wird beendet …"
  osascript -e 'quit app "Xcode"' || true
  for _ in $(seq 1 30); do
    pgrep -x Xcode >/dev/null || break
    sleep 1
  done
  if pgrep -x Xcode >/dev/null; then
    echo "Xcode ließ sich nicht beenden (ungesicherte Änderungen?). Bitte Xcode mit ⌘Q schließen und erneut starten."
    exit 1
  fi
fi

# Signierung: Team und Bundle-ID überleben so das Neuerzeugen des Projekts.
# Eigene Werte optional in signing.env (nicht eingecheckt):
#   PENCILCAD_TEAM=ABCDE12345
#   PENCILCAD_BUNDLE_ID=de.meinname.pencilcad
if [ -f signing.env ]; then
  set -a; . ./signing.env; set +a
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

# Altes Projekt komplett entfernen, damit keine veralteten Dateilisten übrig bleiben
rm -rf PencilCAD.xcodeproj

if [ -d Vendor/OCCT.xcframework ]; then
  echo "OpenCASCADE gefunden – Projekt mit Kernel."
  xcodegen generate --spec project-occt.yml
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
open PencilCAD.xcodeproj
