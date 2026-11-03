# PencilCAD Build 29

Build 29 verbessert die Zuverlässigkeit von Extrusion, Drehen, Sweep und Loft. Die vollständige Test- und Änderungsliste steht in `BUILD_29_AENDERUNGEN_UND_TESTS.md`.

Das Projekt-ZIP enthält den Quellcode, das generierte Xcode-Projekt und die benötigten Vendor-Dateien. Die separat gelieferte IPA ist signiert. Build 29 ist auf Kais iPad per USB installiert und gestartet; die vollständige Testsuite bestand dort. Die 135 zuvor vorhandenen iPad-Dokumente sind nach den Tests bytegleich vorhanden.

Für einen zusätzlichen manuellen Pencil-Test: Skizzenprofil extrudieren, eine Bohrung und einen Boolean anwenden, Körper spiegeln oder mustern, speichern, die App schließen und das Projekt erneut öffnen. Danach Geometrie und Verlauf mit dem Zustand vor dem Schließen vergleichen. Die 4/5-Bewertung beruht auf den automatisierten 3D- und Regressionstests auf dem echten iPad; sie behauptet keine fehlerfreie Bearbeitung beliebig komplexer Modelle.
