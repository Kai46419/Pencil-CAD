#!/usr/bin/env bash
# Zeigt die letzten TestFlight-Builds von PencilCAD mit Verarbeitungsstatus (App Store Connect API).
# Voraussetzungen:
#   ~/.appstoreconnect/private_keys/AuthKey_<Schlüssel-ID>.p8   (API-Schlüssel, Rolle Entwickler)
#   signing.env mit ASC_ISSUER_ID=<Issuer-ID>                   (optional ASC_KEY_ID, wenn mehrere Schlüssel liegen)
#
#   bash scripts/testflight-status.sh [Anzahl]
set -euo pipefail
cd "$(dirname "$0")/.."
limit="${1:-5}"

. scripts/asc-auth.sh
asc_load || exit 2
token="$(asc_token)"

api() { curl -sS -g --fail-with-body -H "Authorization: Bearer $token" "https://api.appstoreconnect.apple.com/v1/$1"; }

bundle="${PENCILCAD_BUNDLE_ID:-de.kai46419.pencilcad}"
app="$(api "apps?filter[bundleId]=$bundle&fields[apps]=name" | jq -r '.data[0].id // empty')"
[ -n "$app" ] || { echo "FEHLER: keine App mit Bundle-ID $bundle in App Store Connect gefunden."; exit 1; }

api "builds?filter[app]=$app&sort=-uploadedDate&limit=$limit&include=preReleaseVersion,buildBetaDetail&fields[builds]=version,uploadedDate,processingState,expired&fields[preReleaseVersions]=version&fields[buildBetaDetails]=internalBuildState,externalBuildState" \
  | jq -r '
      (.included // []) as $inc
      | if (.data | length) == 0 then "Noch kein Build sichtbar (Verarbeitung läuft evtl. noch)." else
        .data[] | . as $b
        | ($inc[] | select(.type == "preReleaseVersions" and .id == $b.relationships.preReleaseVersion.data.id) | .attributes.version) as $v
        | ([$inc[] | select(.type == "buildBetaDetails" and .id == ($b.relationships.buildBetaDetail.data.id // "")) | .attributes.internalBuildState][0] // "-") as $beta
        | "\($v) (\($b.attributes.version))  \($b.attributes.uploadedDate)  Verarbeitung: \($b.attributes.processingState)  Intern: \($beta)"
      end'
