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
| Gezielte 3D-Tests auf Kais iPad | 7/7 bestanden (`/tmp/PencilCAD_B29_ipad_tests_usb.log`) |
| Vollständige Suite auf Kais iPad | 91/91 Tests bestanden (`/tmp/PencilCAD_B29_ipad_full.log`) |
| Signierter iPad-Release-Build | Erfolgreich (`/tmp/PencilCAD_B29_device_build_final.log`), Buildnummer 29, `codesign --verify --deep --strict` bestanden |
| Installation auf Kais iPad | Erfolgreich per USB; installierte Version 29, Release-App gestartet |
| Projektdaten | 135 Dateien unmittelbar vor Installation gesichert; nach iPad-Tests, erneuter Release-Installation und App-Start 135/135 bytegleich, nichts entfernt oder hinzugefügt |

Die 3D-Modellierung steigt damit für die geprüften Kernwerkzeuge auf 4/5. Die Tests prüfen Referenzgeometrien; ein manueller Pencil-Durchlauf komplexer Modelle ist noch nicht erfolgt. Abrunden/Fasen und Verlauf/Parametrik bleiben eigene, niedriger bewertete Bereiche. Die ersten Installationsversuche über WLAN scheiterten an der Geräteverbindung; per USB waren Installation und XCTest erfolgreich.
