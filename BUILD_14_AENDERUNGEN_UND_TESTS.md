# PencilCAD Build 14 – Längenfang in der Skizze (30.10.2026)

## Änderungen gegenüber Build 13

- Neue Fangart **Gleiche Länge** im Fangmenü. Sie ist bei bestehenden Einstellungen zunächst aktiv und lässt sich einzeln abschalten.
- Beim Zeichnen einer geraden Linie rastet ihr Ende innerhalb eines bildschirmabhängigen Radius auf die Länge einer bereits vorhandenen geraden Linie derselben Skizze ein. Die aktuelle Richtung bleibt erhalten; waagerechte und senkrechte Linien bleiben exakt achsparallel.
- Solange der Fang greift, erscheinen Referenzlinie und Vorschau gelb, verbunden durch eine gelb gestrichelte Linie; ein `=` kennzeichnet den Fangpunkt. Beim Verlassen des Fangbereichs verschwindet die temporäre Markierung.
- Beim Absetzen erzeugt die App mit aktivierten automatischen Abhängigkeiten eine vorhandene `Gleiche Länge`-Bedingung. Ohne diese Option wird nur die Geometrie eingerastet.
- Punkt- und Kurvenfang sowie eingegebene Längen haben Vorrang. Der neue Längenfang überschreibt keine Tangente, Parallelität oder Rechtwinkligkeit.
- Der isolierte Abrundungs-Worker und seine Sperre nach einem Worker-Absturz aus Build 13 sind weiterhin enthalten.

## Verifikation

- Projekt mit OpenCASCADE und Blechmodul für Build 14 erzeugt; 167 App-Quelldateien im Xcode-Projekt geprüft.
- Vollständige App-Test-Suite im iPad-Simulator: **37 bestanden, 0 fehlgeschlagen** (`/tmp/PencilCAD-Build14-Sim.xcresult`).
- Vollständige App-Test-Suite auf dem verbundenen iPad: **37 bestanden, 0 fehlgeschlagen** (`/tmp/PencilCAD-Build14-iPad.xcresult`).
- Neue Tests prüfen die senkrechte Linie zu waagerechter Referenz samt gespeicherter Bedingung, eine schräge Linie zu senkrechter Referenz ohne automatische Bedingung, den Fangradius sowie den Vorrang von Punktfang und getippter Länge.
- Vor dem iPad-Test wurden sieben Projektordner und die Projektsicherungen separat kopiert.

## Grenzen

- Die Funktion gilt für den Standard-Eingabestil **SolidCraft** und gerade Skizzenkurven. Ein gesonderter Classic-Eingabepfad und Gleichheit mit Kreisumfang oder Bogenlänge sind nicht Teil dieses Builds.
- Die gelbe Markierung ist eine Live-Vorschau. Nach dem Absetzen bleibt die geometrische `Gleiche Länge`-Bedingung erhalten, sofern automatische Abhängigkeiten aktiv waren.
- Die schwierige Nutzergeometrie der mehrfach verrundeten Körper aus Build 13 ist weiterhin kein nachgewiesen erfolgreich abrundbarer Fall. Der native OCCT-Worker kann bei dieser Auswahl abstürzen; die App fängt seinen Ausfall ab und sperrt dieselbe Auswahl für die laufende Sitzung. Siehe `BUILD_13_AENDERUNGEN_UND_TESTS.md` und den beigefügten Worker-IPS-Bericht.
- Die Skizzenfarben wurden in Code und Build geprüft; eine manuelle Sichtprüfung der neuen Gelbmarkierung mit Apple Pencil ist noch offen.
