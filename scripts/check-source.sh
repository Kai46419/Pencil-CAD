#!/usr/bin/env bash
# Portable preflight; does not replace an Xcode iOS build.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null || { echo 'ERROR: swiftc missing'; exit 2; }
files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < <(find App -type f -name '*.swift' -print0)
if (( ${#files[@]} == 0 )); then echo 'ERROR: no Swift sources'; exit 2; fi
printf 'Checking Swift syntax (%s files)...\n' "${#files[@]}"
swiftc -frontend -parse "${files[@]}"
printf 'PASS: all Swift sources parse.\n'
if [[ ! -d Vendor/OCCT.xcframework ]]; then
  echo 'NOTICE: Vendor/OCCT.xcframework not present; full OCCT build needs this local dependency.'
fi
if [[ ! -f signing.env ]]; then
  echo 'NOTICE: signing.env not present; signing may require local configuration.'
fi
printf 'Preflight complete; no typechecking, linking or iPad runtime testing performed.\n'
