#!/usr/bin/env bash
# Baut PencilCAD als App-Store-Archiv und lädt es zu App Store Connect / TestFlight hoch.
# Voraussetzungen: bezahltes Apple Developer Program, Apple-ID in Xcode (Einstellungen > Accounts),
# App-Eintrag in App Store Connect mit derselben Bundle-ID.
#
#   bash scripts/testflight.sh             Archiv bauen und hochladen
#   bash scripts/testflight.sh --nur-bauen Archiv bauen und .ipa nur lokal exportieren
#
# Build-Nummer (CFBundleVersion): „N.S“ – N aus dem letzten Commit-Titel „Build N: …“,
# S zählt die Uploads je N hoch (build/testflight/zaehler.txt). So bleibt sie für TestFlight streng steigend.
set -euo pipefail
cd "$(dirname "$0")/.."

destination=upload
case "${1:-}" in
  "") ;;
  --nur-bauen) destination=export ;;
  *) echo "Aufruf: bash scripts/testflight.sh [--nur-bauen]"; exit 2 ;;
esac

bash scripts/generate-project.sh

# Anmeldung: Standard ist der in Xcode angemeldete Account (so getestet). Mit TESTFLIGHT_MIT_API_KEY=1
# in signing.env nimmt xcodebuild stattdessen den API-Schlüssel (siehe scripts/asc-auth.sh); für das
# automatische Signieren braucht der Schlüssel dann mindestens die Rolle App-Manager.
auth=()
. scripts/asc-auth.sh
if asc_load 2>/dev/null && [ "${TESTFLIGHT_MIT_API_KEY:-0}" = 1 ]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "Anmeldung: API-Schlüssel $ASC_KEY_ID"
else
  echo "Anmeldung: Xcode-Account"
fi

team="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);/\1/p' PencilCAD.xcodeproj/project.pbxproj | head -n1)"
[ -n "$team" ] || { echo 'FEHLER: kein Team im Projekt. In Xcode ein Team wählen oder PENCILCAD_TEAM in signing.env setzen.'; exit 2; }

n="$(git log -200 --format=%s | grep -m1 -oE '^Build [0-9]+' | grep -oE '[0-9]+' || true)"
n="${n:-$(git rev-list --count HEAD)}"
out=build/testflight
mkdir -p "$out"
counter="$out/zaehler.txt"
s=1
if [ -f "$counter" ]; then
  read -r last_n last_s < "$counter" || true
  if [ "${last_n:-}" = "$n" ]; then s=$(( ${last_s:-0} + 1 )); fi
  if [ -n "${last_n:-}" ] && [ "$n" -lt "$last_n" ]; then
    echo "FEHLER: Build $n ist kleiner als der letzte Upload (Build $last_n). TestFlight verlangt steigende Nummern."
    exit 2
  fi
fi
version="$n.$s"
archive="$out/PencilCAD-$version.xcarchive"
echo "Archiv: Build $version, Team $team"

xcodebuild archive \
  -project PencilCAD.xcodeproj \
  -scheme PencilCAD \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath "$out/DerivedData" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  CURRENT_PROJECT_VERSION="$version" \
  | tee "$out/archive.log" | grep -E '^(error|warning: .*sign|\*\* )' || true
[ -d "$archive" ] || { echo "FEHLER: Archiv fehlt, siehe $out/archive.log"; exit 1; }

# Nummer verbrauchen, sobald das Archiv steht (auch ein abgebrochener Upload darf sie nicht wiederverwenden)
if [ "$destination" = upload ]; then echo "$n $s" > "$counter"; fi

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export-$version" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  2>&1 | tee "$out/export.log" | grep -vE '^\s*$|not yet complete|Checking completion status' | tail -n 25
status="${PIPESTATUS[0]}"
[ "$status" -eq 0 ] || { echo "FEHLER beim Export/Upload, siehe $out/export.log"; exit "$status"; }

if [ "$destination" = upload ]; then
  echo "Hochgeladen: Build $version. In App Store Connect > TestFlight erscheint er nach der Verarbeitung (meist 5–30 Min.)."
  echo "Status prüfen: bash scripts/testflight-status.sh"
else
  echo "Exportiert: $out/export-$version/PencilCAD.ipa (nicht hochgeladen)."
fi
