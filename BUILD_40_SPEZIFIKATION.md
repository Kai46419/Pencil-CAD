# Build 40: Linienlängen folgen der festen U-Schrittweite

## Befund

Das U-Raster rundet bislang die X- und Y-Koordinaten eines Fangpunkts. Bei einer schrägen Linie ist deren Länge `sqrt(dx² + dy²)` und kann deshalb trotz 1-mm-Raster z. B. 1,0458 mm betragen.

## Gewünschtes Verhalten

1. Im Skizzenmodus folgt eine neu gezeichnete freie **Linie** der ausdrücklich gewählten U-Schrittweite: 1 mm → ganze Millimeter, 0,5 mm → halbe Millimeter, 0,01 mm → Hundertstelmillimeter. Die Richtung des Stifts bleibt erhalten.
2. Die Live-Vorschau und die gespeicherte Linie haben denselben Endpunkt und dieselbe Länge. Das gilt für Klickfolge und klassischen Ziehstil.
3. Ein exakt eingetipptes Längenmaß sowie Fänge auf vorhandene Punkte, Kurven, Schnittpunkte, Gleichlänge oder geometrische Ausrichtungen haben Vorrang. Das Abschalten von „Fang“ bzw. das Drücken zum Unterdrücken des Fangs lässt die Linie frei.
4. Der automatische 1-2-5-Modus bleibt zoomabhängig und wird durch diese Änderung nicht als feste Längenvorgabe ausgegeben.

## Abnahme

Gezielte Tests prüfen schräge Linien bei 1 mm und 0,1 mm, Vorschau gegen gespeicherte Geometrie, exakte Eingabe und Vorrang eines vorhandenen Endpunkts. Build und Installation auf dem verbundenen iPad werden separat geprüft.
