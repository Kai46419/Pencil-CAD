# PencilCAD Build 35 – Blech 4/5

## Änderung

Beim Nachbau von „In Blech umwandeln“ wird die gespeicherte STEP-Quelle nicht mehr überschrieben. Die Umwandlung nutzt eine eigene Arbeitsdatei und veröffentlicht erst nach erfolgreicher Berechnung eine neue Quelle. Ein Fehler oder Zeitlimit lässt den bisherigen Projektstand unverändert; die Arbeitsdatei wird nach Ende der Hintergrundarbeit entfernt.

Der neue Quellpfad steht im Rezept des Blechkörpers. Abwicklung, spätere Blechschritte, Undo/Redo und Wiederöffnen verwenden damit den passenden Stand. Nicht mehr referenzierte Replay-Dateien werden nach dem Verwerfen einer Vorschau oder einer Modelländerung entfernt; vorhandene Originalquellen bleiben erhalten.

## Nachweise

- Rot vor der Korrektur: Änderung eines früheren Quaders überschreibt dieselbe Quelldatei; der Regressionstest meldet geänderte Dateibytes (`Pruefprotokolle/Build35_Red_Quelldatei_XCTest.log`).
- Grün danach: neue Quelle, alte Datei bytegleich, neues Flachmuster nach Wiederöffnen lesbar.
- Undo und Redo behalten jeweils die passende Quelle und ein lesbares Flachmuster.
- Verworfene Verlaufsvorschau entfernt ihre neue Quelle, ohne die gespeicherte Quelle zu verändern.
- Fehlgeschlagene Umwandlung entfernt ihre Arbeitsdatei und lässt die gespeicherte Quelle bytegleich.
- Simulator: 120 Tests, 0 Fehler (`Pruefprotokolle/Build35_Simulator_XCTest.log`).
- iPad: 120 Tests, 0 Fehler (`Pruefprotokolle/Build35_iPad_XCTest.log`).
- Signierter Release-Build 35 erstellt und geprüft (`Pruefprotokolle/Build35_iPad_Release_Build.log`), auf Kais iPad installiert und gestartet. `devicectl device info apps` meldet Build 35.
- Projektdateien vor und nach der Installation: 145 Dateien, keine geänderten, fehlenden oder neuen Dateien.

## Bewertung

Blech: **4/5 Sterne** für die vorhandenen Blechwerkzeuge und die jetzt geprüfte Datenkonsistenz der Umwandlung. Der fünfte Stern erfordert zusätzliche geometrische Abnahmen für komplexe Biegungen, benachbarte Freischnitte und Fertigungsabwicklungen. Direkte Stiftgesten wurden durch diese Tests nicht automatisiert geprüft.
