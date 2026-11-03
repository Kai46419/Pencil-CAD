# Build 31 – Untersuchung mehrerer Abrundungskanten

## Frage

Kann der mehrstufige `blendEdges`-Rückfall nach einem fehlgeschlagenen gemeinsamen Fillet ein gültiges, aber nur teilweise gerundetes Ergebnis liefern? Besonders zu prüfen sind `matchEdges` nach `unified(shape)` und das Überspringen einer nicht mehr auffindbaren Kante im schrittweisen Rückfall.

## Vorgehen

1. Mit einfacher Geometrie und den vorhandenen Projekt-6-/Projekt-8-STEP-Formen einen reproduzierbaren Fall suchen. Nur geometrische Ergebnisse und Testausgaben zählen als Befund.
2. Einen Test schreiben, der bei einem falsch akzeptierten Teilresultat fehlschlägt und eine gültige vollständige Rundung weiter zulässt.
3. Eine minimale Korrektur aus dem Befund ableiten; komplette Simulator- und iPad-Suite sowie gespeicherten Zustand prüfen.
4. Bei fehlender Reproduktion keinen unbewiesenen Kernel-Eingriff vornehmen; Untersuchung und Review-Paket liefern.

## Bewertung

Der Stand bleibt 3/5, bis eine konkrete Verbesserung auch auf dem iPad nachgewiesen ist. Der vierte Stern benötigt einen belastbaren mehrkantigen Ablauf an komplexer Anwendergeometrie sowie eine überprüfte Vorschau und Wiederherstellung.

## Befund und Änderung vom 3. November 2026

Der Hauptfehler tritt bereits beim ersten OCCT-Aufruf auf: `Add` verwirft eine nicht rundbare Kante einer Mehrfachauswahl, während `IsDone` einen gültigen Körper für die übrige Kante meldet. Der Zylinder mit Radius 10 mm und Höhe 20 mm reproduziert das mit oberer Kreiskante plus Mantelnaht bei Radius 2 mm. Dieselbe Teilbearbeitung trat bei einfacher Rundung, Fase, variabler Rundung, Radien je Kante und Fase mit zwei Abständen auf. Fünf Regressionstests schlugen vor der jeweiligen Korrektur fehl und bestanden danach. Ein zusätzlicher Test mit `Project8_AdjacentFilletInput.step`, Kanten 11 und 20, besteht.

`PCKShape.mm` verlangt jetzt in diesen fünf Pfaden für jede ausgewählte Kante eine OCCT-Kontur (`Contour(edge) > 0`). Rundungen prüfen außerdem `NbFaultyContours() == 0`. Die hier eingebundene OCCT-Version bietet diese zweite Methode nicht für Fasen; `validSolid` prüft weiterhin das Ergebnis. Die asymmetrische Fase weist eine Auswahl mit fehlender Nachbarfläche jetzt insgesamt zurück, statt diese Kante zu überspringen.

Ein bestehender Test zur zweiten Rundung nach einer großen ersten Rundung war falsch positiv: Kante 3 lässt sich einzeln runden, Kante 9 nicht; die alte gemeinsame Auswahl lieferte nur das Ergebnis von Kante 3. Der Test prüft nun die Ablehnung dieser Teilbearbeitung und weiterhin die vollständige Vernetzung der einzeln gültigen Rundung.

**Verifikation:** Simulator: 100 Tests, 0 Fehler (`/tmp/PencilCAD_B31_full_sim.log`). iPad Air: 100 Tests, 0 Fehler (`/tmp/PencilCAD_B31_full_ipad.log`). Der signierte Release-Build wurde mit `codesign --verify --deep --strict` geprüft, installiert und gestartet; `devicectl device info apps` meldet Build 31. Vor der Installation wurden 135 Dateien aus dem App-Dokumentenordner gesichert. Der Vergleich nach Start zeigte keine Änderung an bestehenden Dateien; Gerätetests legten zusätzliche Testprojektordner an. Dieser Fix belegt keine allgemeine Robustheit aller Mehrkantenrundungen oder Radiusbereiche; insbesondere der geometrische Rückfall über `unified` und `matchEdges` benötigt weitere gezielte Fälle.

Der externe Review `PencilCAD_Abrundung_Review_Build30_Antwort_neu.zip` war der Anlass für die Prüfung. Seine ursprüngliche Behauptung, `NbFaultyContours()` sei auch für `MakeChamfer` vorhanden, schlug beim Kompilieren fehl; die korrigierte ZIP-Version berücksichtigt dies. Der Patch wurde nicht blind übernommen, sondern durch lokale Regressions- und Gesamt-Tests abgeglichen.
