# Build 20: Abrundungsnetz im Hintergrund vorbereiten

## Messung auf dem iPad (Projekt-8-Nachbarrundung)

- Erste Suche der Nachbarkanten: ca. 105 ms, danach aus Cache ca. 0,03 ms.
- Kopie des vorherigen Körpers: ca. 0,23 ms.
- Isolierte Rundung: ca. 54 ms auf dem Kernel-Pfad.
- Vernetzung des fertigen Ergebnisses: ca. 12 ms; erneute Mesh-Übernahme bei vorhandenem Cache: ca. 1,2 ms.

## Änderung

Das gültige Ergebnis wird auf dem bereits verwendeten Kernel-Thread mit der normalen Vorschauauflösung (0,05 mm) vernetzt, bevor es an den MainActor gelangt. `ModelStore.remesh()` erhält dadurch ein fertiges Kernel-Netz. Bei mehreren Körpern werden unveränderte Swift-Netze anhand von Shape-Identität, Auflösung, Farbe, Platzierung und Körperposition wiederverwendet. Der zusätzliche Cache ist auf 32 MiB begrenzt. Numerik, Auswahl, Verlauf und Fehlermeldungen bleiben unverändert.

## Abnahme

- Projekt-8-Geometrie bei gemischten Radien und bestehende Abrundungstests bestehen.
- Vorschauwechsel mit zwei Körpern, Umordnen, Farb-/Sichtbarkeitswechsel und geänderter Auflösung behalten korrekte Körper- und Flächenzuordnung.
- Vollständige Simulator- und iPad-Suite besteht.
- Signierter Release-Build, Installation ohne Verlust der vorhandenen Projekte.
- Die Bildrate bei einer realen Stiftbewegung lässt sich aus XCTest allein nicht beweisen; die Messung begründet nur den vermiedenen Hauptthread-Anteil.
