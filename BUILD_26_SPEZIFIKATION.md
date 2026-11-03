# Build 26 – Skizzieren und Fangpunkte

## Ziel

Bereich 1 der Vergleichsübersicht (Skizzieren und Fangpunkte) verbessern. Die hier
nachweisbare Lücke ist die ungenaue Berechnung von Kurvenschnitten im klassischen
Eingabestil. Die iPad-Bedienung soll in beiden Eingabestilen denselben geometrischen
Fangpunkt liefern.

## Abnahmefälle

1. Gerade/Kreis: Beide Schnittpunkte werden mit Koordinatengenauigkeit unter
   0,000001 mm gefangen, auch wenn der Stift leicht daneben schwebt.
2. Kreis/Kreis und Gerade/Bogen: Exakte Schnitte. Ein Schnitt außerhalb des
   Bogenverlaufs wird nicht angeboten.
3. „Auf Kurve“ hält Kreis und Bogen exakt ein; auch beim 0,001-mm-Raster liegt
   der gefangene Punkt auf der Kreisgeometrie.
4. Gezeichnete Konstruktionslinien bleiben für Schnittpunktfang verfügbar.
5. Hover und Werkzeugwechsel zum Kreis übernehmen den exakten Punkt.
6. Bestehende Tests für Mittellinien, Fangfeedback und gleiche Länge bleiben grün.
7. Simulator-Build und Testlauf; iPad-Build und Installation, soweit das verbundene
   Gerät verfügbar ist. Ergebnisse und Einschränkungen protokollieren.

## Umsetzung

`SnapIndex` verwendet für Schnittpunkte die schon vorhandenen Grundformen und
Schnittfunktionen von `SketchTrim` anstelle der visualisierten Polygonzüge. Für
„Auf Kurve“ projiziert er Kreis und Bogen direkt auf ihre analytische Geometrie.
Die Kostenbegrenzung und Prüfung der Ausdehnungen bleiben erhalten. Falls ein
Eingabetyp nur als Polygonzug existiert (Spline/Ellipse), bleibt dessen Annäherung.

## Grenze der Bewertung

Fünf Sterne erfordern über diese automatisierten Tests hinaus eine Bedienprüfung mit
Apple Pencil an komplexen Skizzen. Die Bewertung wird nur anhand belegter Fälle
angehoben; ein einzelner Build belegt keine vollständige Gleichwertigkeit zu Shapr3D.
