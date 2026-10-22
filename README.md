# PencilCAD

Eigene CAD-App fürs iPad, Bedienkonzept angelehnt an Shapr3D: Apple Pencil zum Zeichnen, Finger zum Navigieren.
Geometriekernel: [OpenCASCADE](https://github.com/Open-Cascade-SAS/OCCT) (LGPL 2.1 mit Ausnahme). Rendering: Metal.

## Stand (Phase 1 – Fundament)

- SwiftUI-App für iPad (iOS 17+)
- Metal-Viewport: 1 Finger drehen, 2 Finger verschieben, Pinch zoomen (Pencil ist für Phase 2 reserviert)
- Kernel-Brücke `PCKShape` (Objective-C++): Quader, Zylinder, Bohrung (Boolean Cut), Kanten runden, Triangulierung
- Undo, STL-Export (binär) über die Dateien-App
- Fallback-Modus ohne OpenCASCADE: Viewer und UI laufen, Booleans/Rundung melden „braucht OpenCASCADE“

## Voraussetzungen

- Mac mit Apple Silicon, Xcode 15 oder neuer
- `brew install xcodegen cmake`
- iPad mit iPadOS 17+ (oder der iPad-Simulator)

## Bauen

```bash
# 1. Optional, aber für echte CAD-Funktionen nötig: OpenCASCADE für iPad bauen (dauert eine Weile)
./scripts/build-occt-ios.sh

# 2. Xcode-Projekt erzeugen (wählt automatisch mit/ohne OpenCASCADE)
./scripts/generate-project.sh

# 3. Öffnen
open PencilCAD.xcodeproj
```

In Xcode: Target **PencilCAD** → *Signing & Capabilities* → eigenes **Team** wählen und ggf. die Bundle-ID
(`com.example.pencilcad`) ändern. Dann iPad auswählen und starten.

Ohne Schritt 1 startet die App im Fallback-Modus. Das ist gut, um Viewer und Gesten sofort zu testen.

## Projektstruktur

```
App/
  PencilCADApp.swift, ContentView.swift   UI, Toolbar, STL-Export
  Model/      Mesh (Netz + STL), ModelStore (Körper, Undo)
  Viewport/   Metal-Renderer, Orbit-Kamera, Gesten, Shader
  Kernel/     PCKShape.h/.mm – Brücke zu OpenCASCADE
scripts/      OCCT-Build, Projekt-Generierung
project.yml   XcodeGen-Spezifikation (project-occt.yml = mit Kernel)
```

## Roadmap

1. **Fundament** (dieser Stand): Viewer, Kernel-Brücke, Demo-Operationen
2. **Skizze + Extrusion**: Ebene wählen, mit Pencil zeichnen, Maße eingeben, extrudieren
3. **Bearbeiten**: auf Flächen skizzieren, Extrude-Cut, Booleans, Fase/Rundung gezielt, STEP-Import/-Export
4. **Feinschliff**: Speichern/Öffnen, Fang-Hilfen, TestFlight
