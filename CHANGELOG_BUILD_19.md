# PencilCAD Build 19 – 31.10.2026

## Änderung

- Beim Ziehen eines Modellpfeils werden unveränderte gerastete Werte nicht erneut an den Workspace weitergegeben. Damit entfallen unnötige Viewport-Aktualisierungen und Aufrufe des Modellbefehls pro Touch-Ereignis.
- Abrunden und Fasen vergleichen den auf vier Nachkommastellen angezeigten Wert mit dem aktuellen Befehlswert, bevor sie die OCCT-Vorschau neu anfragen.
- Die 0,1-mm-Schritte für Radius und Fasenbreite aus Build 18 bleiben erhalten.

## Prüfung

- Neuer Regressionstest: Bei Abrunden und Fasen löst derselbe gerastete Wert keinen weiteren Blend-Job aus; ein neuer Wert schon.
- Simulator: 52 Tests, 0 Fehler (`/tmp/PencilCAD_B19_Sim_Full.xcresult`).
- iPad: 52 Tests, 0 Fehler (`/tmp/PencilCAD_B19_Device_Full.xcresult`).
- Die neun Projektordner des iPads wurden vor der Installation gesichert.

## Grenze der Prüfung

Automatisierte Tests prüfen Kernel-Anfragen und Funktion, aber keine subjektive Bildrate beim Ziehen. Ein kurzer Vergleich am iPad mit einer komplexen Rundung ist für die Beurteilung des Ruckelns noch erforderlich.
