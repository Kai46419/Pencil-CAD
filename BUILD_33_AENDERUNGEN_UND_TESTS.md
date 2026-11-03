# PencilCAD Build 33 – Abrunden/Fasen 4/5

## Änderungen

- GitHub-Remote `https://github.com/Kai46419/Pencil-CAD.git` eingerichtet. Die vorher unabhängigen lokalen und entfernten Historien wurden mit einem Merge-Commit verbunden, der den lokalen Projektstand unverändert ließ.
- Der sequenzielle Kernel-Rückfall für mehrere gewählte Kanten prüft am Ende, ob jede ursprüngliche Kante tatsächlich bearbeitet wurde. Eine bloß gekürzte Nachbarkante gilt nicht als erfolgreich gerundet.
- Benachbarte Rundungen können jetzt auch dann in einem Feature zusammengefasst werden, wenn ein späterer Verlaufsschritt dazwischenliegt. Der Verlauf wird ab der früheren Rundung neu berechnet. Ein fester Snapshot stoppt die Suche, weil er eine ältere Änderung sonst überschreiben würde.
- Wenn die gemeinsame Eckrundung nicht gelingt, erscheint keine direkte Teilrundung als Ersatz. Die Einzelkantenauswahl bleibt Standard; tangentiale Kette und Flächenkontur bleiben ausdrückliche Auswahlmodi.

## Prüfungen

- Quader: drei Kanten an einer Ecke gemeinsam gerundet; Ergebnis ist ein gültiger geschlossener Körper.
- Projekt 8: benachbarte Rundung mit einem dazwischen eingefügten unabhängigen Körper neu berechnet, Vorschau übernommen und beide Körper erhalten. Ungültiger Radius zeigt keine Teilvorschau.
- Projekt 21: die vorhandenen Regressionen für gültige kleine Radien und ungültige 27,5 mm bleiben aktiv.
- Simulator und iPad: jeweils 113 Tests, 0 Fehler (`Pruefprotokolle/Build33_Simulator_XCTest.log`, `Build33_iPad_XCTest.log`).
- Signierter Release-Build 33 erstellt, Signatur geprüft, auf dem iPad installiert und gestartet. Die Dateien unter `Documents/Projects` sind vor und nach Installation bytegleich.

## Grenzen der 4/5-Wertung

Die Bewertung gilt für die genannten Eck-, Auswahl- und Verlaufsfälle. Ein geometrisch unmöglicher konstanter Standardradius wird weiterhin abgelehnt. Der Nachbau mehrerer komplexer Verlaufsschritte kann Zeit kosten; eine eigene Materialabnahme über den Standardfillet hinaus ist noch nicht vorhanden. Der Nutzer soll die neuen Eckenfälle zusätzlich mit dem Pencil an seinem Modell erproben.
