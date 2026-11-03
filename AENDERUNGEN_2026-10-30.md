# Änderungsprotokoll – 30.10.2026

Grundlage: der tatsächliche Dateianhang `PencilCAD_Komplett_Aktuell.zip` aus dem referenzierten Chat.
Alle Änderungen erfolgten in einer separat entpackten Arbeitskopie.

## 1. Skizzenbedingungen und Maßänderungen

`SketchLocalSolver.swift` prüft aktive Referenzen vor den lokalen Versuchen. Eine lokale Lösung muss
anschließend sämtliche aktiven Originalbedingungen erfüllen. Zuvor wurden nur Bedingungen berücksichtigt,
die den lokalen Ausschnitt berührten. Eine ungültige Referenz oder eine verletzte Sperre an einem anderen
Element konnte dadurch trotz der zuvor eingebauten Schutzmaßnahmen im globalen Löser unbemerkt bleiben.

`SketchConstraints.swift` stellt dafür die gemeinsame Prüfung `satisfies` bereit. Suspendierte Bedingungen
bleiben ausgenommen. Die bestehende numerische Toleranz von 1e-5 wird für die Erfüllungsprüfung verwendet.
Die Gegenprobe mit dem alten lokalen Löser weist drei entsprechende Regressionen nach.

`Sketch.swift` behandelt die Änderung eines Elementmaßes mit Erfolg-/Fehlschlag-Rückgabe. Eine neue
Formel wird erst bei erfolgreicher Änderung übernommen. Bei Fehler werden Geometrie, Bedingungen,
Linienzug-Ende und Rückgängig-Stapel zurückgestellt. Beim vollen 200er-Stapel wird die tatsächlich neueste
Momentaufnahme berichtigt; die frühere Prüfung über eine wachsende Stapellänge war dort wirkungslos.
Beim Ändern bestehender treibender Maße wird der Rückgängig-Schritt erst nach erfolgreichem Lösen angelegt.
Ein fehlgeschlagener Versuch verdrängt somit keinen alten Schritt mehr.

Diese Controller-Änderungen wurden mit sechs App-Tests im iPad-Pro-Simulator geprüft;
alle sechs bestanden. Die Tests des eigentlichen lokalen Lösers wurden ebenfalls ausgeführt.

## 2. Zahlen, Formeln und Einheiten

`Expressions.swift` unterstützt wissenschaftliche Schreibweise, etwa `1e-3` und `2,5E+2`.
Ein führendes Dezimalkomma wie `,5` wird akzeptiert. Eine Variable oder Konstante vor einer Klammer
wird multipliziert: `breite(2+1)` bzw. `pi(2)`. Bekannte Funktionen werden weiterhin als Funktionsaufrufe gelesen.

Potenzen binden stärker als ein führendes Minus: `-2^2` ergibt -4, `(-2)^2` ergibt 4.
Negative Exponenten und rechtsassoziative Potenzen wie `2^3^2` bleiben möglich.
Alle unterstützten Funktionsaliasnamen sowie π sind als Variablennamen reserviert.
NaN/Unendlich gelten nicht mehr als einfache Zahl; nichtendliche Funktionsargumente werden zurückgewiesen.
`ProjectUnits.swift` prüft zusätzlich das Ergebnis nach Umrechnung in Millimeter auf Überlauf.

**Kompatibilität:** Bereits gespeicherte Formeln mit `-a^b` können beim nächsten Auswerten ein anderes,
mathematisch übliches Ergebnis liefern. Wer ausdrücklich die negative Basis meint, schreibt `(-a)^b`.
Die bisher mehrdeutige Schreibweise `2e3` ist jetzt die Zahl 2000; für eine Variable namens `e3` ist
`2 * e3` zu verwenden. Dezimalkomma bleibt erlaubt; Funktionsargumente am eindeutigsten mit `;` trennen.
Der Parser ist weiterhin keine vollständige physikalische Dimensionsalgebra.

## 3. Extrusion

Die Berechnung von Start und Länge liegt unverändert in ihrer bisherigen Bedeutung in `ExtrusionSpan.swift`.
Sie wird jetzt unabhängig vom iPad und Kernel ausgeführt getestet: positive/negative Extrusion,
Schnittüberstand, Flächennormale, symmetrische und zweiseitige Richtung sowie Zahlenüberläufe.

`SketchExtrusion.swift` weist NaN/Unendlich und Verjüngungswinkel ab 90° Betrag zurück.
Ohne OCCT werden Profile mit Löchern oder Verjüngung abgewiesen, statt stillschweigend ein gefülltes bzw.
unverjüngtes Prisma zu erzeugen. Die bewusste Bedeutung „symmetrischer Abstand je Seite“ der Geometriefunktion
bleibt bestehen; die vorhandene Kommandoebene berücksichtigt weiterhin ihre Gesamtabstand-Option.

Die bereits im Upload enthaltenen Rundungs-/Mesherwerte in `PCKShape.mm` wurden nicht erneut verändert.
Ihre Objective-C++-Übersetzung mit den vorhandenen OCCT-Headern wurde geprüft, nicht ihre Darstellung auf dem iPad.

## 4. STL, 3MF und ZIP

Der Datei-Leser wurde von der Kernel-Umwandlung in `MeshFileReader.swift` getrennt.
Er weist nichtendliche Koordinaten, unvollständige ASCII-Flächen/Eckpunkte, abgeschnittene binäre STL-Dateien,
defektes 3MF-XML und ungültige Transformationen zurück. Fehlende Komponenten und fehlerhafte
Dreiecksindizes führen zu einem Fehler statt zu einem unvollständigen importierten Modell.

ZIP-Auszüge prüfen Grenzen vor Additionen, die sonst bei sehr großen ZIP64-Werten überlaufen konnten.
Zusatzfelder werden auf ihre tatsächliche Länge geprüft. Die deklarierte entpackte Größe muss zum Ergebnis
passen; CRC32 wird überprüft. Ein einzelner Eintrag darf höchstens 256 MiB entpackt groß sein.
Diese Grenze ist eine bewusste Ressourcengrenze und kann auch sehr große gültige 3MF-Dateien zurückweisen.
Eine beschädigte Datei kann jetzt strenger abgewiesen werden als zuvor.

Die Änderungen ersetzen keine vollständige ZIP-/3MF-Spezifikationsprüfung und keinen ressourcenbegrenzten
Streaming-Importer. Getestet wurden sowohl gespeicherte als auch mit Python/ZIP-Deflate erzeugte Modellarchive.

## 5. Testbarkeit und Projektpflege

- Geometrie und Texttransformation wurden von UI-/Kernel-Zugriffen getrennt, damit dieselben Produktionsdateien
  in einem kleinen nativen Testprogramm laufen. Es werden keine Löser- oder Geometrie-Nachbildungen getestet.
- `Tests/CoreTests.swift`, die Deflate-Datei unter `Tests/Fixtures/` und `scripts/test-core.sh` bilden 84 Tests.
- `Tests/App/SketchDimensionTests.swift` und das Xcode-Testziel enthalten sechs bestandene iOS-Integrationstests.
- Die Startseiten-Kopfzeile wurde nach einem Simulator-Sichttest neu angeordnet, damit App-Titel,
  Versionszeile und Schaltflächen nicht mehr mitten im Wort umbrechen. Das korrigierte Layout wurde erneut betrachtet.
- `scripts/check-source.sh` funktioniert mit dem macOS-System-Bash ohne `mapfile` oder `sort -z`.
- `scripts/typecheck-ios.sh` ermöglicht eine separate vollständige Swift-Typprüfung. Ein früher
  Aufruf scheiterte an gesperrten Xcode-Makroprozessen; der anschließende vollständige Xcode-Build
  und die Simulator-Tests haben die App einschließlich dieser Stellen erfolgreich übersetzt.
- Der Projektgenerator prüft XcodeGen vorab, beendet Xcode nicht, löscht das Projekt nicht vor dem Erzeugen
  und öffnet es nur mit `--open`. Er übernimmt eine vorhandene Team-ID und greift im ZIP-Projekt nicht auf
  einen zufälligen übergeordneten Git-Verlauf zu.
- Das Xcode-Projekt enthält alle neuen Produktionsdateien und das gemeinsame Testschema.
  Simulator-Builds sind auf arm64 festgelegt, passend zu den mitgelieferten OCCT-Bibliotheken.
  Sicherungskopien werden nicht als App-Ressourcen eingebunden.

## Unverändert/offen

Kein neuer CAD-Kernel, kein vollständiger Constraint-Solver-Umbau, keine vollständige Neuimplementierung
von Historie/Baugruppen/Blech und keine behauptete App-Store- oder Hardware-iPad-Abnahme. Die vollständigen
Quellen und vorhandenen Ressourcen bleiben im Paket; konkrete Folgeprioritäten stehen im Analysebericht.
