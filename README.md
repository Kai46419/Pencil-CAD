# PencilCAD

Eigene CAD-App fürs iPad, Bedienkonzept angelehnt an Shapr3D: Apple Pencil zum Zeichnen, Finger zum Navigieren.
Geometriekernel: [OpenCASCADE](https://github.com/Open-Cascade-SAS/OCCT) 7.7.2 (LGPL 2.1 mit Ausnahme). Rendering: Metal.

## Funktionen

Oberfläche nach dem Aufbau von Shapr3D (eigene Symbole, kein Shapr3D-Material):

- **Startseite „Letzte Projekte“** mit Vorschaubildern; neues Projekt, STEP importieren, Umbenennen, Duplizieren, Löschen
- **Arbeitsbereich:** schwebende Titelleiste (Startseite, Projektname, Menü), linke Werkzeugleiste mit Gruppen und
  Untermenüs, rechte Leiste (Fang, Rastergröße, ViewCube, Einpassen, Anzeigemodi, Screenshot, Verlauf, Elemente),
  „Abbrechen/Fertig“ unten, Rückgängig/Wiederholen unten links, Maß-Etikett am Ziehpfeil
- **Skizze** (Pencil): Linie, Rechteck, Kreis, Ellipse, Polygon, auf der Bodenebene oder auf jeder ebenen Fläche
- **Extrudieren** mit Ziehpfeil: Skizzenprofil (Neuer Körper, Vereinigen, Abziehen) oder ebene Fläche eines Körpers
- **Abrunden und Fase** mit Ziehpfeil: einzelne Kanten antippen, mehrere gleichzeitig
- **Einfügen:** Quader, Zylinder, Kugel, Kegel, STEP-Datei
- **Boolesch:** Vereinigen, Abziehen, Schneiden
- **Transformation:** Verschieben mit Achsenpfeilen (X/Y/Z), Drehen in 90°-Schritten, Spiegeln
- **Schale**, **Farbe** je Körper, Körper ein-/ausblenden und umbenennen (Elemente)
- **Anzeigemodi:** Schattiert, Schattiert ohne Kanten, Drahtgitter, Röntgen; Perspektive oder orthografisch
- **Verlauf** mit benannten Schritten, Antippen springt zurück (oder wieder vor)
- **STEP/STL exportieren**, Screenshot teilen
- Automatisches Speichern je Projekt (`Projects/<id>/` in der Dateien-App unter „Auf meinem iPad › PencilCAD“)
- Fallback-Modus ohne OpenCASCADE: Viewer, Skizze und „Neuer Körper“ laufen, alles andere meldet „braucht OpenCASCADE“

Grau dargestellt und noch nicht umgesetzt: Bogen, Spline, Punkt, Text, Versetzen, Ebenen/Achsen, Muster, Skalieren,
Rotieren/Sweep/Loft, Kante versetzen, Beschneiden, Teilen, Schnittansicht, Messen, Einschränkungen.

## Bedienung

| Eingabe | Wirkung |
| --- | --- |
| 1 Finger ziehen | Ansicht drehen |
| 2 Finger ziehen | Ansicht verschieben |
| Pinch | Zoomen |
| Tippen auf eine Kante | Kante wählen bzw. abwählen (mehrere möglich), Pfeil zum Abrunden erscheint |
| Tippen auf eine Fläche | Fläche wählen, bei ebenen Flächen erscheint der Pfeil zum Extrudieren |
| Pfeil ziehen (Pencil oder Finger) | Wert ändern, rastet je nach Zoom auf 0,1/0,5/1/5/10 mm |
| Pencil im Skizzenmodus | Zeichnen; der erste Strich auf einer ebenen Fläche legt die Skizzenebene fest |
| ViewCube antippen | Ansicht senkrecht auf diese Seite |

**Typischer Ablauf:**

1. Startseite › „Neues Projekt“.
2. Links „Skizze › Rechteck“, mit dem Pencil ein Rechteck ziehen, unten Breite/Tiefe eintragen.
3. Am blauen Pfeil auf 20 mm ziehen, „Fertig“.
4. „Skizze › Kreis“, den Strich auf der Oberseite beginnen, Modus „Abziehen“, Pfeil ziehen → Bohrung.
5. „Fertig“ (Skizze beenden), zwei Kanten oben antippen, am Pfeil ziehen → Rundung, „Fertig“.
6. Titelleiste › „⋯“ › „Als STEP exportieren …“ oder „Als STL exportieren …“.

Werkzeuge im Detail:
- *Rechteck:* von Ecke zu Ecke ziehen
- *Kreis, Polygon:* vom Mittelpunkt nach außen ziehen (Polygon: Seitenzahl unten einstellbar)
- *Ellipse:* vom Mittelpunkt zur Ecke des umschließenden Rechtecks ziehen
- *Linie:* Startpunkt tippen, dann jeden weiteren Punkt antippen oder hinziehen; zurück zum Startpunkt schließt das Profil
- *Boolesch:* erst den Zielkörper antippen, dann die Werkzeugkörper, „Fertig“
- *Schale:* die Fläche antippen, die offen sein soll, Wandstärke eingeben

„Abziehen“ arbeitet auf einer Fläche ins Material hinein, auf der Bodenebene nach oben. Negative Werte kehren die Richtung um.
Im Simulator ist „Finger zeichnet“ automatisch an (rechte Leiste, Handsymbol); zum Drehen kurz ausschalten.
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

**Echtes iPad:** Einmal in Xcode unter Target **PencilCAD** › *Signing & Capabilities* das eigene **Team** wählen und
`./scripts/generate-project.sh` erneut ausführen. Das Skript liest die Team-ID danach selbst aus dem Schlüsselbund,
die Einstellung geht beim Neuerzeugen also nicht mehr verloren. Bundle-ID: `de.kai46419.pencilcad`. Eigene Werte
optional in `signing.env` (`PENCILCAD_TEAM=…`, `PENCILCAD_BUNDLE_ID=…`). Auf dem iPad den Entwicklermodus einschalten
(Einstellungen › Datenschutz & Sicherheit).

**Wichtig:** Das Xcode-Projekt wird nicht eingecheckt, sondern erzeugt. Nach jedem `git pull` oder Branch-Wechsel, der
neue Dateien bringt, `./scripts/generate-project.sh` erneut ausführen (beendet Xcode selbst und öffnet das Projekt neu). Sonst meldet Xcode
„Cannot find '…' in scope“. Gleiches gilt nach Schritt 1.

Falls schon eine ältere OpenCASCADE-Version gebaut wurde: `rm -rf build/occt Vendor` und Schritt 1 wiederholen.

Ohne Schritt 1 startet die App im Fallback-Modus. Das ist gut, um Viewer und Gesten sofort zu testen.

## Projektstruktur

```
App/
  PencilCADApp.swift   Einstieg: Startseite oder geöffnetes Projekt
  Files.swift          Dateitypen und Export
  Projects/   Projektliste (Documents/Projects), Startseite
  Workspace/  Arbeitsbereich: Zustand und Werkzeuge, Werkzeugleisten, ViewCube, Parameterkarten, Verlauf, Elemente
  Model/      Mesh (Netz, Picking, STL), Sketch (Skizzenebene, Werkzeuge, Profile), ModelStore (Körper, Verlauf, STEP)
  Viewport/   Metal-Renderer, Orbit-Kamera, Gesten, Pencil-Eingabe, Ziehpfeile, Shader
  Kernel/     PCKShape.h/.mm – Brücke zu OpenCASCADE (mit Fallback ohne Kernel)
scripts/      OCCT-Build, Projekt-Generierung
project.yml   XcodeGen-Spezifikation (project-occt.yml = mit Kernel)
```

## Bewusst noch nicht enthalten

Parametrische Historie (nachträgliches Ändern von Maßen), Constraints in Skizzen, Drehen/Sweep/Loft, Baugruppen,
2D-Zeichnungen sowie die oben grau aufgeführten Werkzeuge. Für den App-Store-Vertrieb vorher Lizenz (LGPL) und Markenrecht prüfen lassen.
