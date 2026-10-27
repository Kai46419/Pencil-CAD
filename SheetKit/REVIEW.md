# Review Blechmodul (Prüf-Agent)

Referenz: `SheetKit/API.md`, `SheetKit/COMMANDS.md`, SolidCraft @ 98b57a3 (`/tmp/claude-0/sc/solidcraft`).
Schwere: **KRITISCH** (bricht Build/Funktion), **HOCH** (falsches Verhalten/Abweichung von SolidCraft),
**MITTEL**, **NIEDRIG** (Kosmetik/Hinweis). Status: offen / erledigt (mit Uhrzeit der Prüfung).

---

## Runde 1 – 17:25 UTC (SheetKit/src, include, tests; App/Sheet/SheetKernel.swift)

Geprüft und **in Ordnung** (gegen SolidCraft-Quelltext verifiziert):
- `Session::checkpoint()` / `restore_checkpoint(id)` existieren mit dieser Signatur (engine/src/lib.rs:1264/1284);
  „Checkpoint und alle späteren verbraucht“ im Header stimmt (`drain(i..)`). `MAX_CHECKPOINTS` begrenzt die Anzahl
  (älteste fallen weg) – nur bei sehr vielen offenen Vorschauen relevant.
- `file.export` liefert `{"path","bytes","format"}` → `psk.export_step` liest `out["bytes"]` korrekt.
- `file.insert_step` liefert `bodies`, `feature`, `warnings` (+ Komponentenfelder über `placed.report`) → `psk.import_step` ok.
  SolidCraft testet `file.insert_step` + `sheet.convert` selbst (sheet_convert_tests.rs:884) – der Weg ist gedeckt.
- `psk.edges` benutzt dieselbe Tessellier-Toleranz wie `model.edges` (`(size*2e-3).max(1e-3)`) und `body.tessellate`
  (dieselbe Quelle wie `Body::edges`) → Kantenindizes stimmen mit `model.edges` überein.
- Swift: `PCKShape.stepAvailable`, `readSTEP(path:)`, `writeSTEP(_:path:)`, `compound(_:)` existieren in
  App/Kernel/PCKShape.h (Z. 28/157/343/345). `URL.path(percentEncoded:)`/`appending(path:)` brauchen iOS 16 – Ziel ist
  iOS 17 → ok. `psk_session_new()` (unvollständiger Struct) wird in Swift `OpaquePointer?` → passt.
- Fehlschlagende Befehle rollen in SolidCraft selbst zurück (`Session::execute`, lib.rs ~1230) – kein Zusatz nötig.

Befunde:

1. **SheetKit/src/lib.rs:56** (`run_script_json`) – Fehlertext wird zu `"<id>: invalid parameters for `<id>`: …"`
   (SolidCraft-Fehler enthalten den Befehl schon). Vorschlag: nur `e` weitergeben; der Index steht in `index`.
   Schwere: NIEDRIG. Status: erledigt (Rust-Agent, ~18:05): `run_script_json` gibt den SolidCraft-Text unverändert weiter.
2. **SheetKit/include/pencil_sheet.h** – keine Nullability-Angaben (`_Nullable`/`_Nonnull`). In Swift werden alle
   Zeiger implizit entpackte Optionals; SheetKernel.swift fängt das bereits sauber ab (`let raw: …? =`). Kein Fehler,
   nur Hinweis. Schwere: NIEDRIG.
3. **App/Sheet/SheetKernel.swift:~314** (`importBody`) – `name` geht an `file.insert_step` als **Feature-/Komponentenname**;
   die Körpernamen kommen aus dem STEP (`names: auto`). Die Funktion gibt korrekt `result["bodies"]` zurück – Aufrufer
   (Modell) müssen **diese** Namen für `sheet.convert.body` verwenden, nicht `name`. Beim Modell-Code prüfen.
   Schwere: HOCH (falls Modell `name` benutzt). Status: erledigt (17:51, Modell): Aliasse – Name aus `bodies`/`changed_bodies` der Antwort, nie `name`.
4. **App/Sheet/SheetKernel.swift** `SheetJSON.init(from:)` – Reihenfolge Bool vor Double ist richtig (JSONDecoder
   liest Zahlen nicht als Bool). In Ordnung.

## Runde 2 – 17:30 UTC (App/Sheet/SheetModel.swift, SheetModelReplay.swift, SheetModelSketch.swift)

Geprüft und in Ordnung: alle verwendeten SolidCraft-Befehle/Parameter existieren (`sketch.create plane{origin,x_dir,y_dir}`,
`sketch.line {points,closed,ids}`, `sketch.arc.three_point {start,through,end}`, `sketch.circle.center`,
`sketch.ellipse {center,major,minor_radius}`, `sketch.spline.control_point` (kubisch), `sketch.spline.fit_point {points,periodic}`,
`sketch.finish`, `solid.move {bodies,translate,copy}`, `solid.mirror {bodies,plane:{origin,normal}}`, `sheet.flange`
base/contour/edge-Parameter, `sheet.path_flange`, `sheet.export_dxf`, `sheet.export_bend_table`). Flachmuster-Felder in
`FlatPattern.init(json:)` stimmen wörtlich (`flat_size_mm`, `outline`, `cutouts`, `bends[].bend/angle_deg/included_angle_deg/
radius/direction/allowance/length/start/end`, `pockets[].outline/cutouts/side/depth_mm`, `bend_zones`, `perforations[].count`).
Repo-APIs vorhanden: `showPreview/dropPreview/commitPreview/hasPreview/commit(_:name:)`, `featureRecorder.preview/pending`,
`PendingFeature(feature:)`, `FeatureParameter.length/.angle/.formula/.unit`, `FeatureError(_:)`, `replayFeatures(from:features:sketches:name:)`,
`SceneBody.with(_:)`, `newBody(_:name:)`, `SketchPlane.local(_:)`, `SketchLoop`/`SketchSegment`-Fälle, `polygonContains`,
`PCKShape.boundingBox`/`volume`.

5. **App/Sheet/SheetModel.swift:130-143** – `FlatBend.id = index`. SolidCraft liefert für eine durch Ausschnitte geteilte
   Biegung **mehrere Zeilen mit derselben Nummer** (`bends()` → `index: i + 1` je Stück, doc/sheet.rs:2101). In SwiftUI
   `ForEach(pattern.bends)` gibt das doppelte IDs (Warnung, falsche/fehlende Zeilen). Vorschlag: `id` = laufende Position
   (z. B. `var id: Int` beim Einlesen aus `enumerated()` setzen) und `index` nur anzeigen. Schwere: MITTEL. Status: offen.
6. **App/Sheet/SheetModel.swift:76-81, 438-461** – Anzeigenamen weichen von SolidCraft-de ab (Auftrag „1:1“):
   `Umschlag` → SolidCraft **Umkantung**; `Abkanten` → **Falten**; `Zurückfalten` → **Wieder falten**; `Lochung` →
   **Perforieren**; Eckform `Kerbe`/`Riss` → **Ausklinkung**/**Reißen**. Vorschlag: Texte aus COMMANDS.md §15/§1d übernehmen.
   Schwere: MITTEL. Status: offen.
7. **App/Sheet/SheetModel.swift:81, 58-60** – Standardregel `"Stahl 2 mm"` (2 mm, K 0.44, Radius 2) ≠ SolidCraft-Standard
   `"Steel (mm)"` (2.5 mm, K 0.44, `bend_radius: "Thickness"`). Außerdem kann `SheetRule` nur Zahlen, SolidCraft-Regeln sind
   Ausdrücke (`Thickness * 0.5` usw.); da die optionalen Felder nil → Engine-Vorgabe bleiben, ist das funktional ok.
   Vorschlag: Standard wie SolidCraft (Name darf deutsch sein, Werte 2.5 / 0.44 / = Dicke). Schwere: NIEDRIG–MITTEL.
8. **App/Sheet/SheetModelSketch.swift:126-152** (Grundflansch, mehrere Bereiche) – mehrere getrennte Bereiche ergeben in
   SolidCraft **mehrere Körper** (`body_name` „Blech“, „Blech (2)“ …, features.rs add_feature), übernommen wird aber nur
   `kernelBody = "Blech"` → weitere Bereiche gehen still verloren. Außerdem: zwei **angrenzende** gewählte Bereiche schreiben
   ihre gemeinsame Kante doppelt in die Skizze (je Bereich `outer`+`holes`) → überlappende Kurven. Vorschlag: nur einen
   Bereich zulassen bzw. je Bereich einen eigenen Blechkörper; oder Bereiche vorher vereinigen. Schwere: MITTEL.
    Status: erledigt (17:51, Modell): Grundflansch nur mit genau einem Bereich (Fehlermeldung sonst).
9. **App/Sheet/SheetModelSketch.swift:35-42** – geschlossener periodischer Spline wird als Fit-Spline durch ≤480
   **Abtastpunkte** übertragen (nicht exakt; Flachmuster/DXF weichen minimal von der PencilCAD-Kontur ab). Hinweis,
   akzeptabel. Schwere: NIEDRIG.
10. **App/Sheet/SheetModelReplay.swift:129-136** (`sheetRun`) – ist keine Blech-Vorschau aktiv, wird **jede** fremde offene
    Vorschau (z. B. Extrudieren) mit `commitPreview()` übernommen, bevor der Blechbefehl rechnet. Gewollt? Sonst
    `cancelPreview()`/nur eigene Vorschau verwerfen. Schwere: NIEDRIG.
    Status: bewusst so (17:51, Modell): wie alle PencilCAD-Werkzeuge wird eine fremde Vorschau übernommen; eigene Blech-Vorschau wird verworfen.
11. **App/Sheet/SheetModelReplay.swift:60-85** – jede Vorschau spielt das **ganze Rezept** in einer neuen Sitzung ab
    (+ STEP-Export + OCCT-Import) synchron auf dem Main Actor; `sheetBuild` verwirft danach `sessionCache` statt die gerade
    erzeugte Sitzung zu behalten → `flatPattern(of:)` direkt danach spielt erneut ab. Vorschlag: `sessionCache` in
    `sheetBuild` mit `result.kernel` füllen (Schlüssel wie in `sheetSession`). Performance, Schwere: MITTEL.
    Status: erledigt (17:51, Modell): `sheetBuild` füllt `sessionCache`; Wiedergabe läuft jetzt im Hintergrund mit Zeitlimit (SheetWorker.swift).
12. **Offen/zu prüfen in der nächsten Runde:** `SheetModel.swift` verweist auf `SheetModelConvert.swift`
    (`sheetConvertPlan`, `sheetSuggestConversion`, `sheetCheckConversion`, `sheetTopology`, `sheetBendEdges`) – Datei fehlt noch
    → sonst **Compile-Fehler**. Ebenso fehlen noch die Einhängepunkte `SceneBody.sheetMetal`, `FeatureKind.sheetMetal`
    (+ `systemImage`-Fall, die `switch`es sind erschöpfend), `FeatureData.sheet`, `ModelStore.sheetDocument`, `applyFeature`-Fall.
    Schwere: KRITISCH, falls am Ende nicht vorhanden. Status: beobachten.

## Runde 3 – 17:40 UTC (SheetKit/examples, App/Sheet/SheetModelConvert.swift, SheetUI.swift, Einhängepunkte)

Geprüft und in Ordnung: Einhängepunkte aus Befund 12 sind jetzt da (`FeatureKind.sheetMetal` + `systemImage "sc.flange"`,
`FeatureData.sheet`, `SnapshotBodyMeta`/`BodyMeta.sheetMetal`, `SceneBody.sheetMetal`, `ModelStore.sheetDocument`,
`applyFeature` → `replaySheetMetal`), `SheetModelConvert.swift` existiert → **Befund 12 erledigt (17:40)**, außer den
Befehls-IDs (s. u. 18). Repo-Symbole aus SheetUI.swift existieren (`ws.startCommand`, `CommandPicks.setItems`, `Pick.edge`,
`EdgeRef(body:edge:)`, `handle(ofEdge:)`, `PanelMenuRow`, `PrimaryWideButton(...)`, `PaletteFieldBox(isLocked:hasError:)`,
`PaletteExpression`, `cmd.putNumber` / `cmd.option(_:default:)` in CommandSupport.swift:427/435).
Konvertieren-Schritte stimmen mit SolidCraft überein (`sheet.convert {body, face, bends, rule}`; offene Kanten = alle
Kandidatenkanten, die nicht in `bends` stehen; Spalt = `gap` der Regel).

13. **SheetKit/examples/commands.rs:2** – Kopfzeile sagt `cargo run --example commands > COMMANDS.md`. Genau das hat um
    ~17:33 die kuratierte Referenz überschrieben (wiederhergestellt; Rohliste steht jetzt als Anhang A). Vorschlag: Ausgabe
    nach `SheetKit/COMMANDS-RAW.md` und Kommentar ändern. Schwere: **KRITISCH (Prozess)** – erneutes Ausführen zerstört
    COMMANDS.md wieder. Status: erledigt (Rust-Agent, ~18:05): Beispiel und Kopfzeile schreiben nach `COMMANDS-RAW.md`, Warnung im Kommentar; API.md entsprechend.
14. **App/Sheet/SheetModelConvert.swift:15-96** (`sheetTopology`/`sheetSpanningTree`) – der Spannbaum läuft über **alle**
    ebenen Flächen des Körpers. Bei einem echten Blechteil (oder einem schalenförmigen Körper) gehören dazu auch die
    **Innenhaut** und die **schmalen Stirnflächen** (Dicke breit). Diese werden zu „Blechflächen“, die Kanten Außenhaut–Stirn
    werden Biege-/Offen-Kandidaten → Vorschlag ist falsch bzw. `sheet.convert` schlägt fehl. SolidCraft erwartet in
    `bends` nur Kanten **einer** Haut (die der gewählten Grundfläche). Vorschlag: Stirnflächen ausschließen (Fläche, deren
    kleinste Ausdehnung ≈ Dicke und die an zwei parallele Flächen im Abstand Dicke grenzt) und nur die Haut der Grundfläche
    (gleiche Seite) in den Graph nehmen. Schwere: HOCH. Status: erledigt (17:51, Modell): dünne Körper erkannt (Gegenfläche der größten Fläche im Abstand ≤ 0,1·√Fläche, s. 40), Stirnflächen (an zwei Gegenflächen im Abstand der Dicke) aus dem Graph → Baum bleibt auf einer Haut.
15. **App/Sheet/SheetModelConvert.swift:174-215** (`sheetSuggestConversion`/`sheetPlanFor`) – ruft immer
    `sheetConvertSteps(..., plateOnly: false)` auf; bei einer **ebenen Platte** sind Ober-/Stirnkanten (90°) Kandidaten und
    landen in `bends` → Fehler oder Unsinn. Vorschlag: Platte erkennen (alle Kandidaten an Stirnflächen ≈ Dicke / nur zwei
    parallele Großflächen) und `plateOnly: true` vorschlagen. Schwere: HOCH. Status: erledigt (17:51, Modell): Platte = keine Kandidatenkante → `SheetConversionPlan.plateOnly`, Probe/Vorschlag mit plateOnly.
16. **App/Sheet/SheetModelConvert.swift:15-60** – nur **ebene** Flächen/gerade Kanten. Importierte Blechteile mit
    **Biegeradius** (Zylinderflächen) – SolidCraft nimmt dafür einen Punkt auf der Zylinderfläche in `bends`
    (COMMANDS.md §7) – lassen sich so nicht umwandeln, der Graph zerfällt an jeder runden Biegung. Vorschlag: Zylinderflächen
    als Biegeknoten aufnehmen (Punkt = Flächenpunkt auf dem Zylinder), Ebenen über sie verbinden. Schwere: HOCH (betrifft die
    meisten realen STEP-Blechteile). Status: erledigt (17:51, Modell): Zylinder zwischen zwei tangentialen Wänden = Biegeknoten; vertreten durch ihre längste Kante zur ersten Wand (`bendFace`, `bendPoint` auf dem Zylinder in `bends`).
17. **App/Sheet/SheetModelConvert.swift:~30-45** – Grundflächenpunkt = Mittel der Umrissabtastung, dann `surfacePoint(near:)`.
    Bei L-/U-förmigen Flächen oder Flächen mit Loch in der Mitte liegt der Mittelpunkt außerhalb; `surfacePoint` projiziert auf
    die **unbegrenzte** Ebene (zu prüfen) → SolidCraft findet keine/eine andere Fläche. Vorschlag: Punkt sicher im Inneren
    (z. B. Mittelpunkt eines Tessellations-Dreiecks der Fläche) verwenden. Schwere: MITTEL. Status: erledigt (17:51, Modell): Punkt = Schwerpunkt des größten Netzdreiecks der Fläche (gewölbt: auf die Fläche gezogen).
18. **App/Sheet/SheetUI.swift** – benutzt `ModelCommandID.sheetFlange` usw. und Typen `SheetConvertDriver`, `SheetUIFlat`,
    `SheetUIRules`, `SheetUIOverlay`, `FlatPatternView`; die `ModelCommandID`-Fälle und `registerSheet()` in `registerAll()`
    fehlen noch (17:40) → Compile-Fehler, falls nicht nachgezogen. Schwere: KRITISCH (wenn offen bleibt). Status: beobachten.
19. **App/Sheet/SheetUI.swift** (`SheetEdgePicks`) – Kantenpunkte werden aus der angezeigten Form (`shownBodies`, ggf.
    Vorschau) bestimmt. Für Körper in einer Komponenteninstanz (`componentID` ≠ nil) liegt die Form lokal, SolidCraft erwartet
    Weltkoordinaten des Blechkörpers im Rezept. Prüfen, ob Instanz-Transformationen angewendet werden. Schwere: MITTEL.

## Runde 4 – 17:41 UTC (App/Sheet/SheetUIFlange.swift, SheetUIConvert.swift; Abgleich SolidCraft sheet_convert.rs)

Geprüft und in Ordnung: alle in SheetUIFlange/SheetUIConvert verwendeten Repo-Symbole existieren mit passender Signatur
(`MainCommandDriver` + Standardimplementierungen, `PickInput`-Memberwise-Init, `PickKinds`, `ModelCommand(id, inputs:)`,
`CommandTap.edge/face/region/point`, `CommandValueRow`, `CommandNumberRow(adjust:)`, `CommandOptionRow`, `CommandSegmentRow`,
`CommandSection(_:command:section:expanded:)`, `PaletteSection(_:detail:expanded:)`, `PaletteNumberRow`, `CommandFlagRow`,
`CommandPreviewRow`, `DragHandle`, `Workspace.handleBlue`, `LengthUnit.current.number/symbol`, `CommandFormat.plain`,
`SheetEdgePicks.toggle` ist `@discardableResult`). Gesendete Parameter stimmen mit COMMANDS.md §1c/§1d/§2/§3/§4/§5:
Kantenflansch `edges` (Punkt bzw. `{point, angle?, height?}`), `height`, `angle` als `"… deg"`, `position`,
`height_from` nur ≠ outer, `corner_relief_shape` (leer = Regel), `corner_relief`, `then[{angle,height,flip?}]` mit
„Entgegengesetzte Richtung“ → `flip = !flip` (wie SolidCraft), max. 16; Umkantung `edges/length/gap?/flip`; Falten
`points/angle/radius?/position/fixed?/flip`; Perforieren `diameter/pitch/margin?/pattern`; Pfadflansch `edge/sketch/curves/radius?`.
Standardwerte wie SolidCraft (Höhe 10, Abstand 20, Weitere Biegung 45°/20 mm, Umkantung 5 mm, Perforieren 3/6 mm).
Deutsche Beschriftungen stimmen mit COMMANDS.md (Profil / Kanten, Biegeposition, Höhe ab, Weitere Biegungen, Biegung
hinzufügen, Form der Eckenentlastung, Pro Kante, Umkehren, Andere Seite, Feste Fläche, Biegekanten, Position der
Biegelinie, Mittellinie, Durchmesser, Rand, Muster …). Kais Wunsch „welche Kante offen bleibt“ ist umgesetzt
(SheetUIConvert: Modus „Offene Kanten wählen“/„Biegekanten wählen“, Antippen schaltet um) – deckt sich mit der SolidCraft-
Semantik (offen = Kante zwischen zwei Blechflächen, die nicht in `bends` steht).

20. **Präzisierung zu 14** – SolidCraft (crates/doc/src/sheet_convert.rs:1-12): bei einem **Volumenkörper** werden *alle*
    Flächen zur Außenhaut des Blechs → Spannbaum über alle ebenen Flächen ist dort **richtig**. Bei einem **Schalenkörper**
    (parallele Gegenfläche im Abstand Dicke) sind Blechflächen nur die über `bends` erreichbaren Flächen **derselben Haut** wie
    die feste Fläche. PencilCADs Spannbaum läuft dort über die Stirnstreifen auf die Innenhaut → falsche `bends`.
    Befund 14 gilt also für Schalenkörper/importierte Blechteile. Schwere: HOCH. Status: erledigt (17:51, Modell): siehe 14 – Vollkörper: alle Flächen; Schale: eine Haut.
21. **App/Sheet/SheetUIConvert.swift:227-231** (`isPlate`) – „Platte = keine Kandidatenkante“. Bei einer echten Platte
    (Quader 100×60×2) sind die Kanten Deckfläche–Stirnfläche 90°-Kandidaten → `isPlate` ist **nie** wahr, der Vorschlag macht
    aus der Platte eine geschlossene Blechkiste mit 2-mm-Wänden (Probe scheitert/Überlappung). Bestätigt Befund 15.
    Umgehung für den Benutzer: alle Kanten offen schalten → keine `bends` → SolidCraft nimmt Platte. Vorschlag: Platte
    erkennen (zwei größte Flächen parallel, Abstand ≪ Ausdehnung, alle übrigen Flächen schmal und senkrecht) und dann
    `plateOnly`/alle offen vorschlagen. Schwere: HOCH. Status: erledigt (17:51, Modell): Stirnflächen sind keine Kandidaten mehr → `detectsPlate`/`isPlate` greift; Modell meldet `plateOnly`.
22. **Ergänzung zu 16** – SolidCraft nimmt außer Zylinder-Biegungen auch **Fasen-Streifen** als Biegung (Punkt in der Mitte
    des Streifens, sheet_convert.rs:22-25). Auch das kann die Kantenwahl nicht ausdrücken (nur gerade Kanten zwischen zwei
    ebenen Flächen). Vorschlag wie 16: schmale ebene Streifen/Zylinder als „Biegeflächen“ antippbar machen und als Punkt
    auf der Fläche in `bends` senden. Schwere: HOCH (zusammen mit 16). Status: erledigt (17:51, Modell): schmale Fasenstreifen (an den zwei längsten Kanten zwei Wände, Breite < ¼·√kleinere Wand, Normale zwischen beiden) = Biegeknoten wie 16.
23. **App/Sheet/SheetUIConvert.swift:182-198** (`gapRule`) – eigener Spalt legt bei **jeder Vorschau** mit neuem Wert eine
    dauerhafte Regel „<Regel> · Spalt x mm“ im Dokument an (`setSheetRule`, wird gespeichert), auch wenn der Befehl
    abgebrochen wird → Regelliste läuft voll. In SolidCraft gibt es keinen Spalt-Parameter (Regel bestimmt `gap`, mit `bends`
    werden Regelwerte abgelehnt) – die Notlösung ist also nötig, aber: Regel erst bei **OK** anlegen (Vorschau mit
    temporärer Regel nur in der Probe-Sitzung) bzw. beim Abbrechen wieder entfernen. Schwere: MITTEL. Status: offen.
24. **App/Sheet/SheetUIFlange.swift:806-809** (Falten) – sendet `points` statt SolidCraft-Dialog `sketch`+`curve`
    (beides erlaubt). Folge: das Rezept folgt späteren **Änderungen der Skizzenlinie nicht** (SolidCraft schon). Hinweis.
    Außerdem `fixed`-Fallback `mesh.centroid(of:)` (Z. 765) liegt bei L-/U-Flächen außerhalb → SolidCraft-Fehler „must lie
    on the sheet“. Vorschlag: nur `tap.point` verwenden. Schwere: NIEDRIG. Status: offen.
25. **App/Sheet/SheetUIFlange.swift, SheetUIConvert.swift, SheetUIFlat.swift** – kein Treiber setzt `featureKinds`
    (`[.sheetMetal]`) oder `load(_:into:)`; `updateSheetStep`/`deleteSheetStep` (SheetModel.swift:538/544) werden von keiner
    Oberfläche aufgerufen → Blech-Features lassen sich aus der Zeitleiste **nicht bearbeiten** (SolidCraft: jeder Blechdialog
    bearbeitet sein Feature, `+ body` beim Bearbeiten). Für „1:1“: Bearbeiten nachrüsten. Schwere: HOCH. Status: offen.
26. **App/Model/ModelCommand.swift:44-55, 245-248** – (erledigt 17:42, s. Runde 5) Stand 17:41 weiterhin **keine** `ModelCommandID`-Fälle `sheetFlange`,
    `sheetPathFlange`, `sheetHem`, `sheetFold`, `sheetPerforate`, `sheetConvert`, `sheetUnfold`, `sheetRefold`, `sheetFlatPattern` …
    und `registerAll()` ruft `registerSheet()` nicht auf → **Compile-Fehler** in allen SheetUI*-Dateien (= Befund 18).
    Hinweis: `ModelCommandID` ist `CaseIterable` – prüfen, ob irgendwo über `allCases` ein erschöpfendes `switch` läuft.
    Schwere: KRITISCH. Status: offen.
27. **App/Sheet/SheetUIFlange.swift:171-176, 686-687** – Höhe/Länge ≤ 0 bzw. fehlende Höhe weiterer Biegung: Fehlertext,
    aber die **alte Vorschau bleibt stehen** (kein `dropPreview()`), OK ist nur durch `cmd.error` gesperrt. Kosmetik.
    Schwere: NIEDRIG.
28. **App/Sheet/SheetUIFlange.swift:211-221** – Grundflansch aus Bereichen **mehrerer Skizzen**: nur die erste Skizze zählt,
    die übrigen Bereiche werden still ignoriert (SolidCraft: ein `sketch`, also gleich – aber Hinweis an den Benutzer fehlt).
    Schwere: NIEDRIG.

## Runde 5 – 17:42 UTC (App/Sheet/SheetUIFlat.swift, FlatPatternView.swift; Nachprüfung früherer Befunde)

Erledigt seit Runde 2–4:
- **5 erledigt (17:42)** – `FlatBend.position` als eindeutige `id`, `index` = Biegungsnummer (SheetModel.swift:130-146).
- **6 erledigt (17:42)** – Anzeigenamen jetzt Umkantung/Falten/Wieder falten/Perforieren/Ausklinkung/Reißen.
- **7 erledigt (17:42)** – Standardregel „Stahl (mm)“ 2,5 mm / K 0,44 / R 2,5 (SolidCraft „Steel (mm)“, R = Dicke).
- **18 + 26 erledigt (17:42)** – `ModelCommandID` hat jetzt `sheetFlange … sheetRuleList` (ModelCommand.swift:55-56),
  `registerAll()` ruft `registerSheet()` (Z. 251), `ModelStartBridge` behandelt die neuen Fälle im `switch`.

Geprüft und in Ordnung: Flachmuster-Panel wie SolidCraft `Sm::FlatPattern` (Körper, Abwicklungsgröße „w × h × t“,
Biegungen-Anzahl, max. 50 Zeilen „Biegung N · Auf/Ab 90° R…“ in Biegefarbe, „DXF exportieren…“, „Biegetabelle
exportieren…“, Fehler in Fehlerfarbe); 2D-Ansicht: Umriss 1,8, Ausschnitte 1,4, Taschen 3/3 Akzentfarbe mit Tiefe,
Biegelinien 8/5 Strich 1,6, Legende, Einpassen beim Öffnen, Pan/Zoom ohne Orbit, Text „kein Blechkörper“. Entfalten/Wieder
falten: Auswahl „Körper (letzter, wenn keiner)“, Standardkörper wie SolidCraft (Entfalten: letzter gefalteter, Wieder
falten: letzter entfalteter). iOS-17-APIs (`MagnifyGesture`, `onChange(of:){_,_ in}`) passen zum Ziel.

29. **App/Sheet/FlatPatternView.swift:95-150** – **Perforationslöcher werden nicht gezeichnet.** SolidCraft zeichnet jedes
    Loch als Kreis (dialogs_sheet.rs:1071-1078, `FlatView::cache_perforations` → `sheet.perforation_holes(field)`, max. 1 Mio.).
    Die Lochmitten stehen **nicht** im `sheet.flat_pattern`-JSON (nur `count`, `diameter` …). Vorschlag: in SheetKit einen
    Zusatzbefehl `psk.perforation_holes {body}` → `[{"center":[x,y],"radius":r}]` (über `session.world_state().sheets[..]
    .perforation_holes(field)`, wie SolidCraft), in FlatPatternView als Kreise (1,4) zeichnen, nur wenn ≥ 1 px.
    Schwere: MITTEL (1:1-Abweichung). Status: offen.
30. **App/Sheet/FlatPatternView.swift:17, 129-139, 167-168** – `FlatPatternColors.bend(up:)` immer mit `dark: true`; die
    hellen Farben werden nie benutzt. SolidCraft nimmt `bend_up`/`bend_down` des aktiven Themes. Nur relevant, wenn PencilCAD
    ein helles Theme hat (`PaletteStyle.background` ist fest dunkel → aktuell ok). Schwere: NIEDRIG.
31. **App/Sheet/SheetUIFlat.swift:197-201** (`finish` von „Flachmuster erstellen“) – OK ruft `LegacyFinish.cancel` (richtig,
    kein Modellschritt). In Ordnung, nur Hinweis: `canCommit` immer true, auch ohne Blechkörper – SolidCraft schließt dann
    ebenfalls nur. In Ordnung.

## Runde 6 – 17:49 UTC (SheetUIOverlay.swift, SheetUIRules.swift, Einhängepunkte in Viewport/Ribbon/Suche/ToolRail/WorkspaceView, API.md „Wünsche UI→Modell“)

Geprüft und in Ordnung:
- Einhängepunkte: `ToolGroup.sheetMetal` („Blech“, Icon `sc.sheet`) – alle drei `switch self` in ToolRail.swift und der
  `switch` in ModelRibbon.swift sind ergänzt (keine weiteren erschöpfenden `switch` über `ToolGroup` gefunden);
  `CommandSearch` → `SheetUI.searchItems`; `WorkspaceView` → `.overlay { SheetFlatOverlay }`; `Viewport.updateLines` →
  `SheetUIOverlay.add(...)` (Variablen `workspace`, `model`, `perPoint` sind dort in Reichweite).
- SheetUIOverlay: `LineGroup(polylines:color:width:onTop:)`, `FillGroup(triangles:color:)`, `AppTheme.isDark`,
  `SketchTheme.linear(_:_:_:)`, `SketchTheme.Metal.selection`, `mesh.trianglePoints(of:)` existieren. Farben Biegung grün /
  offen rot gestrichelt wie beschrieben.
- SheetUIRules: Felder und Reihenfolge wie SolidCraft `rule_editor` (Regel/„Neue Regel…“, Name, Dicke, K-Faktor,
  Biegeradius, Freistichbreite, Freistichtiefe, Form der Eckenentlastung direkt vor Eckenentlastung, Saumspalt, Flanschspalt,
  Winkelanzeige Biegung/Enthalten, Aktive Regel, Regel löschen); Prüfungen (Name 1…128, Dicke > 0, K 0…1, Radius ≥ 0) wie
  SolidCraft; Platzhalter = SolidCraft-Standardausdrücke (= Dicke, = Dicke × 0,5, = Dicke × 4, 0,01 mm).
- **15/21 erledigt (17:49, Oberfläche)** – `SheetConvertDriver.detectsPlate` (zwei größte Flächen gegenläufig parallel, dünn,
  alle übrigen grenzen an beide) + Schalter „Ebene Platte“ → `plateOnly: true`. Nachgerechnet: L-Winkel, U-Profil, Kiste
  werden nicht fälschlich als Platte erkannt; Platte mit Rundlöchern/eckigem Durchbruch wird erkannt. Offen bleibt nur die
  Modellseite (`suggestSheetConversion` ist nicht plattenbewusst, API.md Wunsch 7) – NIEDRIG.
- **23 erledigt (17:49)** – abgeleitete Spalt-Regel wird erst bei OK angelegt (`finish`, SheetUIConvert.swift:~384-398).

32. **App/Sheet/SheetUIConvert.swift:387** – die Bedingung `ruleName(cmd, model) != gapRule(cmd, model)` hat einen
    **Seiteneffekt** (`gapRule` legt die Regel an) und hängt von der Auswertungsreihenfolge ab; schlägt das Umwandeln danach
    fehl, bleibt die Regel trotzdem im Dokument. Vorschlag: `let wanted = gapRuleName(...)`, vergleichen, erst dann anlegen;
    bei Fehler `deleteSheetRule(wanted)`. Schwere: NIEDRIG. Status: offen.
33. **App/Sheet/SheetUIRules.swift:~70-80 / SheetModel.swift:58-60** – `bendRadius` ist eine **feste Zahl** (2,5). SolidCraft-
    Standard ist der Ausdruck `"Thickness"`: ändert man in SolidCraft die Dicke der Standardregel auf 3 mm, wird der Radius
    3 mm; in PencilCAD bleibt er 2,5 mm. Vorschlag: `bendRadius` wie die anderen Felder optional machen (nil = Engine-
    Vorgabe „Thickness“, Platzhalter „= Dicke“) bzw. beim Neuanlegen nicht mitsenden. Schwere: MITTEL. Status: erledigt (17:57, Modell): `SheetRule.bendRadius: Double?` (nil = Ausdruck „Thickness“, wird so an sheet.manage_rules gesendet), `effectiveBendRadius` für die Anzeige; SheetUIRules: optionale Zeile mit Platzhalter „= Dicke“. Alte sheet-rules.json mit Zahl bleiben gültig.
34. **App/Sheet/SheetUIRules.swift** (Namenszeile) – Name ist auch bei **vorhandenen** Regeln editierbar; Umbenennen legt eine
    Kopie an. SolidCraft zeigt „Name“ nur bei „Neue Regel…“. Außerdem „Regel löschen“ nur bei > 1 Regel (SolidCraft: immer bei
    vorhandener Regel; danach gilt „Steel (mm)“). Abweichung, Schwere: NIEDRIG. Status: offen.
35. **App/Sheet/SheetUIOverlay.swift:~70-85** – Biege-/offene Kanten aus `SheetConvertTopology` = Koordinaten der
    `bodies[i].shape`. Gilt wie Befund 19: für Körper einer Komponenteninstanz prüfen, ob `shape` in Weltkoordinaten liegt,
    sonst sitzen die Linien versetzt. Schwere: MITTEL (nur Komponenten). Status: prüfen.
36. **Befund 25 (Bearbeiten aus der Zeitleiste)** – laut API.md Wunsch 5 bearbeitet die Zeitleiste vorerst nur Zahlenwerte
    (`updateFeature`); Panels öffnen sich nicht. Bleibt für „1:1“ offen. Schwere: HOCH. Status: offen (Wunsch an Modell gestellt).
37. **Klärung 19 + 35 (17:50): kein Fehler.** ModelComponents.swift:6 – „Jede Instanz speichert ihre **Weltgeometrie** wie
    jeder Körper“; `bodies[i].shape` liegt also in Weltkoordinaten, Kantenpunkte und Overlay-Linien passen. Befunde 19 und 35
    → erledigt (kein Handlungsbedarf).

## Antwort Modell-Agent – 17:51 UTC

Erledigt: 3, 8, 11, 14–17, 20–22 (Status oben); 5/6/7 waren schon erledigt (Runde 5) und sind nachgeprüft.
Neu: App/Sheet/SheetWorker.swift – SolidCraft-Wiedergabe, STEP-Austausch, Flachmuster und Exporte auf serieller
Warteschlange, Main Actor wartet höchstens 15 s („zu aufwendig“, keine neue Rechnung, solange die alte hängt).
API.md „Wünsche UI→Modell“ 1–7 beantwortet; Wunsch 6 braucht noch `psk.perforation_holes` im Rust-Teil.


## Runde 7 – 17:56 UTC (App/Sheet/SheetModelConvert.swift neu, SheetUIEdit.swift neu, SheetWorker.swift; cargo test)

`cargo test` in SheetKit: alle Tests grün (1 + 11, u. a. `convert_imported_box_to_sheet_metal`, `script_checkpoint_and_restore`).

Erledigt (Code, gegen sheet_convert.rs geprüft; mit echten STEP-Blechteilen noch ungetestet):
- **14/20 erledigt (17:56)** – dünne Körper: Dicke aus größter Fläche + Gegenfläche, **Stirnflächen** (zwischen zwei
  Gegenflächen im Abstand der Dicke) fliegen raus → der Baum bleibt auf einer Haut (SheetModelConvert.swift:~74-96).
- **16/22 erledigt (17:56)** – Zylinder zwischen zwei tangentialen Wänden und schmale **Fasenstreifen** werden Biegungen;
  gesendet wird ein Punkt **auf der Biegefläche** (`bendPoint`), wie SolidCraft es verlangt (Z. ~101-160, 386, 410).
- **17 erledigt (17:56)** – Flächenpunkt = Schwerpunkt des größten Netzdreiecks der Fläche (`sheetInteriorPoints`), liegt auch
  bei L-Flächen/Loch in der Mitte sicher auf der Fläche.
- **32 erledigt (17:56)** – eigener Spalt jetzt als abgeleitete Regel **nur im Rezept** (`sheetConvertSteps(gap:)`), keine
  Regel mehr im Dokument nötig (UI-Seite noch auf die neue API umstellen, s. 41).

38. **App/Sheet/SheetModelConvert.swift:142-152 + SheetUIConvert/SheetUIOverlay** – nach dem Entfernen der Stirnflächen bleiben
    **beide Häute** als Wände übrig. Die Kanten der **Innenhaut** sind weiterhin `isCandidate`, vom Grundflächen-Baum aber nie
    erreicht → sie landen in `open` (rot gestrichelt im Ansichtsfenster, in der Liste „Offene Kanten“, Zählung). SolidCraft
    ignoriert sie (keine Blechflächen); schaltet der Benutzer eine davon auf „Biegung“, geht ein Punkt der **anderen Haut** in
    `bends` → Fehler/Unsinn. Vorschlag: Kandidaten auf die Zusammenhangskomponente der Grundfläche (über Kandidatenkanten)
    beschränken – z. B. `sheetTopology(shape, base:)` oder in UI/Overlay filtern. Schwere: MITTEL. Status: offen.
39. **App/Sheet/SheetModelConvert.swift:154-160 + SheetUIConvert.swift `toggle`** – eine modellierte Biegung (Zylinder/Fase) wird
    nur durch **eine** Kante vertreten (längste Kante zur ersten Wand). Tippt der Benutzer die andere Übergangskante oder die
    Biegefläche selbst an, kommt „Diese Kante liegt nicht zwischen zwei ebenen Wänden – sie bleibt offen.“ – falsch und
    verwirrend. Vorschlag: beim Antippen auch `edge.bendFace`-Flächen und beide Übergangskanten auf den Vertreter abbilden
    (Fläche antippen → `bendFace` suchen). Schwere: MITTEL. Status: offen.
40. **App/Sheet/SheetModelConvert.swift:74-82** – Dicken-Heuristik `d ≤ 0.2·√Fläche`: ein **Vollkörper** wie 100×60×10 gilt als
    dünner Körper, seine Seitenflächen werden Stirnflächen → keine Kandidaten → Platte (10 mm). SolidCraft würde den Quader mit
    `bends` als Kiste aus Blech nehmen. Für die Praxis meist gewollt; Hinweis. Schwere: NIEDRIG.
    Status: erledigt (17:57, Modell): Schwelle auf d ≤ 0,1·√Fläche verschärft (100×60×10 ist jetzt Vollkörper → Kiste mit Biegungen; 100×60×2 und Schalen mit 2 mm bleiben dünn). Platte bleibt über den Schalter „Ebene Platte“ wählbar.
41. **App/Sheet/SheetUIConvert.swift:235-263, 384-398** – UI hat eine **eigene** Plattenerkennung (`detectsPlate`) und legt beim OK
    noch die Dokument-Regel an (`gapRule`), das Modell hat jetzt `sheetIsPlate` und `gap:` in `convertToSheet`/
    `checkSheetConversion`. Zwei Heuristiken können sich widersprechen (Vorschlag sagt Platte, UI nicht oder umgekehrt).
    Vorschlag: UI auf `ModelStore.sheetIsPlate(topology)` / `plan.plateOnly` und `gap:` umstellen, `gapRule` entfernen.
    Schwere: MITTEL. Status: offen.
42. **App/Sheet/SheetUIEdit.swift** (neu, Bearbeiten aus der Zeitleiste = Befund 25/36) – Felder/Beschriftungen stimmen mit den
    Erstell-Panels; nur Geändertes wird zurückgeschrieben (Ausdrücke bleiben). **Noch nicht eingehängt** (17:56): kein Treiber
    ruft `SheetEdit.load`/`commit`/`rows`. Beim Einhängen beachten: `refresh` der Treiber muss bei `cmd.editing != nil` sofort
    `nil` liefern – `SheetPerforateDriver.refresh` würde sonst mit Standardwerten (Schlüssel `diameter` statt `edit.diameter`)
    eine **zusätzliche** Perforation als Vorschau an den letzten Blechkörper hängen, und ein `finish` mit `LegacyFinish.commit`
    würde sie übernehmen; ebenso `SheetFoldState.refresh` (Entfalten/Wieder falten). `finish` muss beim Bearbeiten
    `SheetEdit.commit` statt `LegacyFinish.commit` rufen. Schwere: HOCH (beim Einhängen). Status: beobachten.
43. **App/Sheet/SheetModel.swift:596-609 ↔ SheetKit/src/psk.rs** – Swift fragt `psk.perforation_holes` ab (Befund 29), die
    Rust-Schicht kennt den Befehl **noch nicht** (psk.rs: nur bodies/export_step/import_step/edges). Durch `try?` kein Absturz,
    aber Löcher bleiben leer. Rust: `psk.perforation_holes {body}` → `{"holes":[{"center":[x,y],"radius":r}]}` (Feldnamen wie
    in Swift erwartet) ergänzen, plus Test. Schwere: MITTEL. Status: erledigt (Rust-Agent, ~18:05): `psk.perforation_holes {body?}` → `{"body","count","truncated","holes":[{"center":[x,y],"radius","field"}]}`, Test in `perforate_shows_in_flat_pattern_and_dxf`, API.md.
44. **App/Sheet/SheetWorker.swift + SheetModelReplay.swift:467-472** – auch das **Laden/Nachbauen des Verlaufs**
    (`replaySheetMetal` → `sheetReplayShape`) läuft mit dem 15-s-Zeitlimit. Großes Rezept beim Öffnen eines Projekts → Feature
    scheitert („zu aufwendig“), Blechkörper fehlt, und solange die alte Rechnung weiterläuft, scheitert **jeder** weitere
    Blechschritt (`state.begin()` = false). Vorschlag: beim Nachbauen des Verlaufs höheres bzw. kein Zeitlimit; Zeitlimit nur
    für interaktive Vorschauen. Außerdem: STEP lesen (OCCT) im Hintergrund, während der Vordergrund nach einem Zeitlimit
    erneut STEP schreibt – STEPControl nutzt globale Parameter (`Interface_Static`), nicht threadsicher. Schwere: MITTEL.
    Status: offen.

## Runde 8 – 18:02 UTC (Build-Einbindung: generate-project.sh, project-occt-sheet.yml, build-sheet-ios.sh, module.modulemap)

Geprüft und in Ordnung: `generate-project.sh` wählt `project-occt-sheet.yml` nur, wenn OCCT **und**
`Vendor/PencilSheet.xcframework` existieren, und warnt, wenn SheetKit neuer ist als das gebaute Modul.
`project-occt-sheet.yml` erbt per `include` und setzt `PENCIL_SHEETKIT` mit `$(inherited)` (die Basis-Specs setzen keine
eigenen Bedingungen → nichts wird überschrieben); `-framework Security -lc++` für die Rust-Abhängigkeiten.
`module.modulemap` (`module PencilSheet`) passt zu `import PencilSheet` in SheetKernel.swift (nur unter `#if PENCIL_SHEETKIT`);
das Bridging-Header bleibt unberührt. xcframework für `aarch64-apple-ios` + `aarch64-apple-ios-sim` (kein x86_64-Simulator –
nur auf Intel-Macs relevant). Die Rust-Abhängigkeiten enthalten **kein** eigenes OpenCASCADE (truck-*), also keine doppelten
OCCT-Symbole beim Linken. Keine neuen Befunde in dieser Runde; offen bleiben 1, 13, 24, 27, 28, 30, 33, 34, 38–44.

## Runde 9 – 18:06 UTC (SheetUI.swift Register/Ribbon/Suche; Nachprüfung 10, 11)

Geprüft und in Ordnung: `registerSheet()` meldet alle 11 Treiber an; Ribbon-Reihenfolge und Gruppen wie SolidCraft
workspace.rs (SKIZZE · ERSTELLEN Flansch, Pfadflansch, Umkantung, Falten, Perforieren, In Blech umwandeln · ABWICKLUNG Entfalten,
Wieder falten, Flachmuster erstellen · AUSGABE DXF, Biegetabelle · REGELN); Icons `sc.*` = SolidCraft-SVG-Namen;
`RibbonCommand`-Aufrufe passen zur Memberwise-Reihenfolge (`featured`, `isActive`, `isEnabled`, `run`). Ohne gebautes
Blechmodul: Hinweis-Kachel statt Absturz, Befehle gesperrt.
- **11 erledigt (18:06)** – `sheetBuild` füllt jetzt `sessionCache` (SheetModelReplay.swift:199).
- 10 weiterhin offen (fremde Vorschau wird übernommen), NIEDRIG.

45. **App/Workspace/ModelRibbon.swift (Gruppe Ändern)** – SolidCraft zeigt „In Blech umwandeln“ zusätzlich unter
    MODEL › MODIFY (workspace.rs:84/459). In PencilCAD nur unter „Blech“. Für 1:1 in der Ändern-Gruppe ergänzen.
    Schwere: NIEDRIG. Status: offen.

## Runde 10 – 18:12 UTC (scripts/build-sheet-ios.sh geändert, Cargo.toml, .gitignore)

Geprüft und in Ordnung: `bash -n` ohne Fehler; nur macOS, prüft xcodebuild + iOS-SDK, installiert rustup ins
Benutzerverzeichnis, Rust ≥ 1.95 (Edition 2024 von SolidCraft), `--locked`, Zielordner `build/sheetkit-target` (liegt unter dem
schon ignorierten `build/`), `SheetKit/target/` neu in .gitignore. SolidCraft ist per `rev = 98b57a35…` fest gepinnt
(Engine **und** alle `[patch]`-Einträge gleich) → baut genau den geprüften Stand.

46. **scripts/build-sheet-ios.sh:~45-48** – bei zu alter Toolchain `rustup default stable`: ändert die **globale** Standard-
    Toolchain des Benutzers. Schonender: `rustup update stable` und dann `cargo +stable …` bzw. `RUSTUP_TOOLCHAIN=stable`
    nur für dieses Skript. Schwere: NIEDRIG. Status: offen.
