# Build 38: Abrundungsfenster und Sehnenbreite

## Änderungen

- **Fenstermodus:** Abrunden öffnet standardmäßig ein 320-pt-Fenster neben der Ansichtsleiste. Im Panelmenü `…` schaltet „Schwebendes Fenster“ zwischen dieser Ansicht und dem bisherigen 160-pt-Panel um. Der scrollbare Inhalt ist im Querformat auf 380 pt begrenzt; OK und Abbrechen bleiben darunter fest stehen.
- **Kantenauswahl:** Einzelkante bleibt der Standard. Tangential, Kontur und Fläche sind ausdrückliche Wahlen im Panel.
- **Maßtyp:** Radius oder Sehnenbreite. Für Kanten zwischen zwei ebenen Flächen berechnet PencilCAD den Radius aus dem tatsächlichen Winkel der Flächennormalen (`Sehnenbreite = 2 × Radius × sin(Winkel/2)`). Bei ungeeigneten gekrümmten oder unterschiedlich geneigten Kanten erscheint eine Fehlermeldung, statt einen falschen Wert zu verwenden. Plus/Minus verändert das angezeigte Maß in Schritten von höchstens 0,1 mm, bei feinerem Raster entsprechend feiner.
- **Verlauf:** Bei einer einzeln gespeicherten Rundung bleiben Sehnenbreite und Umrechnungsfaktor erhalten. Die Sehnenbreite wird beim Bearbeiten gezeigt und ein geänderter Wert vor dem Nachbau wieder in den Radius übersetzt. Eine mit einer vorherigen Rundung zu einem Mehrfachradius verschmolzene Rundung bleibt im Radiusmodus.
- **Leistung:** Die Flächen einer Kantenauswahl werden einmalig zugeordnet; beim Ziehen des Pfeils wird der Winkel pro unverändertem Körper wiederverwendet.

## Prüfung

- `xcodebuild` Simulator und signierter Gerätebuild: erfolgreich.
- Drei gezielte Simulator-Tests: Sehnenbreite am 90°-Quader; Sehnenbreite im gespeicherten, erneut berechneten Verlauf; zweite angrenzende Rundung. Alle bestanden.
- Build 38 wurde auf „iPad von Kai“ installiert; `devicectl` meldet Version 0.1.0, Build 38, und der App-Start gelang.
- Vor der Installation wurden die PencilCAD-Dokumente gesichert (154 Dateien). Ein Dateivergleich nach der Installation zeigt keine fehlenden oder geänderten bisherigen Dateien; beim Start kam ein neues Projektverzeichnis hinzu.
- `git diff --check`: ohne Befund.

## Grenzen

- G2-Krümmungsstetigkeit, Setback-Ecken, Überlaufarten, Krümmungsprofil und Y-Blend sind geometrisch nicht implementiert. Der G2-Schalter bleibt deaktiviert. Diese Funktionen erfordern eigene Kernel-Arbeit; Shapr3D bietet sie laut Produktdokumentation.
- Sehnenbreite ist für eine kreisförmige G1-Rundung zwischen zwei ebenen Flächen definiert. Für eine angrenzende Kante auf einer bereits verrundeten Fläche ist weiterhin der Radiusmodus nötig.
- Der automatische Gerätetest belegt Installation und Start, nicht die manuelle Bedienung der neuen Fensteransicht oder alle komplexen OCCT-Rundungsfälle. Die Bewertung „Abrunden und Fasen“ bleibt daher bei 4/5 Sternen.

## Öffentliche Quellen

- Shapr3D-Dokumentation zu Rundungsoptionen: <https://support.shapr3d.com/hc/en-us/articles/7874402399900-Chamfer-Fillet>
- Öffentliche Shapr3D-Repositories: <https://github.com/shapr3d> (kein veröffentlichtes CAD-App- oder Parasolid-Kernrepository gefunden).
- Autodesk-Fusion-API-Beispiele: <https://github.com/AutodeskFusion360> (API/Add-ins; kein Fusion-Modellierkern).
