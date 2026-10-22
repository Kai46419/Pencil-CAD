#!/usr/bin/env bash
# Erzeugt PencilCAD.xcodeproj mit XcodeGen (brew install xcodegen).
# Mit OpenCASCADE, wenn Vendor/OCCT.xcframework existiert, sonst im Fallback-Modus.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d Vendor/OCCT.xcframework ]; then
  echo "OpenCASCADE gefunden – Projekt mit Kernel."
  xcodegen generate --spec project-occt.yml
else
  echo "Kein Vendor/OCCT.xcframework – Projekt im Fallback-Modus (nur Grundkörper, keine Booleans)."
  xcodegen generate --spec project.yml
fi
