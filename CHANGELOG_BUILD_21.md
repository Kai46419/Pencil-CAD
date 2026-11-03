# PencilCAD Build 21 – 31.10.2026

## Geändert

- Der Zustand unmittelbar vor der letzten Volumenkörper-Abrundung wird als entbehrliche STEP-Datei im Projekt gespeichert. Nach dem Öffnen kann eine angrenzende Rundung diesen Zustand direkt nutzen. Der zuvor beobachtete erste Verlaufs-Nachbau auf dem MainActor entfällt in diesem Fall.
- Die zusätzliche Datei wird nur bei passender letzter Feature-ID, Körpernummer, gültiger Geometrie und passendem Ergebnisvolumen angenommen. Fehlt sie, verwendet PencilCAD unverändert den bisherigen Nachbau.
- Undo/Redo und Geometrieänderungen verwerfen den geladenen Zwischenstand. Nicht mehr benötigte Zwischenstandsdateien werden nach dem Speichern entfernt.
- `features.json` hat ein optionales Feld `preBlendCache`; vorhandene Projekte bleiben lesbar.

## Nachweis

- Der Projekt-8-Regressionstest öffnet den gespeicherten Fall erneut, wählt die benachbarte Kante und bestätigt die gemeinsame Rundung ohne ersten Feature-Nachbau.
- Der Projektzyklus-Test prüft Speichern, Öffnen, Zeitachse, STEP-Export und den Rückfall bei fehlender Zwischenstandsdatei.
- 56/56 Simulator- und 56/56 iPad-Tests bestanden.
- Signierter Release-Build 21 erfolgreich; auf dem iPad installiert und gestartet. Vorher und nachher: 10 Projektordner, 79 Dateien, 0 Inhaltsunterschiede.

## Grenzen

- Die Änderung beseitigt den konkret gemessenen ersten Verlaufs-Nachbau für die letzte Rundung. Sie ist kein allgemeiner Nachweis flüssiger Pencil-Eingabe oder der Gleichwertigkeit mit Shapr3D.
- Die Vorschau „Rundung vor Schnitt“ rechnet den umgestellten Verlauf nach der Eingabepause weiterhin auf dem MainActor. Diese eigenständige Verzögerung bleibt offen.
- Bereits vorhandene Projekte ohne Build-21-Zwischenstandsdatei brauchen den ersten Nachbau noch einmal. Der Zwischenstand wird beim nächsten Speichern abgelegt; folgende Öffnungen können ihn direkt lesen.
