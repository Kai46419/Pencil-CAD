# Build 12: Absturzpfad der Maximalradius-Suche entfernen

## Befund

Der iPad-Absturzbericht vom 30.10.2026, 22:55:52 Uhr, zeigt `EXC_BAD_ACCESS` im Thread `PencilCAD.blend`. Der Stack führt über `BlendKernel.run` zu `PCKShape.maximumBlendForEdges` und dort zu `BRepFilletAPI_MakeFillet::Build`. Die automatische Maximalradius-Suche probiert bei einem zuvor gescheiterten Abrunden weitere Radien; einer dieser Versuche löste den Kernel-Absturz aus. Das betroffene Projekt ist als Kopie gesichert.

## Änderung

1. Interaktive Abrundung und Fase rechnen nur den vom Nutzer verlangten Wert. Nach einem Fehlschlag erfolgen keine zusätzlichen Suchversuche nach einem Maximalwert und keine automatische Reduktion des Werts.
2. Derselbe Suchpfad wird im vorgezogenen Verlaufsschritt „Rundung vor Schnitt“ entfernt. Die OCCT-API für die riskante Suchfunktion wird entfernt, damit sie nicht versehentlich erneut aufgerufen wird.
3. Bei einem geometrisch unmöglichen Wert bleibt der Körper unverändert; das Werkzeug meldet den Fehlschlag. „Fertig“ übernimmt kein nicht vorhandenes Vorschauergebnis.

## Abnahme

- Keine Aufrufstelle von `maximumBlend` im App-Code.
- Kerntests, iPad-Simulator und physisches iPad bestehen.
- Ein Test mit absichtlich unmöglichem Radius ergibt einen Fehlschlag ohne Absturz und ohne stilles Klemmen auf einen anderen Radius.
- Signierte App ohne Testmodul wird auf dem iPad installiert; der Projektbestand wird vorher und nachher verglichen.

## Grenze

Ein direkter OpenCASCADE-Aufruf für den konkret angeforderten Radius kann bei anderen unbekannten problematischen Formen weiterhin abstürzen. Der belegte zusätzliche Absturzpfad der automatischen Maximalsuche wird entfernt; eine allgemeine Garantie für alle möglichen CAD-Geometrien wäre unbelegt.
