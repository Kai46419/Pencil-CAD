# PencilCAD Build 37 – technische Zeichnungen

## Änderung

- Auf dem Zeichnungsblatt lassen sich Längenmaße zwischen zwei sichtbaren Endpunkten derselben Normansicht setzen.
- Messarten: ausgerichtet, waagerecht und senkrecht. Das Maß lässt sich ziehen, auswählen und löschen.
- Der Wert berücksichtigt den Maßstab der Ansicht; PDF, DXF, Vorschau und Teilen enthalten dasselbe Maß.
- Isometrische Ansichten sind von der Maßauswahl ausgeschlossen, weil deren projizierte Strecken keine verlässlichen 3D-Längen liefern.
- Bei einem geänderten Blatt werden Maße ohne gültige Quellpunkte entfernt.

## Nachweise

- Simulator: 125 Tests bestanden, 0 Fehler (`/tmp/PencilCAD_B37_full_test.log`).
- Physisches iPad: 3 gezielte Zeichnungstests bestanden, 0 Fehler (`/tmp/PencilCAD_B37_device_test.log`).
- Release Build und strenge Codesign Prüfung bestanden; App auf dem iPad installiert und gestartet.
- Alle 145 Projektdateien waren vor und nach der Installation SHA-256 bytegleich.

## Grenze

Die Touchbedienung der neuen Maßfunktion ist auf dem iPad noch nicht manuell durchgetippt. Radius- und Durchmessermaße sowie Toleranzen fehlen weiterhin. Deshalb liegt die Bewertung „Technische Zeichnungen“ vorläufig bei 3/5.
