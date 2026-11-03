# Build 38: Abrundungsdialog und schwebendes Fenster

## Ziel

Die am iPad beobachtete Shapr3D-Bedienung als eigenständige PencilCAD-Oberfläche umsetzen. Zwei nacheinander gesetzte Rundungen bleiben getrennte, bearbeitbare Verlaufsschritte. Das bestehende schmale Eigenschaftenpanel bleibt wählbar.

## Abnahme

1. Im Abrundungsbefehl kann der Nutzer zwischen dem schmalen Panel und einem breiteren schwebenden Fenster wechseln. Das Fenster zeigt Auswahl, Maß, Rundungstyp, Stetigkeit und Vorschau lesbar an. Der Ansichtsbereich bleibt bedienbar.
2. Die Kantenwahl bleibt standardmäßig eine einzelne Kante. Tangentiale Ketten und ganze Flächen werden nur nach ausdrücklicher Wahl einbezogen.
3. Der Radius wird numerisch mit Dezimalstellen und Plus/Minus bedienbar. Bei zwei angrenzenden ebenen Flächen kann alternativ eine Sehnenbreite eingegeben werden; sie wird aus dem tatsächlichen Flächenwinkel in einen Radius umgerechnet und als bearbeitbares Maß im Verlauf gespeichert. Der Wert wird auch bei einer zweiten, angrenzenden Rundung an die bestehende Vorschau und den Verlauf übergeben.
4. Nicht vorhandene Kernel-Funktionen werden nicht als funktionsfähige Schalter ausgegeben: G2, alternative Ecken, Überlauf und Y-Blend benötigen gesonderte Geometriearbeit.
5. Simulator-Build und gezielte Rundungstests laufen. Ein Gerätetest wird gesondert ausgewiesen.

## Quellenlage

Shapr3D stellt öffentlich keine App- oder Parasolid-Kernquellen bereit. Autodesk veröffentlicht Fusion-API-Beispiele und Referenzen, nicht den Fusion-Modellierkern. Der hier verwendete Code ist eigenständig auf Basis des vorhandenen OCCT-Backends.
