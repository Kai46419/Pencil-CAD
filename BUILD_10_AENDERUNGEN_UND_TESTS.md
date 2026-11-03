# PencilCAD Build 10 – Kantenwahl und Projektsicherungen (30.10.2026)

## Umgesetzt

1. **Abrunden wählt zunächst eine Kante.** Im Abrunden-Panel ist „Einzelkante“ die Vorgabe. „Kontur“ bleibt als ausdrücklich wählbarer Modus erhalten. Der bisherige Test wurde umgedreht: Er schlug vor der Codeänderung fehl und besteht danach.
2. **Lokale Projektsicherungen.** Auf der Startseite steht die Zahl der aktuell gespeicherten Projekte. Ein langer Druck auf eine Projektkachel bietet „Sicherung erstellen“. Die Schaltfläche „Sicherungen“ listet die lokalen Kopien und stellt eine davon als neues Projekt wieder her. Der vorhandene Projektordner wird dabei nicht überschrieben. Sicherungen liegen unter `Documents/ProjectBackups` und bleiben auch nach dem Löschen des ursprünglichen Projekts erhalten.

## Prüfung

- Mac: 84 Kerntests bestanden, 0 fehlgeschlagen.
- iPad-Simulator: 26 App-Tests bestanden, 0 fehlgeschlagen.
- Physisches iPad: 26 App-Tests bestanden, 0 fehlgeschlagen.
- Die beiden neuen Sicherungstests prüfen getrennte Kopien und das Wiederöffnen eines gespeicherten 3D-Modells nach Löschen des Originals.
- Die Startseite wurde im Simulator visuell geprüft; die neuen Schaltflächen passen in die Kopfzeile.
- Projektdaten vor/nach den Gerätetests und nach Installation/Start der App: Die 20 vorher vorhandenen Dateien sind bytegleich. Ein neues „Titelloses Projekt 4“ kam während der Prüfung hinzu. Nach dem App-Start enthält es einen Körper mit Extrusions- und Abrundungsfeature; die Herkunft ist ungeklärt. Es wurde nicht gelöscht.
- Die signierte App-only-Version 10 wurde auf dem physischen iPad installiert und gestartet. Die installierte App enthält kein Testmodul.

## Einordnung zum Shapr3D-Vergleich

Der Shapr3D-Installer enthält kompilierte proprietäre Binärdateien, keinen freigegebenen Quellcode. In PencilCAD wurde kein Shapr3D-Quellcode übernommen. Die Änderungen sind eigenständig implementiert.

Build 10 ist **keine vollständige Shapr3D-Funktionsparität**. Weiter offen sind insbesondere eine eindeutige Auswahl überlappender Kanten, optionales Mitnehmen nur tangentialer Kanten, zusätzliche Rundungsprofile (G2, Sehnenbreite, Eck- und Überlaufarten), weitergehende Optionen beim Ziehen von Körperflächen, Verlaufsfilter nach Auswahl, Schnitt- und Detailansichten mit Toleranzen, zusätzliche CAD-Importformate sowie eine geräteübergreifende Synchronisierung. Komplexe Abrundungen müssen weiterhin an konkreten Modellen geprüft werden; ein beliebig großer Radius ist geometrisch nicht immer möglich.

Die Sicherungen sind lokal und manuell. Sie ersetzen weder iCloud/Cloud-Synchronisierung noch eine automatische Versionierung. Die neuen Prüfungen belegen den modellseitigen Sicherungsablauf; eine automatisierte Stift- oder Fingerprüfung der Sicherungsoberfläche ist nicht enthalten.
