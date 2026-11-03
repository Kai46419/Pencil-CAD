# PencilCAD Build 29 – 3D-Modellierung

## Änderungen

- Extrusion: Eine fehlgeschlagene Neuberechnung entfernt die zuvor gültige Vorschau. Dadurch lässt sich kein alter Körper unter einem neuen, ungültigen Abstand oder Verjüngungswinkel übernehmen. Nicht endliche Abstände werden vor dem Kernel abgelehnt.
- Drehen: Eine Nullachse sowie nicht endliche Achsen-, Ursprung- und Winkelwerte werden vor dem OCCT-Aufruf abgelehnt.
- Sweep: Ein Pfad mit mehreren getrennten Kurven wird als ungültig gemeldet, statt unbemerkt nur einen Teil zu verwenden.
- Loft: Eine ungültige ausgewählte Querschnittskurve darf nicht stillschweigend entfallen.

## Verifikation

| Prüfung | Ergebnis |
| --- | --- |
| Neue 3D-Regressionen | 7/7 bestanden: Extrusion, Drehung, Bohrung, Boolean, Schale, Sweep, Loft, Muster, Spiegeln, Undo und Wiederöffnen |
| Vollständige iOS-Simulator-Suite | 91/91 Tests bestanden (`/tmp/PencilCAD_B29_full_final.log`) |
| Signierter iPad-Release-Build | Erfolgreich (`/tmp/PencilCAD_B29_device_build_final.log`), Buildnummer 29, `codesign --verify --deep --strict` bestanden |
| iPad-Projektsicherung | 135 Dateien vor dem Installationsversuch gesichert |
| XCTest auf echtem iPad | Nicht gelaufen: `xcodebuild test` führte das per WLAN gekoppelte iPad nicht als Ziel auf |
| Installation auf echtem iPad | Nicht bestätigt: `devicectl` meldete beim Übertragen eine sofortige Trennung des Geräts |

Die Tests prüfen einfache Referenzgeometrien und belegen keine fehlerfreie Bearbeitung beliebig komplexer Körper. Die 4/5-Wertung für 3D-Modellierung bleibt bis zu einem erfolgreichen Geräteablauf und einem Vergleich der Projektdaten vor und nach der Installation ausstehend.
