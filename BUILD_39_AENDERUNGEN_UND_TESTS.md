# Build 39: Festes Skizzenraster

## Ursache

Die U-Leiste zeigte eine feste Rasterweite, etwa 1 mm. Der voreingestellte Skizzenmodus „Automatisch (1-2-5)“ verwendete beim Fang aber weiterhin die vom Zoom abgeleitete Weite. Die Wahl in der U-Leiste änderte den Automatikmodus nicht.

## Änderung

- Eine ausdrückliche Rasterwahl in der rechten Leiste oder im Fangmenü schaltet „Automatisch (1-2-5)“ aus. Der Skizzenfang verwendet dann den gewählten Wert.
- Im automatischen Modus zeigt die Leiste „Auto“ statt eines scheinbar wirksamen festen Werts.
- Rasterweite und Automatikmodus werden zusammen je Projekt gespeichert. Eine ältere `grid.json` ohne Automatikfeld bleibt lesbar und wird als feste Wahl behandelt.

Das U-Raster bestimmt Fangpunkte beim Zeichnen. Für eine **exakt 1 mm lange Linie** ist die Längeneingabe oder eine Bemaßung erforderlich. Außerdem muss „Fang“ mit der Fangart „Raster“ aktiv sein.

## Prüfung

- Drei gezielte Simulator-Tests bestanden: tatsächlicher 1-mm-Fangpunkt; Speicherung nach erneutem Öffnen; ältere Rasterdatei.
- Signierter iPad-Build erfolgreich. `devicectl` bestätigt PencilCAD 0.1.0 (39); die App wurde gestartet.
- Vor der Installation wurden 163 Projektdateien gesichert. Ein Dateivergleich nach Installation und Start zeigt keine Änderung an den vorhandenen Dateien.
- `git diff --check` ohne Befund.

## Grenze

Der automatische Gerätetest belegt Installation und Start. Die Bedienung mit dem Apple Pencil am konkreten Projekt wurde noch nicht manuell geprüft. Die Bewertung für „Skizzieren und Fangpunkte“ bleibt deshalb bei 4/5 Sternen.
