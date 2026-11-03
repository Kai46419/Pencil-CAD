# PencilCAD Build 11 – tangentiale Kanten (30.10.2026)

**Zurückgezogen:** Trotz bestandener Tests stürzte Build 11 am 30.10.2026 um 22:55:52 Uhr bei der automatischen Maximalradius-Suche nach einem gescheiterten Abrundungsversuch ab. Der iPad-Bericht zeigt `EXC_BAD_ACCESS` in `PCKShape.maximumBlendForEdges` → `BRepFilletAPI_MakeFillet::Build`. Der nachfolgende Build 12 entfernt diesen Suchpfad. Build 11 nicht erneut installieren.

## Änderungen

- Abrunden und Fasen bieten „Einzelkante“, „Tangential“ und „Kontur“. „Einzelkante“ ist die Vorgabe; die anderen Modi werden ausdrücklich gewählt.
- Der OCCT-Adapter verfolgt eine tangentiale Kantenkette über gemeinsame Eckpunkte. Zwei Kanten werden nur verbunden, wenn sie mindestens eine gemeinsame Fläche besitzen und ihre Tangenten am Treffpunkt höchstens 3° auseinanderliegen. Eine rechtwinklige Ecke stoppt die Kette.
- Die Auswahl wird bei Moduswechsel geleert, damit keine Kante aus dem vorigen Modus unbemerkt mitbearbeitet wird.
- Die automatische Ergänzung zusammenhängender Teilstücke ist für die Fase im Modus „Einzelkante“ abgeschaltet. Im Modus „Kontur“ bleibt sie möglich.

## Prüfung

- Kerntests auf dem Mac: 84 bestanden, 0 fehlgeschlagen.
- App-Tests im iPad-Simulator: 29 bestanden, 0 fehlgeschlagen.
- App-Tests auf dem physischen iPad: 29 bestanden, 0 fehlgeschlagen.
- Integrationstests decken zwei kollineare Teilkanten, einen tangentialen Übergang zu Halbkreisen, das Stoppen an einer 90°-Ecke, die Auswahlmodi beim Abrunden und Fasen sowie das erneute Abwählen ab.
- Die signierte App-Version 11 wurde ohne Testmodul auf dem physischen iPad installiert und gestartet.
- Vor der Build-11-Prüfung lagen auf dem iPad fünf Projektordner; eine vollständige Kopie wurde erstellt. Die Projektordner sind nach Tests sowie nach Installation und Start bytegleich. Kein Projekt wurde entfernt.

## Vergleich mit Shapr3D

Das gezielte Einbeziehen tangentialer Kanten ist nun in beiden Werkzeugen vorhanden. [Shapr3D dokumentiert darüber hinaus](https://support.shapr3d.com/hc/en-us/articles/7874402399900-Chamfer-Fillet) G2-Stetigkeit, Sehnenbreite, Ecktypen, Überlaufarten, Krümmung und Y-förmige Übergänge. Diese Optionen sind in PencilCAD weiterhin nicht als geprüfte, vollständige Geometriefunktionen verfügbar. Auch die Auswahl mehrerer deckungsgleich dargestellter Kanten und größere Radien an komplexen Körpern bleiben offen.

Die Tests prüfen Kern und Werkzeuglogik. Eine automatisierte Prüfung der Finger-/Stiftinteraktion mit dem neuen Segment im Panel liegt noch nicht vor.

Die aktuelle Änderung ist eigenständig implementiert. Es wurde kein Shapr3D-Quellcode übernommen. Produktparität ist mit Build 11 nicht erreicht.
