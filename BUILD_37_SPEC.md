# Build 37: manuelle Längenmaße in technischen Zeichnungen

## Bedienung

Im Zeichnungsblatt „Längenmaß setzen“ wählen, zwei sichtbare Endpunkte derselben Ansicht antippen und das Maß zum Positionieren ziehen. Die Messart ist ausgerichtet, waagerecht oder senkrecht. Ein angetipptes Maß lässt sich löschen.

## Akzeptanz

- Die Maßzahl stammt aus den Modellkoordinaten einer Normansicht; der Blattmaßstab ändert den Wert nicht. Die Isometrie steht nicht zur Maßauswahl bereit, weil ihre projizierten Längen verkürzt sein können.
- Punkte aus verschiedenen Ansichten ergeben kein Maß.
- Vorschau, PDF und DXF enthalten dieselben manuell gesetzten Maße.
- Maße werden verworfen, wenn ihre Quellpunkte nach einer Neuberechnung nicht mehr auf derselben Ansicht liegen.
- Simulator Tests und iPad Test bestehen.
