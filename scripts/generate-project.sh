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
