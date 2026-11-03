# PencilCAD Build 20 – 31.10.2026

## Geändert

- Gültige Abrundungs- und Fasenergebnisse werden auf dem bestehenden großen Kernel-Thread mit 0,05 mm vernetzt, bevor der MainActor die Vorschau zeigt. Der UI-Pfad verwendet das fertige Kernel-Netz.
- `ModelStore.remesh()` verwendet Swift-Netze unveränderter Körper bei Vorschauwechseln erneut. Der Schlüssel enthält Körperposition, Shape-Identität, Deflection, Darstellungsfarbe und Platzierung. Ausgeblendete Körper werden nicht gecacht. Der zusätzliche Cache ist auf 32 MiB begrenzt.
- Die 0,1-mm-Radien aus Build 18 und die Unterdrückung doppelter Rasterwerte aus Build 19 bleiben erhalten.

## Messung und Tests

- iPad, gespeicherter Projekt-8-Nachbarrundungsfall: Ergebnisnetz erstmals ca. 12 ms, bei vorhandenem Kernel-Netz samt Swift-Übernahme ca. 1,2 ms. Die 12 ms laufen in Build 20 auf dem Kernel-Thread. Die Messung ist ein einzelner Diagnosefall, kein allgemeiner FPS-Wert.
- Neuer Cache-Test mit zwei Körpern: Netz des unveränderten Körpers bleibt identisch; Umordnen, Farbe, Sichtbarkeit, Platzierung und Extrusionsauflösung werden korrekt berücksichtigt.
- Durchgehender Projektzyklus als zusätzlicher Test: 20 × 20-mm-Skizze, 10-mm-Extrusion, 1,5-mm-Rundung, Wiederöffnen, Verlaufsschritte und STEP-Rückimport mit übereinstimmendem Volumen.
- Vollständige Simulator-Suite: 55 Tests, 0 Fehler (`/tmp/PencilCAD_B20_Sim_Full_55.xcresult`).
- Vollständige iPad-Suite: 55 Tests, 0 Fehler (`/tmp/PencilCAD_B20_Device_Full_55.xcresult`).
- Die neun vorhandenen Projektordner wurden vor der Installation gesichert.
- Signierter Release-Build erfolgreich; Build 20 auf dem iPad installiert und gestartet. Danach waren alle neun Ordner und 71 Dateien weiterhin vorhanden; SHA-256-Vergleich aller 71 Dateiinhalte: 0 Unterschiede.

## Offene Leistungsgrenze

- Beim ersten Aufruf der Nachbarrundung nach dem Öffnen kostete die Suche des früheren Kantenstands in diesem Projekt-8-Fall ca. 105 ms auf dem Hauptthread; spätere Werte nutzen den Cache (ca. 0,03 ms). Dieser erste Aufruf ist noch nicht verlagert.
- „Rundung vor Schnitt“ kann im Konturmodus nach 0,15 s Ruhe einen Verlaufsnachbau auf dem Hauptthread starten. Eine sichere Verlagerung braucht einen unveränderlichen Modell-Snapshot und serialisierte OCCT-Arbeit; sie ist noch nicht umgesetzt.
- Eine reale Stiftbewegung und ihre Bildrate wurden nicht automatisch gemessen. Der Build belegt keine vollständige Gleichwertigkeit mit Shapr3D.
