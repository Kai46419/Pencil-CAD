# Build 68 – Auswahl verschieben, drehen, skalieren (Skizzenmodus)

Kai: Rechteck zeichnen, mit „Auswählen“ antippen – es ließ sich weder verschieben noch drehen noch skalieren.

- Gewählte Elemente bekommen einen gestrichelten Rahmen mit Griffen wie ein Text:
  - Kreuz in der Mitte bzw. Ziehen in der leeren Rahmenfläche: verschieben (Fang an Punkten, sonst Raster)
  - Pfeil rechts oben: gleichmäßig skalieren (Ecke links unten bleibt, 1-%-Schritte)
  - Griff oberhalb: drehen um die Rahmenmitte (15°-Schritte rasten ein)
- Kanten und Ecken ziehen wie bisher (Größe ändern); der Finger verschiebt in der Fläche weiter die Ansicht und
  greift nur die drei Knöpfe.
- Rechte Leiste „Auswahl › Lage“: X, Y, Skalieren (%), Drehen (°), ±90°.
- Elemente, die über Bedingungen an der Auswahl hängen, gehen mit. Maße (Abstände, Radien) werden beim Skalieren
  mitskaliert, Formeln werden dabei feste Werte. Waagerecht/Senkrecht bleiben nur bei Vierteldrehungen.
- Schräg gedrehtes Rechteck → geschlossener Linienzug mit drei Senkrecht-Bedingungen (bleibt ein Rechteck).
- Verankerte Elemente in der Gruppe: es wird nichts bewegt, Hinweis zum Lösen.

Dateien: `App/Model/SketchSelectionTransform.swift` (neu), `App/Workspace/SketchSelectionTransformPanel.swift` (neu),
`App/Model/Sketch.swift`, `App/Viewport/Viewport.swift`, `App/Workspace/SketchSelectionProperties.swift`.
Nicht auf dem Mac kompiliert (Linux-Sitzung) – geprüft über den Xcode-Cloud-Build.
