# Prüfbericht – 30.10.2026

## Ergebnis

**84 Kerntests und 6 App-Tests bestanden, 0 fehlgeschlagen. Vollständiger iOS-Simulator-Build
erfolgreich; App im iPad-Pro-Simulator gestartet und Startseite visuell geprüft.**
Ein Test auf einem echten iPad fand noch nicht statt.

Geprüft wurde auf einem Apple-Silicon-Mac mit Xcode 27.1 (Build 27A9275), Swift 6.4 und iOS-Simulator-SDK 27.1.
Die App ist weiterhin für iPadOS 17 oder neuer konfiguriert. Die fehlende Metal-Toolchain wurde
im Laufe dieser Sitzung mit `xcodebuild -downloadComponent MetalToolchain` installiert. Der
erfolgreiche vollständige Build lief mit einer Kopie des Projekts aus dem hochgeladenen Archiv
unter `/private/tmp`, auf die die aktualisierten Dateien übertragen wurden. Das erzeugte Paket
enthält denselben aktualisierten Quellstand und das geprüfte Xcode-Projekt.

## Ausgeführte Prüfungen

| Prüfung | Ergebnis | Aussagegrenze |
| --- | --- | --- |
| `bash scripts/test-core.sh` | Exit 0; 84 PASS, 0 FAIL | Native Ausführung auf macOS, kein OCCT und keine iPad-Oberfläche. |
| Kontrollversuch mit den ursprünglichen Dateien `Expressions.swift`, `ProjectUnits.swift`, `SketchLocalSolver.swift` | Exit 1; bei damals 81 Tests 67 PASS, 14 FAIL | Gezielt drei alte Dateien eingesetzt, keine vollständige Ausführung des ursprünglichen App-Pakets. |
| `bash scripts/check-source.sh` | Exit 0; 164 Swift-Dateien syntaktisch gültig | Kein Typcheck, kein Linken, kein Laufzeittest. |
| iPad-Pro-Simulator, Xcode-Schema `PencilCAD`, `test` | Exit 0; 6 Tests, 0 Fehler | Maßänderung/Undo, Konflikt, 200er-Stapel, ungültige Extrusion, OCCT-Volumen. Kein Hardwaretest. |
| OCCT-Adapter mit iOS-SDK und vorhandenen Simulator-Headern | `clang++ -fsyntax-only` Exit 0 | Objective-C++-Syntax/Typen zusätzlich isoliert geprüft. |
| `bash -n` für die neuen/geänderten Prüf- und Generierungsskripte | Exit 0 | Shell-Syntaxprüfung. |
| Projektgenerator mit OCCT-Konfiguration | Exit 0 | Neue Produktionsdateien und Testziel im Projekt registriert. |
| `plutil -lint PencilCAD.xcodeproj/project.pbxproj` | OK | Strukturell gültige Projektdatei, kein Buildnachweis. |
| Vollständiger Simulator-Build nach Installation der Metal-Toolchain | Exit 0; `BUILD SUCCEEDED` | arm64, Signierung aus, Debug-Dylib aus; kein echter iPad-Build. |
| Erneuter Simulator-Test nach Layoutkorrektur | Exit 0; `TEST SUCCEEDED`, 6 Tests, 0 Fehler | Hat die letzte Quelländerung neu übersetzt und getestet. |
| `simctl launch` und Startseiten-Screenshot nach Layoutkorrektur | Exit 0; App startete und Titel/Schaltflächen wurden betrachtet | Sichtprüfung nur der Startseite; keine manuelle CAD-Bedienfolge. |
| Frühere Einzeltypprüfung unter beschränkter Ausführung | Exit 1 | Xcode-Makroprozess konnte dort nicht starten; der spätere vollständige Build übersetzte diese Quellen. |
| Frühere Builds vor Installation der Metal-Toolchain | Exit 65 | Historischer Zwischenstand; die spätere vollständige Prüfung war erfolgreich. |

Die rohe Ausgabe der wichtigsten Prüfungen und ein Screenshot liegen unter `Pruefprotokolle/`.
Das leere `kernel-syntax.log` bedeutet, dass der erfolgreiche Compileraufruf keine Diagnosen ausgegeben hat.
Der Exit-Status wurde zusätzlich aus dem abgeschlossenen Prozess geprüft.

## Kerntests im Detail

- Rechenregeln, Vorzeichen/Potenzen, Dezimalkomma, Exponentialschreibweise, implizite Multiplikation,
  Funktionsaliasnamen, ungültige Ausdrücke und Variablenzyklen.
- Längen in mm und Zoll, explizite Einheiten, Variablenwerte und Überlauf nach der Einheitenumrechnung.
- Offene Bögen/Splines, Rechteck und geschlossene Linien-/Bogenkonturen, Ringe, degenerierte
  Spline-Versätze und Triangulierung eines Polygons mit Loch.
- Extrusionsstart/-länge für positive, negative, symmetrische und zweiseitige Richtung;
  Schnittüberstand einschließlich Flächennormale; Null/NaN/Unendlich/Überlauf.
- Globale und lokale Constraint-Lösung, ungültige Referenzen, fremde verletzte Sperren,
  unveränderte unbeteiligte Geometrie, suspendierte Bedingungen, widersprüchliche Maße und Linienanschlüsse.
- ASCII- und Binär-STL, Binärdatei mit `solid`-Kopf, ungültige Koordinaten, unvollständige Daten.
- 3MF mit Zoll/Transformation, gespeichertes und Deflate-komprimiertes Archiv, defektes XML,
  ungültige Transformationen/Referenzen und CRC32-Fehler.
- Extreme ZIP-Offsets/-Größen und übermäßige entpackte Größe ohne Absturz.

Die Tests kompilieren die entsprechenden Original-Produktionsdateien zusammen mit dem Testprogramm.
Es gibt keine Ersatzimplementierung des Lösers, Parsers oder der Geometrie.

## Aussage der Gegenprobe

Mit den drei gezielt zurückgesetzten Dateien schlagen 14 Tests fehl, die mit den aktualisierten Dateien
bestehen. Darunter: `1e-3` wurde vorher als ungefähr -0,281718 statt 0,001 interpretiert;
`-2^2` ergab 4 statt -4; `sign(acos(2))` akzeptierte ein ungültiges Zwischenergebnis.
Der lokale Löser akzeptierte außerdem eine gelöschte Fremdreferenz, einen ungültigen fremden Punkt
und eine unerfüllte fremde Sperre. Das sind reproduzierte Verhaltensunterschiede.

## Noch nicht verifiziert

- Pencil-Gesten, vollständige Icon-/Layoutdarstellung, Echtzeitvorschau, Performance und Speicher auf dem echten iPad.
- End-to-End-Speichern, Öffnen, Historien-Replay, STEP-Austausch und umfangreiche reale Nutzermodelle.
- Blechmodul-Build und Rust-Tests; die passende vorgebaute PencilSheet-Bibliothek fehlt im Upload.

Der erfolgreiche Simulator-Build und die sechs App-Tests sind tatsächlich ausgeführt.
Sie belegen nicht die Abnahme sämtlicher CAD-Funktionen und nicht die Hardwaretauglichkeit.
