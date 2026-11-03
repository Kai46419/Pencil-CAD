# PencilCAD Build 26 – 03.11.2026

## Skizzieren und Fangpunkte

- Der klassische Eingabestil berechnet Schnittpunkte von Gerade, Kreis und Bogen
  nun aus den geometrischen Grundformen. Die vorherigen Schnittpunkte aus
  abgetasteten Darstellungssegmenten konnten neben der tatsächlichen Kurve liegen.
- „Auf Kurve“ projiziert bei Kreis und Bogen auf die exakte Geometrie. Der
  Feinrasterabstand wird entlang des Kreisbogens angewendet, ohne den Punkt vom
  Kreis wegzuschieben.
- Konstruktionslinien, Textkonturen und die bisherigen Polygonzüge für Ellipsen
  und Splines bleiben in den jeweiligen Fangpfaden erhalten.
- Neue Regressionstests prüfen Gerade/Kreis, Kreis/Kreis, Bogengrenze, klassisches
  Hover und den Radius des Kurvenfangs bei 0,001-mm-Raster.
- Ein vorhandener Test für „gleiche Länge“ setzt seine Fangarten nun ausdrücklich.
  Damit hängt er nicht vom zuletzt gespeicherten Testzustand ab.

## Verifikation

- Swift-Quellen geparst: 165/165.
- Simulator (iPad Pro 11 Zoll): 75/75 Tests bestanden.
- iPad Air 11 Zoll (M4): 75/75 Tests bestanden; Ergebnis in
  `Pruefprotokolle/Build26_iPad_Testsummary.json`.
- Signierter Release-Build für das iPad erfolgreich; Bundle-Version 26 und
  Signatur durch `codesign --verify --deep --strict` geprüft.
- Release-App auf dem iPad installiert und gestartet. Projektdateien davor und
  danach: 14 Ordner, 105 Dateien, bytegleich (SHA-256-Vergleich).

## Grenzen

- Ellipsen und Splines werden beim Schnitt- und Kurvenfang weiterhin über
  abgetastete Polygonzüge angenähert.
- Die Bewertung „fünf Sterne“ für den gesamten Bereich erfordert zusätzlich
  eine manuelle Pencil-Prüfung komplexer Skizzen und einen erneuten Vergleich
  mit den aktuellen Funktionen der anderen CAD-Programme.
