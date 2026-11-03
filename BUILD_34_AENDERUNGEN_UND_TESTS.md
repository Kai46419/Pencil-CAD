# PencilCAD Build 34 – Verlauf und Parametrik

## Änderung

Ein fehlgeschlagener Verlaufsschritt hat bisher alle späteren Schritte blockiert. Der Nachbau verfolgt jetzt die betroffenen Körper, solange die Körperzahl und die Referenzen stabil bleiben. Änderungen an anderen Körpern und neue unabhängige Grundkörper laufen weiter. Ein vollständiger gespeicherter Stand stellt den Zustand wieder her und gibt spätere Schritte frei.

Übersprungene Schritte erweitern die Abhängigkeitssperre. Bei Operationen mit unklarer Wirkung, etwa einem Booleschen Schritt, bleibt die Fortsetzung gesperrt. Ein teilweise ungültiger Zustand wird nicht als Cachebasis gespeichert. Nach Korrektur eines ungültigen Parameters werden die Folgeoperationen erneut berechnet.

## Nachweise

- Zwei Körper: fehlerhafte Änderung an A, gültige Verschiebung an B, weiterer Schritt an A gesperrt; nach Parameterkorrektur alle Schritte wieder gültig und nach Wiederöffnen vorhanden.
- Fehlerhafte Rundung an A, Verschiebung an B bleibt ausführbar.
- Übersprungener Mehrkörper-Schritt sperrt eine spätere Änderung an B.
- Vollständiger Snapshot nach Fehler stellt den gespeicherten Körper wieder her; nachfolgender Grundkörper wird berechnet.
- Simulator: 117 Tests, 0 Fehler (`Pruefprotokolle/Build34_Simulator_XCTest.log`).
- iPad: 117 Tests, 0 Fehler (`Pruefprotokolle/Build34_iPad_XCTest.log`).
- Signierter Release-Build 34 erstellt, Signatur geprüft, auf Kais iPad installiert und gestartet (`Pruefprotokolle/Build34_iPad_Release_Build.log`). `devicectl device info apps` meldet Build 34.
- Projektdateien vor und nach der Installation verglichen: 145 Dateien, keine geänderten, fehlenden oder neuen Dateien.

## Bewertung

Verlauf und Parametrik: **4/5 Sterne** für die geprüften Bearbeitungs-, Fehler- und Wiederöffnenfälle. Der fünfte Stern setzt stabile Topologiebezüge über komplexe Änderungen und einen vollständigen Abhängigkeitsgraphen voraus. Schritte mit unklarer Wirkung werden aus Sicherheitsgründen weiterhin blockiert.
