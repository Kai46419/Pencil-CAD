# Build 39: festes Skizzenraster wirkt beim Zeichnen

## Befund

Die U-Leiste zeigte z. B. „1 mm“, während der voreingestellte Skizzenstil wegen `gridAuto = true` weiterhin die zoomabhängige Rasterweite verwendete. Eine explizite Auswahl änderte nur `gridStep`, nicht den aktiven Modus.

## Abnahme

1. Die Wahl eines festen U-Rastermaßes deaktiviert „Automatisch (1-2-5)“ in beiden rechten Leisten und im Fangmenü.
2. Die Leiste zeigt „Auto“, solange das zoomabhängige Raster aktiv ist; ein fester Wert wird nur im festen Modus als wirksam angezeigt.
3. Rasterweite und Automatikmodus überstehen das Schließen und erneute Öffnen eines Projekts. Bestehende `grid.json`-Dateien bleiben lesbar; bei einem bisher gespeicherten Wert ohne Modus gilt der Wert als feste Nutzerwahl.
4. Ein Test prüft den tatsächlichen Fangpunkt im SolidCraft-Eingabestil bei 1-mm-Raster und die Persistenz.

Das Raster steuert Fangpunkte beim freien Zeichnen. Es legt keine Linienlänge als geometrische Bedingung fest; dafür bleibt das Längenmaß zuständig.
