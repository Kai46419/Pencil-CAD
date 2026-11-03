# Build 22: Schwebepunkte und Hilfsgeometrie

## Ursache
Der voreingestellte SolidCraft-Zeichenmodus leitet `captureHovered` zu `togglePinnedPoint` um. Dieser Zweig erzeugt Fangspuren, ruft aber die Paarfunktion für Mittelpunkt und gestrichelte Mittellinien nicht auf.

## Änderung
Nach dem Merken eines neuen Fangpunkts im SolidCraft-Zeichenwerkzeug wird derselbe genaue Punkt auch an die bestehende Paarfunktion übergeben. Erneutes Schweben entfernt den Punkt aus der Fangspur und aus einem noch offenen Paar. Die klassische Eingabe bleibt unverändert.

Die Mittelsenkrechte des Punktpaars wird nur für die Anzeige bis zu beiden sichtbaren Viewporträndern verlängert. Die Verbindung der beiden gemerkten Punkte und alle gespeicherten Skizzendaten bleiben endlich.

Ein leiser Ton wird beim Wechsel auf einen neuen Punktfang ausgelöst (Ende, Mitte, Zentrum, Schnittpunkt, Körperecke). Ein eigener, standardmäßig aktiver Schalter steuert diesen Ton unabhängig vom Klick bei gleicher Länge und von der Haptik. Bei einem gemerkten Punkt wird zusätzlich ein eigenes Pencil-Feedback für das abgeschlossene Merken angefordert.

Bei dicht liegenden Konstruktionslinien und Endpunkten gewinnt der dem Stift nähere Schnittpunkt. Ein exakt getroffener Endpunkt bleibt vorrangig.

## Akzeptanz
- Im voreingestellten Zeichenmodus merkt ein schwebender Stift Endpunkte.
- Zwei verschiedene gemerkte Punkte erzeugen einen fangbaren Mittelpunkt und gestrichelte Verbindungs- und Mittellinie.
- Erneutes Schweben über denselben Punkt entmerkt ihn; kein Duplikat.
- Klassischer Stil sowie Fangspur-Ausrichtung bleiben funktionsfähig.
- Die gestrichelte Mittelsenkrechte bei einem 10-mm-Punktpaar erreicht den oberen und unteren sichtbaren Rand, wie bei größeren Punktabständen.
- Ein neu gefangener Punkt klickt einmal; fortlaufendes Schweben auf demselben Punkt klickt nicht erneut. Haptik wird beim Einrasten und beim Merken angefordert, soweit Stift und iPad das unterstützen.
- Der Schnitt zweier Konstruktionslinien ist auch bei einem nahen Linienende fangbar.
- Simulator- und iPad-Tests, Release-Build und Projektbestand werden geprüft.
