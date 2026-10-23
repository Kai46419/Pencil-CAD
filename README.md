# PencilCAD

Eigene CAD-App fürs iPad, Bedienkonzept angelehnt an Shapr3D: Apple Pencil zum Zeichnen, Finger zum Navigieren.
Geometriekernel: [OpenCASCADE](https://github.com/Open-Cascade-SAS/OCCT) 7.7.2 (LGPL 2.1 mit Ausnahme). Rendering: Metal.

## Funktionen

- **Skizzieren mit dem Pencil** auf der Bodenebene oder direkt auf jeder ebenen Fläche eines Körpers:
  Rechteck, Kreis, Linienzug, 1-mm-Rasterfang, Live-Maße
- **Exakte Maße** nach dem Zeichnen eingeben (Breite/Tiefe, Durchmesser)
- **Extrudieren** als neuer Körper, Vereinigen oder Abziehen (Taschen, Durchbrüche)
- **Kanten runden und fasen** (alle Kanten der gewählten Fläche)
- Flächen antippen und auswählen, Körper löschen
- Kantendarstellung, Undo/Redo, Ansicht einpassen, Draufsicht auf die Skizzenebene
- **STEP öffnen und exportieren**, **STL exportieren** (z. B. für den 3D-Druck)
- Automatisches Speichern (`Autosave.step`, in der Dateien-App unter „Auf meinem iPad › PencilCAD“ sichtbar)
- Fallback-Modus ohne OpenCASCADE: Viewer, Skizze und „Neuer Körper“ laufen, alles andere meldet „braucht OpenCASCADE“

## Bedienung

| Eingabe | Wirkung |
| --- | --- |
| 1 Finger ziehen | Ansicht drehen |
| 2 Finger ziehen | Ansicht verschieben |
| Pinch | Zoomen |
| Tippen | Fläche auswählen (orange) |
| Pencil im Skizzenmodus | Zeichnen auf der Skizzenebene |
| Finger-Tipp im Skizzenmodus | Ebene Fläche wird zur Skizzenebene, Tipp ins Leere = Bodenebene |

**Typischer Ablauf:**

1. „Skizze“ einschalten, mit dem Pencil ein Rechteck ziehen.
2. Unten Breite/Tiefe exakt eintragen, Modus „Neuer Körper“, Höhe 20, „Extrudieren“.
3. Skizze aus, Oberseite antippen (wird orange), Skizze wieder ein: Die Fläche ist jetzt Skizzenebene.
   Kreis ziehen, Ø 8 eintragen, Modus „Abziehen“, Tiefe 20 → Bohrung (braucht OpenCASCADE).
4. Skizze ausschalten, Oberseite antippen, „Kanten › Kanten runden …“, 2 mm.
5. „Datei › Als STEP exportieren …“ oder „Als STL exportieren …“.

Werkzeuge im Detail:
- *Rechteck:* von Ecke zu Ecke ziehen
- *Kreis:* vom Mittelpunkt nach außen ziehen
- *Linienzug:* Startpunkt tippen, dann jeden weiteren Punkt antippen oder hinziehen; zurück zum Startpunkt schließt das Profil

„Abziehen“ arbeitet auf einer Fläche ins Material hinein, auf der Bodenebene nach oben. Negative Werte kehren die Richtung um.
„Vereinigen“ verbindet mit dem Körper, auf dem skizziert wurde (sonst mit dem zuletzt erzeugten).
Im Simulator ist „Finger zeichnet“ automatisch an (die Maus zählt als Finger); zum Drehen kurz ausschalten.
Auf dem iPad zeichnet nur der Pencil, die Finger navigieren.

## Voraussetzungen

- Mac mit Apple Silicon, Xcode 15 oder neuer
- `brew install xcodegen cmake`
- iPad mit iPadOS 17+ (oder der iPad-Simulator)

## Bauen

```bash
# 1. OpenCASCADE für iPad bauen (einmalig, dauert eine Weile)
./scripts/build-occt-ios.sh

# 2. Xcode-Projekt erzeugen (wählt automatisch mit/ohne OpenCASCADE)
./scripts/generate-project.sh

# 3. Öffnen
open PencilCAD.xcodeproj
```

In Xcode: Target **PencilCAD** → *Signing & Capabilities* → eigenes **Team** wählen und ggf. die Bundle-ID
(`com.example.pencilcad`) ändern. Dann iPad auswählen und starten.

**Wichtig:** Das Xcode-Projekt wird nicht eingecheckt, sondern erzeugt. Nach jedem `git pull` oder Branch-Wechsel, der
neue Dateien bringt, Xcode schließen und `./scripts/generate-project.sh` erneut ausführen. Sonst meldet Xcode
„Cannot find '…' in scope“. Gleiches gilt nach Schritt 1.

Falls schon eine ältere OpenCASCADE-Version gebaut wurde: `rm -rf build/occt Vendor` und Schritt 1 wiederholen.

Ohne Schritt 1 startet die App im Fallback-Modus. Das ist gut, um Viewer und Gesten sofort zu testen.

## Projektstruktur

```
App/
  PencilCADApp.swift, ContentView.swift   Oberfläche, Toolbar, Dialoge, Import/Export
  Model/      Mesh (Netz, Picking, STL), Sketch (Skizzenebene, Werkzeuge, Profile), ModelStore (Körper, Undo/Redo, STEP)
  Viewport/   Metal-Renderer, Orbit-Kamera, Gesten und Pencil-Eingabe, Shader
  Kernel/     PCKShape.h/.mm – Brücke zu OpenCASCADE (mit Fallback ohne Kernel)
scripts/      OCCT-Build, Projekt-Generierung
project.yml   XcodeGen-Spezifikation (project-occt.yml = mit Kernel)
```

## Bewusst noch nicht enthalten

Parametrische Historie (nachträgliches Ändern von Maßen), Constraints in Skizzen, Drehen/Sweep/Loft, Baugruppen,
2D-Zeichnungen, einzelne Kanten auswählen. Für den App-Store-Vertrieb vorher Lizenz (LGPL) und Markenrecht prüfen lassen.
