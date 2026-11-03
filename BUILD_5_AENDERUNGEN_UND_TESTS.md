# PencilCAD Build 5 – Änderungen und Prüfstand (30.10.2026)

## Stand auf dem iPad

Build 5 (`de.kai46419.pencilcad`, Version 0.1.0) wurde auf Kais iPad Air M4 mit iPadOS 26.5 installiert und gestartet. Vor der Installation wurde der App-Datencontainer gesichert. Ein Vergleich der Dokumente vor dem Update und nach Installation, Tests und erneutem Start ergab 227 Dateien auf beiden Seiten, ohne fehlende Pfade oder geänderte SHA-256-Prüfsummen. Die Sicherung ist eine getrennte ZIP-Datei; sie gehört nicht in das Quellprojekt.

## Änderungen seit dem ersten Sammelupdate

- Der mitgelieferte OpenCASCADE-Kernel wurde von 7.7.2 auf 8.0.1 aktualisiert, jeweils für iPad und Apple-Silicon-Simulator. Die Objective-C++-Brücke wurde an die geänderte Iterator-API angepasst. Das Neubau-Skript verwendet ebenfalls `V8_0_1` und das dazugehörige STEP-Toolkit `TKDESTEP`.
- 107 Werkzeugbilder stammen aus den SVG-Quellen von SolidCraft. Der genaue Quellstand, die Lizenz und fünf Befehlszuordnungen stehen in `SOLIDCRAFT_ICONS.md`. Das App-Symbol wurde passend dazu abgeleitet.
- Nach dem erneuten Öffnen eines Projekts baut die Zeitleiste einen noch nicht zwischengespeicherten früheren Stand aus den gespeicherten Features wieder auf. Das Antippen eines Schritts setzt die Vorschau auf diesen Stand.
- Beim Ziehen eines 3D-Pfeils gilt die im U-Menü gewählte Rasterweite, sofern Raster-Fang aktiv ist. So kann auch 0,001 mm gewählt werden. Ohne Raster-Fang bleibt die zoomabhängige Schrittweite; die Konizitätssteuerung behält ihren Winkelmaßstab. Der Zahlenwert lässt sich weiterhin direkt eingeben.
- Bei der Vorschau einer einzelnen Flächenextrusion wird nun dieselbe normale Netzauflösung wie bei der späteren Darstellung verwendet. Der zuvor gemeldete Ruckler war schon vor Build 5 nicht mehr reproduzierbar; eine messbare Verbesserung durch diese Änderung ist daher nicht belegt.
- Eine seltene Abrundung konnte eine vorhandene obere Fläche ohne Anzeigedreiecke zurücklassen. Nur in diesem Fall wird die Form über STEP neu aufgebaut und ausschließlich übernommen, wenn sie geschlossen bleibt, die Flächenzahl gleich ist, die Hülle um höchstens 0,01 mm abweicht, das Volumen um höchstens 0,3 % abweicht und anschließend alle Flächen triangulierbar sind.

## Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Vollständiger Build für iOS-Simulator | erfolgreich |
| Eigenständige Kerntests auf dem Mac | 84 bestanden, 0 fehlgeschlagen |
| App-Tests im Simulator | 9 bestanden, 0 fehlgeschlagen |
| Vollständiger Build für physisches iPad | erfolgreich, signiert |
| App-Tests auf dem iPad | 9 bestanden, 0 fehlgeschlagen |
| Start auf dem iPad | erfolgreich |
| Dokumente vor/nach Installation und Tests | 227/227, keine fehlende oder geänderte Datei |
| App-Version auf dem iPad | Build 5 bestätigt |
| Nachstellung der fehlenden Deckfläche aus Projekt 27 im Simulator | vorher 0, nach dem bedingten STEP-Neuaufbau 44 Anzeigedreiecke auf der oberen Fläche |

Die App-Tests decken unter anderem eine zweite Abrundung an einer angrenzenden Kante, das Vorhandensein aller 107 Icon-Ressourcen, eine Kernel-Extrusion mit Volumenprüfung und das Zurückspringen in einen früheren Verlaufsschritt nach gelöschtem Zwischenspeicher ab. Das ursprüngliche iPad-Absturzszenario mit genau denselben Gesten wurde nicht erneut auf dem Gerät ausgeführt. Der Projekt-27-Nachstelltest verwendete eine private Kopie der Geometrie und liegt nicht im Quellpaket.

## Bekannte Grenzen

- Der helle schmale Keil an der gerundeten Verbindung aus dem zweiten Screenshot ist nach dem erneuten Öffnen sichtbar. Ein zusätzlicher Test der gespeicherten Projekt-27-Geometrie fand zwei winzige Überlappungen zwischen Körper 1 und Körper 2/3 (0,0064 und 0,0135 mm³) an den äußeren Enden. Solche Überlappungen können Anzeige-Artefakte verursachen; ob sie genau den fotografierten Keil erklären, ist nicht belegt. Die Körper wurden daher nicht automatisch verändert.
- Größere Rundungsradien werden versucht, aber der Kernel kann bestimmte Kantenkombinationen geometrisch nicht mehr lösen. Es gibt keine pauschale künstliche Obergrenze für alle Abrundungen; ein Fusion-ähnliches Auflösen bis zum vollständigen Verschwinden eines Körpers ist nicht implementiert.
- Der bedingte STEP-Neuaufbau änderte bei der Projekt-27-Nachstellung das Volumen um rund 0,22 %. Das liegt unter der Übernahmeschwelle, ist aber keine mathematisch identische B-Rep.
- Ein gebautes `PencilSheet.xcframework` ist nicht enthalten. Der Rust-Quelltext des Blechmoduls bleibt im Projekt.
- Die neun App-Tests sind gezielte Regressionstests, keine vollständige Abnahme aller CAD-Werkzeuge oder aller alten Projekte.

## Paket

Das Quellprojekt enthält Xcode-Projekt, App-Code, Tests, 107 SolidCraft-Assets und die zwei benötigten OCCT-Framework-Slices. `Vendor/OCCT.xcframework` muss im ZIP ein echtes Verzeichnis sein, kein externer Symlink. Die signierte IPA ist für den Test auf dem bereits registrierten iPad bestimmt. Eine Weitergabe an beliebige iPads erfordert eigene Signierung.
