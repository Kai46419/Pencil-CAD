# PencilCAD – integrierte Arbeitskopie

## Sammelupdate 30.10.2026: ausführbare Regressionstests und gebündelte Korrekturen

84 Kerntests auf dem Mac bestanden. Lokaler Löser, Maßrücknahme, Formeln, Extrusionsgrenzen,
Netzimport und Build-Hilfen überarbeitet. Das vollständige Xcode-Projekt wurde neu erzeugt.
Die vorherigen Einträge bleiben als Historie erhalten; die maßgeblichen aktuellen Nachweise stehen
in `PRUEFBERICHT_2026-10-30.md`, die Änderungen in `AENDERUNGEN_2026-10-30.md`.
Nach Installation der Metal-Toolchain: vollständiger iOS-Simulator-Build erfolgreich,
sechs App-Tests auf dem iPad-Pro-Simulator bestanden. Startseite im Simulator gestartet und
sichtgeprüft; ein dabei gefundener Umbruchfehler in der Kopfzeile wurde behoben und erneut geprüft.
Die Abnahme auf einem echten iPad bleibt offen.

## 2026-10-30: Geschlossene Konturen

Datei: `App/Model/SketchGeometry.swift`, `findRegions(in:)`.

**Befund:** Die Bedingung `if samePoint(...), chain.count >= 2 || !startsWithLine` ließ durch die Operatorgruppierung ein einzelnes offenes Nicht-Liniensegment als geschlossene Kontur durch. Bei einem einzelnen offenen Bogen war `!startsWithLine` wahr, auch wenn Anfang und Ende nicht übereinstimmten.

**Änderung:** `if samePoint(...) && (chain.count >= 2 || !startsWithLine)`.

**Regressionstests für iPad/Xcode:**
- Einzelner offener Bogen: keine geschlossene Kontur und keine extrudierbare Fläche.
- Einzelne offene Spline: keine geschlossene Kontur.
- Einzelne geschlossene Spline: Kontur bleibt gültig.
- Zwei verbundene Segmente, deren Endpunkte nicht zurück zum Anfang führen: keine Kontur.
- Geschlossenes Rechteck: Fläche weiterhin erkannt.
- Geschlossener Linien-/Bogen-Mix: Fläche erkannt.

**Teststatus:** Quelltextänderung geprüft; kein Xcode-Build in dieser Umgebung durchgeführt.

## 2026-10-30: Degenerierte Kurven beim Skizzenversatz

Datei: `App/Model/SketchGeometry.swift`, `SketchOffset.segment`.

**Befund:** Im Bogen-Versatz wurde `samples[1]` ohne Längenprüfung verwendet. Beim Versatz von Bézier-/B-Spline-Kurven wurde `fit[fit.count - 1]` ohne Absicherung einer nichtleeren Punktliste ausgewertet. Bei degenerierten oder leeren Kurvensamples drohten Indexfehler.

**Änderung:** Vor Berechnung der Bogennormalen wird auf mindestens zwei unterschiedliche Samples geprüft; beim Spline-Versatz auf mindestens zwei Ausgabepunkte. Nicht versetzbare Segmente liefern `nil`, wie es die bestehende optionale API vorsieht.

**Testfälle für Xcode/iPad:** Bogen mit gültiger Krümmung; degenerierter Bogen; Spline mit leerer/Ein-Punkt-Sampleliste; normaler offener Spline-Versatz. Kein Xcode-Build in dieser Umgebung.

## 2026-10-30: Constraint-Solver – ungültige numerische Zustände

Datei: `App/Model/SketchConstraints.swift`, `ConstraintSolver.solve`.

**Befund:** Der iterative Solver nahm an, dass die aus Skizzenelementen erzeugten Parameter und Residuen endlich sind und die Anzahl der Residuen während der numerischen Jacobi-Ableitung konstant bleibt. Bei degenerierten Kurven, ungültigen Maßwerten oder inkonsistenten Constraint-Zuständen können `NaN`/`Infinity` oder abweichende Residuenlängen entstehen. Dies kann die numerische Lösung destabilisieren oder bei einem Array-Zugriff zu einem Laufzeitfehler führen.

**Änderung:** Vor dem Solve werden Parameter, Gewichtungen und Anfangsresiduen geprüft; bei jeder Jacobi-Ableitung wird die Residuenlänge und Endlichkeit geprüft; ungültige Backtracking-Kandidaten werden verworfen. In solchen Fällen liefert die bestehende optionale API kontrolliert `nil`, statt ungültige Geometrie zu übernehmen.

**Offen:** Überbestimmte Constraints und die Erhaltung geschlossener Profile bei Maßänderungen benötigen eigene reproduzierbare Testfälle. Diese Änderung garantiert keine erfolgreiche Konvergenz und ist kein vollständiger Solver-Umbau.

**Teststatus:** Statische Prüfung der Änderungen durchgeführt. Kein vollständiger iOS-/OCCT-Build und keine Laufzeittests in Xcode.

## Prüfung: Verbundene Skizzenelemente bei Maßänderungen (30.10.2026)
- `App/Model/Sketch.swift`, `addCommitConstraint`: Ein leerer Residuenvektor wurde bislang mit `reduce(0, ...)` als Residuum 0 interpretiert. Ungültige Punktreferenzen konnten damit als erfolgreich übernommene geometrische Bedingung gelten, obwohl der Solver nichts binden konnte.
- Korrigiert: Leere oder nicht-endliche Residuen führen jetzt zur Rücknahme der gerade hinzugefügten Bedingung und zu `false`. Bestehende gültige Bedingungen bleiben unverändert.
- Statische Kontrolle durchgeführt; kein iPad-/Xcode-Build. Offene Arbeit: Solver-weite Validierung aller Referenzen und Regressionstests für Maßänderungen und verbundene Linien/Bögen.

## Prüfung: Solver-weite Referenzabsicherung (30.10.2026)
- `App/Model/SketchConstraints.swift`: `ConstraintSolver.solve`, `determined` und `constraintRank` prüfen jetzt vor der numerischen Auswertung, ob **jede aktive** Einschränkung einen nichtleeren, endlichen Residuenvektor liefert.
- Hintergrund: `residual()` gibt für ungültige Punkt-/Kurvenreferenzen oder inkompatible Kurventypen `[]` zurück. Ohne Vorprüfung können diese Constraints aus dem Gleichungssystem verschwinden und dadurch fälschlich als erfüllt erscheinen.
- Fehlerverhalten: `solve` und `constraintRank` geben `nil`, `determined` gibt eine leere Menge zurück; ungültige Geometrie wird nicht als Lösung bestätigt.
- Teststatus: Statische Quelltextprüfung; kein Xcode-/iPad-Build. Offene Regressionstests: ungültiger Punktindex, gelöschte Kurve, gemischte gültige/ungültige Constraints, gültiger Linien-Bogen-Anschluss mit nachträglicher Bemaßung.


## Sammelblock: fünf zusammenhängende Absicherungen (30.10.2026)
1. `SketchConstraints.swift` – `determined()`: Nicht-endliche Parameter/Residuen werden vor der Jacobi-Berechnung verworfen.
2. `SketchConstraints.swift` – `determined()`: Nicht-endliche Ableitungen und Normen werden nicht als feste Freiheitsgrade klassifiziert.
3. `SketchConstraints.swift` – `constraintRank()`: Nicht-endliche Parameter und Basis-Residuen liefern einen nicht bestimmbaren Rang statt irreführender Ergebnisse.
4. `SketchConstraints.swift` – `constraintRank()`: Nicht-endliche numerische Ableitungen werden abgefangen.
5. `SketchClickTool.swift` – Doppeltipp-Zeitfenster ist explizit nicht-negativ; `FeatureHistory.swift` – bereits als fehlgeschlagen markierte Feature-Zustände werden nicht als Cache-Anker verwendet.

Statische Quelltextänderungen, **kein** iOS-Build oder Laufzeittest. Kein vollständiger Abschluss der fünf großen Entwicklungsbereiche; dafür sind weitere Implementierung und Tests nötig.

## Sammelblock: 10 numerische Schutzmaßnahmen (30.10.2026)

Datei: `App/Model/SketchConstraints.swift`.

1. `hasValidEquations`: Alle in Constraints angegebenen Elementindizes müssen existieren.
2. `solve`: Numerische Störwerte und Differenzenschrittweite werden auf Endlichkeit geprüft.
3. `solve`: Die numerische Jacobi-Matrix wird vor dem Normalgleichungssystem validiert.
4. `solve`: Die Normalmatrix wird vor der linearen Lösung auf endliche Werte geprüft.
5. `solve`: Der errechnete Update-Schritt muss endlich sein.
6. `solve`: Backtracking überspringt Kandidaten mit ungültigen Parametern.
7. `determined`: Numerische Störwerte und Schrittweite werden validiert.
8. `determined`: Die Jacobi-Matrix wird vor der Rangbestimmung validiert.
9. `constraintRank`: Numerische Störwerte und Schrittweite werden validiert.
10. `constraintRank`: Constraint- und Gauge-Jacobi-Matrizen werden validiert.

**Validierung:** `swiftc -frontend -parse` auf der geänderten Swift-Datei erfolgreich. Kein iOS-Build, keine OCCT-Integrationstests und keine Laufzeittests. Diese Maßnahmen sind defensives Hardening des Solvers; die 10 übergeordneten CAD-Funktionsbereiche sind damit nicht abgeschlossen.

## Aktive Prüfung: Solver-Rangnorm (30.10.2026)
- `constraintRank()` weist jetzt nicht-endliche Zeilennormen und normierte Basisvektoren zurück. Zuvor konnte eine Überlaufnorm in der Gram-Schmidt-Orthogonalisierung als gültige Basis aufgenommen werden.
- `swiftc -frontend -parse App/Model/SketchConstraints.swift` erfolgreich (Syntaxprüfung, kein Typcheck oder iOS-Build).
- **Nicht abgeschlossen:** Gesamtprojekt-Build, UI-Tests, parametrische Rebuild-Tests, iPad-Hardwaretests. Kein 100-%-Status.

## Build-Vorbereitung: gesamter Swift-Quellbestand (30.10.2026)
- `scripts/check-source.sh` ergänzt: reproduzierbarer Syntax-Preflight aller Swift-Dateien unter `App/`, mit Hinweisen auf fehlende lokale OCCT-Bibliothek und Signing-Konfiguration.
- Gesamten Swift-Quellbestand gemeinsam mit `swiftc -frontend -parse` geprüft: **160 Swift-Dateien, Syntaxprüfung bestanden**.
- Einschränkung: Keine iOS-SDK-Typprüfung, kein XcodeGen-Lauf, kein OCCT-Linking, keine iPad-Laufzeittests. Ein erfolgreicher Xcode-Build ist damit ausdrücklich nicht bestätigt.
