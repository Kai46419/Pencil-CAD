# PencilCAD Build 30 – Abrunden und Fasen

## Änderung und Ursache

`edgesFromNumbers` in `App/Kernel/PCKShape.mm` ließ bisher ungültige Kantennummern aus und rechnete mit dem Rest weiter. Bei einer veralteten Auswahl konnte dadurch eine scheinbar erfolgreiche Teilabrundung oder Teilfase entstehen. Build 30 lehnt die gesamte Auswahl ab, sobald eine der Nummern nicht zum aktuellen Körper gehört. Gültige Einzelkanten werden weiterhin bearbeitet. Diese Prüfung gilt auch für den isolierten BlendWorker.

## Verifikation

| Prüfung | Ergebnis |
| --- | --- |
| Test zuerst gegen Build 29 | Zwei direkte Kerneltests und ein Worker-Test schlugen erwartungsgemäß fehl: trotz ungültiger zweiter Kante wurde ein Körper erzeugt |
| Dieselben Tests nach der Korrektur | 3/3 bestanden |
| Vollständige Suite im Simulator | 94/94 bestanden, einschließlich Projekt 6 und Projekt 8 |
| Vollständige Suite auf Kais iPad | 94/94 bestanden; gezielt 3/3 |
| Signierter Release-Build | Erfolgreich, Buildnummer 30; `codesign --verify --deep --strict` bestanden |
| Installation und Start | Build 30 per USB auf Kais iPad installiert und gestartet; Geräteübersicht meldet Version 30 |
| Projektdaten | Vorher 135 Dateien gesichert; nach Tests, Release-Installation und App-Start 135/135 bytegleich, keine Datei hinzugefügt oder entfernt |

Die Bewertung „Abrunden und Fasen“ steigt für die geprüfte Auswahl- und Fehlerbehandlung von 2/5 auf 3/5. Komplexe Mehrfachrundungen, große Radien an beliebigen Körpern und der manuelle Pencil-Durchlauf sind damit nicht allgemein abgenommen. Bei nicht möglicher Geometrie bleibt die kontrollierte Ablehnung weiterhin ein gültiges Ergebnis.
