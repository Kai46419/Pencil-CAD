# SheetKit – Blechmodul (Punkt 16)

PencilCAD übernimmt das Blechmodul von SolidCraft (github.com/tangency-labs/solidcraft, MIT OR Apache-2.0)
1:1, indem die SolidCraft-Engine (Rust) als statische Bibliothek eingebettet wird. Alle Blechbefehle
(`sheet.*`) laufen unverändert in SolidCraft; PencilCAD liefert Eingaben (Skizzenprofile, Kantenpunkte,
Körper als STEP) und übernimmt die Ergebnisse (Körper als STEP → OCCT, Flachmuster als JSON, DXF, CSV).

## Schichten und Dateibesitz

| Schicht | Dateien | Inhalt |
|---|---|---|
| Rust | `SheetKit/` (Cargo-Crate `pencil-sheet`, staticlib) | C-ABI über `solidcraft-engine` (git-Abhängigkeit, fester Commit) |
| Build | `scripts/build-sheet-ios.sh` | baut `Vendor/PencilSheet.xcframework` (iPad arm64 + Simulator), installiert bei Bedarf rustup/Ziele |
| C-Header | `SheetKit/include/pencil_sheet.h` | siehe unten |
| Swift-Brücke | `App/Sheet/SheetKernel.swift` | dünne Hülle um die C-Funktionen (nur im OCCT-Build mit `PENCIL_SHEETKIT`) |
| Modell | `App/Sheet/SheetModel*.swift` | Blechrezepte je Körper, Wiedergabe, Speichern, Verlauf, Skizzen→SolidCraft |
| Oberfläche | `App/Sheet/SheetUI*.swift`, `App/Sheet/FlatPatternView.swift` | Ribbon-Gruppe „Blech“, Panels, Kantenwahl, Flachmuster-Ansicht, offene Kanten |
| Projekt | `project-occt.yml` | xcframework + Flag `PENCIL_SHEETKIT`, nur wenn `Vendor/PencilSheet.xcframework` existiert |

Bestehende Dateien nur mit minimalen Einhängepunkten ändern (ein Aufruf / ein `case`), weil parallel an
Punkt 1–15 gearbeitet wird.

## C-ABI (`pencil_sheet.h`)

```c
typedef struct PskSession PskSession;

PskSession *psk_session_new(void);               // leere SolidCraft-Sitzung (Einheiten mm)
void        psk_session_free(PskSession *s);

// Ein Befehl: command z. B. "sheet.flange", params ein JSON-Objekt (UTF-8).
// Rückgabe (immer, mit psk_string_free freigeben):
//   {"ok":true,"result":<JSON des Befehls>}  oder  {"ok":false,"error":"<Text>"}
char *psk_execute(PskSession *s, const char *command, const char *params_json);

// Mehrere Befehle der Reihe nach: script_json = {"commands":[{"command":"…","params":{…}}, …]}
// Rückgabe {"ok":true,"results":[…]} oder {"ok":false,"error":"…","index":<n>}
char *psk_run_script(PskSession *s, const char *script_json);

// Zustand sichern/zurücksetzen (Vorschau während ein Panel offen ist)
uint64_t psk_checkpoint(PskSession *s);
int32_t  psk_restore(PskSession *s, uint64_t id);   // 0 = ok

void        psk_string_free(char *str);
const char *psk_version(void);                   // statisch, nicht freigeben
```

Komfortbefehle, die `pencil-sheet` zusätzlich zu den SolidCraft-Befehlen über `psk_execute` anbietet
(Präfix `psk.`):

- `psk.bodies` → `{"bodies":[{"name","sheet":bool,"unfolded":bool}]}`
- `psk.export_step` `{"body":"…","path":"…"}` → `{"path"}` (exakter B-Rep des Körpers als STEP)
- `psk.import_step` `{"path":"…","name":"…"}` → `{"bodies":[names]}` (für „In Blech umwandeln“)
- `psk.edges` `{"body":"…"}` → `{"edges":[{"mid":[x,y,z],"a":[…],"b":[…],"faces":[i,j],"convex":bool,"angle_deg":…}]}`
  (Kanten mit Nachbarflächen, für Kantenwahl und den Modus „offene Kanten“)

### Umsetzung und Ergänzungen (Rust-Schicht, Stand SolidCraft `98b57a3`)

Nur ergänzt, nichts am obigen Vertrag geändert:

- `psk.bodies`: je Körper zusätzlich `"thickness"` (mm) und `"rule"` (Name der Blechregel), beide `null`
  bei Nicht-Blechkörpern. Reihenfolge = Modellreihenfolge; Namen wie SolidCraft sie vergibt (`Body1`, …).
- `psk.export_step`: zusätzlich `"bytes"`, `"body"`. Intern `file.export` mit `format:"step"`, `bodies:[body]`
  (SolidCrafts exakter STEP-Schreiber: Biegungen als `CYLINDRICAL_SURFACE`). Koplanare Teilflächen, die
  SolidCraft intern an Panelgrenzen trennt, kommen im STEP zusammengefasst an (gleiche Geometrie).
  Abgewickelter Körper (`sheet.unfold`) → flacher STEP.
- `psk.import_step`: `name` optional; zusätzlich `"feature"`, `"component"`, `"warnings"`. Intern
  `file.insert_step`: die Körper landen als Import-Feature in einer eigenen Komponente und sind danach mit
  ihrem Namen (aus `bodies`) für `sheet.convert {"body":…}` und `psk.edges` ansprechbar.
- `psk.edges`: je Kante zusätzlich `"index"` (= Index in SolidCrafts `model.edges`), `"name"` (stabiler
  SolidCraft-Kantenname), `"length"`, `"closed"` (Kreiskante) und bei zwei Nachbarflächen `"normals"`
  (Außennormalen beider Flächen an `mid`). `faces` hat 1 Eintrag bei Rand-/Nahtkanten; dann sind
  `convex` und `angle_deg` `null`. `angle_deg` = Winkel zwischen den Außennormalen: 0° tangential,
  90° rechtwinklige Körperkante, 180° Messerkante. `convex: true` = Außenkante (Material innen),
  `false` = Innen-/Kehlkante. Punkte auf 1e-9 mm gerundet.
- `psk_run_script`: bricht beim ersten Fehler ab; Befehle vor `index` **bleiben angewendet** (vorher
  `psk_checkpoint`, wenn zurückgerollt werden soll). Fehlertext unverändert von SolidCraft (nennt den Befehl
  meist selbst, z. B. „invalid parameters for `sheet.flange`: …“).
  Fehlt `params` in einem Eintrag, gilt `{}`. `psk.*`-Befehle sind im Skript erlaubt.
- `psk_execute`: `params_json` NULL oder leer = `{}`; Fehler bei NULL-Sitzung/-Befehl, ungültigem UTF-8 oder JSON.
- `psk_restore`: 0 = ok, -1 = NULL-Sitzung, -2 = unbekannter (oder schon verbrauchter) Checkpoint. Ein
  Checkpoint und alle späteren sind nach dem Zurücksetzen verbraucht (SolidCraft hält höchstens 32).
- `psk_checkpoint` liefert 0 nur bei NULL-Sitzung.
- `psk_version` → `"pencil-sheet 0.1.0 (SolidCraft 98b57a3)"`.
- Panics im Kern → `{"ok":false,"error":"interner Fehler im Blechkern: …"}` (catch_unwind an jeder Grenze;
  `panic = "unwind"` im Release-Profil ist dafür Pflicht).

- `psk.perforation_holes` `{"body"?}` → `{"body","count","truncated":bool,"holes":[{"center":[x,y],"radius":r,"field":i}]}`
  (Ergänzung, Wunsch 6): Lochmitten aller Perforationsfelder (`field` = Index in `sheet.flat_pattern`
  `perforations`) im **selben Koordinatensystem wie `sheet.flat_pattern`** (`outline`, `cutouts`, `bends`) –
  SolidCraft `SheetBody::perforation_holes`, wie dessen Flachansicht sie zeichnet. Ohne `body` der zuletzt
  erzeugte Blechkörper. Höchstens 1 000 000 Löcher (`truncated:true`, wenn gekappt). Kein Blechkörper → Fehler;
  ohne Perforation `holes:[]`. Getestet in `perforate_shows_in_flat_pattern_and_dxf`.

### „In Blech umwandeln“ und offene Kanten

`sheet.convert {"body", "face":[x,y,z], "bends":[[x,y,z],…]}`: `face` = Punkt auf der festen (großen,
ebenen) Fläche, `bends` = Mittelpunkte (`mid` aus `psk.edges`) der scharfen Kanten, die Biegungen werden.
Jede Kante zwischen zwei so erreichten Flächen, die **nicht** in `bends` steht, wird mit dem Spalt (`gap`)
der Regel **aufgeschnitten** – das ist die Wahl der offenen Kanten. Für einen oben offenen Kasten also: die
vier Boden-Außenkanten als `bends`, die vier senkrechten Ecken werden offen. Ein Vollkörper wird nach innen
mit der Regeldicke ausgehöhlt, ein geschalter Körper behält seine Wanddicke. Kandidaten für `bends` sind
Kanten mit `convex:true` und `angle_deg` ≈ 90 (oder anderer Winkel ≠ 0); Rundungs-/Fasenflächen zwischen
zwei Wänden werden über einen Punkt mitten auf ihnen zu einer Biegung. Getestet in
`tests/sheet_abi.rs::convert_imported_box_to_sheet_metal`.

## Skizzen übergeben

`sketch.create` nimmt eine freie Ebene als `{"origin":[x,y,z], "x_dir":[x,y,z], "y_dir":[x,y,z]}` in
Weltkoordinaten (mm; nur Zahlen, keine Ausdrücke). Eine **Normale** gibt es als Parameter nicht: SolidCraft
bildet sie als `x_dir × y_dir`. PencilCAD (Ursprung `o`, Normale `n`, x-Achse `x`) übergibt also

    origin = o,   x_dir = x,   y_dir = n × x      (alle normiert, x ⟂ n)

Dann gilt Welt = `origin + u·x_dir + v·y_dir` für einen Skizzenpunkt `[u, v]`, und der Grundflansch wächst
mit seiner Dicke entlang `+n` (Gegenrichtung: `n` und damit `y_dir` umdrehen, oder `"flip": true` im Grundflansch). Benannte Ebenen: `"XY"`,
`"XZ"`, `"YZ"`. Beispiel (getestet in `sketch_on_free_plane`): Ebene um 30° um X gekippt, Ursprung
(10, 20, 5), also n = (0, −0,5, 0,866), x = (1, 0, 0), y = n × x = (0, 0,866, 0,5):

```json
{"commands":[
  {"command":"sheet.manage_rules","params":{"name":"Stahl 2","thickness":"2 mm","bend_radius":"2 mm","k_factor":0.4,"gap":"0.5 mm","active":true}},
  {"command":"sketch.create","params":{"name":"Schräg","plane":{"origin":[10,20,5],"x_dir":[1,0,0],"y_dir":[0,0.8660254037844387,0.5]}}},
  {"command":"sketch.line","params":{"points":[[0,0],[80,0],[80,40],[0,40]],"closed":true}},
  {"command":"sketch.finish","params":{}},
  {"command":"sheet.flange","params":{"sketch":"Schräg"}}
]}
```

Elemente (Skizzenkoordinaten `[u,v]` in mm, ids optional, damit Konturflansch/Pfadflansch/Falten sie über
`curves` ansprechen):

| PencilCAD | SolidCraft-Befehl |
|---|---|
| Linienzug / Polygon | `sketch.line {"points":[[u,v],…], "closed"?:bool, "ids"?:["l1",…]}` (ein id je Segment) |
| Rechteck | `sketch.rectangle.two_point {"p0":[u,v],"p1":[u,v]}` |
| Kreis | `sketch.circle.center {"center":[u,v],"radius":r}` |
| Bogen | `sketch.arc.center_point {"center","start","end"}` (gegen den Uhrzeigersinn von start) oder `{"center","start","sweep":°}`; `sketch.arc.three_point` |
| Spline | `sketch.spline.fit_point` |

Endpunkte, die genau aufeinanderfallen, werden automatisch verbunden (`connect` Standard true). Bei
mehreren geschlossenen Bereichen wählt `sheet.flange {"sketch","profiles":[{"point":[u,v]}]}` den Bereich,
der den Punkt (Skizzenkoordinaten) enthält; Kreise darin werden Löcher (getestet in
`base_flange_with_arc_and_hole_on_free_plane`). Konturflansch: offene Linienkette + `"curves":[ids]`,
`"distance"`. Pfadflansch: Skizze auf einer Ebene quer zur Kante, `"edge":[x,y,z]`, `"curves"`. Falten:
`"points":[[x,y,z],[x,y,z]]` auf der Blechoberseite oder `"sketch"+"curve"`.

## Rust-Crate, Build, Tests

- `SheetKit/Cargo.toml`: `solidcraft-engine` als git-Abhängigkeit mit festem `rev`; SolidCrafts
  `[patch.crates-io]` für die geänderten truck-Crates aus `vendor/` ist gespiegelt (sonst bekäme man das
  ungepatchte truck von crates.io). `Cargo.lock` ist eingecheckt und folgt SolidCrafts eigener Lock-Datei
  (gleiche Versionen aller Abhängigkeiten). Beim Aktualisieren alle sechs `rev` gleich setzen.
- Tests: `cd SheetKit && cargo test` (Linux/macOS) – Gesamtumfang über die C-ABI in `tests/sheet_abi.rs`.
- iPad: `./scripts/build-sheet-ios.sh` → `Vendor/PencilSheet.xcframework` (Modul `PencilSheet`, Header +
  modulemap). Kein C-Code in den Abhängigkeiten (alles reines Rust, keine build.rs braucht das iOS-SDK; die
  zwei build.rs von SolidCraft erzeugen nur Rust-Quelltext bzw. lesen `git rev-parse`). Die App muss zusätzlich
  linken: **`-framework CoreFoundation -liconv`** (laut `--print native-static-libs`: CoreFoundation über
  chrono/iana-time-zone in truck-stepio; libSystem/libc/libm sind ohnehin dabei). Linker-Flag `-dead_strip`
  (Xcode-Standard im Release) hält die App klein.
- `SheetKit/COMMANDS.md` ist die kuratierte Referenz (von Hand gepflegt). Die Rohliste aus SolidCrafts
  Befehlsdokumentation erzeugt `cargo run --example commands > COMMANDS-RAW.md` (nie nach COMMANDS.md umleiten).

## Swift-Brücke (`App/Sheet/SheetKernel.swift`)

```swift
enum SheetJSON { … }                       // Codable-JSON-Wert (null/bool/number/string/array/object)

struct SheetCommand: Codable, Hashable {   // ein SolidCraft-Befehl
    var command: String
    var params: SheetJSON
}

struct SheetKernelError: LocalizedError { let message: String; var index: Int? }

final class SheetKernel {
    static var isAvailable: Bool           // false ohne PENCIL_SHEETKIT
    init() throws
    @discardableResult func execute(_ cmd: SheetCommand) throws -> SheetJSON
    @discardableResult func run(_ cmds: [SheetCommand]) throws -> [SheetJSON]
    func checkpoint() -> UInt64
    func restore(_ id: UInt64) throws
    func bodies() throws -> [(name: String, sheet: Bool, unfolded: Bool)]
    func shape(of body: String) throws -> PCKShape       // über psk.export_step + PCKShape.readSTEP
    func importBody(_ shape: PCKShape, name: String) throws -> [String]
}
```

Ohne `PENCIL_SHEETKIT` existiert dieselbe Schnittstelle, `isAvailable == false`, `init()` wirft
„Blechmodul nicht gebaut – im Terminal ./scripts/build-sheet-ios.sh ausführen“.

## Datenmodell

Ein Blechkörper in PencilCAD speichert sein **Rezept**: die geordnete Liste der `SheetCommand`s, die ihn in
einer frischen SolidCraft-Sitzung erzeugen (Blechregel, Skizze, Flansche …). Neu berechnet wird durch
Wiedergabe; Ergebnis-Körper kommt per STEP nach OCCT. Bearbeiten im Verlauf = Befehl im Rezept ändern und
neu wiedergeben. Abwicklung = Rezept + `sheet.flat_pattern`.

Befehlsreferenz mit allen Parametern: `SheetKit/COMMANDS.md`.

## Skizzen übergeben

Eine PencilCAD-Skizze (`StoredSketch`, Ebene `SketchPlane` mit `origin`, `u`, `v`) wird als SolidCraft-Skizze in
das Rezept geschrieben: `sketch.create {plane: {origin, x_dir: u, y_dir: v}, name}` (freie Ebene in Weltkoordinaten,
lokale Koordinaten bleiben gleich), danach je Kontur `sketch.line {points, closed?}` (Linienketten),
`sketch.arc.three_point {start, through, end}`, `sketch.circle.center {center, radius}`,
`sketch.ellipse {center, major, minor_radius}`, `sketch.spline.control_point {points}` (Bézier-Stücke und
B-Splines), `sketch.spline.fit_point {points, periodic: true}` (geschlossene Splines), zum Schluss `sketch.finish`.
Übertragen werden nur die gewählten Bereiche (Außenkontur + Löcher); der Grundflansch wählt den Bereich über
`profiles: [{point: [x, y]}]` (Punkt im Bereich, lokal). Skizzennamen im Rezept: `pc-<UUID>`.

## Swift-Modell-API (`App/Sheet/SheetModel*.swift`)

Typen (`SheetModel.swift`):

- `SheetStep { id: UUID, title: String, command: SheetCommand }` – ein Rezeptschritt.
- `SheetBodyInfo { steps, kernelBody, rule, sourceFile?, resultBox?; recipe; isUnfolded }` – liegt in
  `SceneBody.sheetMetal` (nil = kein Blechkörper), gespeichert in bodies.json.
- `SheetRule { name, thickness, kFactor, bendRadius? (nil = „Thickness“), effectiveBendRadius, reliefWidth?, reliefDepth?, cornerRelief?, cornerReliefShape?,
  hemGap?, gap?, angleDisplay?; command(active:) }`, `SheetRule.cornerShapes` (Schlüssel + deutscher Titel).
- `FlatPattern { body, rule, thickness, kFactor, size, outline: [[SIMD2]], cutouts: [[SIMD2]], bends: [FlatBend],
  pockets, bendZones, perforationCount, raw; upBends, downBends, bounds }`,
  `FlatBend { position (= id, laufende Zeile), index (Biegungsnummer, kann sich wiederholen), angle, includedAngle, radius, up,
  allowance, length, start, end }`.
- `SheetDXFOptions { exactCurves, bendNotes, bendLines, singleLayer, etchText }`.
- `SheetModelEdge { edge, start, end, mid, faces, angle, isCandidate }`, `SheetModelFace { face, area, normal, point }`,
  `SheetConversionPlan { baseFace, basePoint, openEdges, bendEdges, problem }` – OCCT-Nummern (wie `EdgeRef.edge`).
- `SheetDocument` (`model.sheetDocument`, ObservableObject): `rules`, `activeRuleName`, `activeRule`, `lastError`.
- Befehlsbauer: `SheetCommand.edgeFlange(edges:height:angle:radius:heightFrom:position:flip:cornerReliefShape:
  cornerRelief:then:)`, `.hem(edges:length:gap:flip:)`, `.fold(from:to:angle:radius:position:fixed:flip:)`,
  `.perforate(diameter:pitch:margin:pattern:)`, `.unfold`, `.refold`; `command.title` (deutscher Name).

Hintergrund: Wiedergabe, STEP-Austausch, Flachmuster und Exporte laufen auf einer seriellen Warteschlange
(`SheetWorker`, App/Sheet/SheetWorker.swift), auch alles STEP-Lesen/-Schreiben des Blechmoduls; der Main Actor wartet
höchstens 15 s (Nachbau des Verlaufs/Projekt-Öffnen 120 s), danach Fehler „zu aufwendig“ (`SheetKernelError.timedOut`);
hinter einer hängenden Rechnung wartet höchstens ein neuer Auftrag.

Funktionen am `ModelStore` (alle auf dem Main Actor; `Bool` = gelungen, sonst steht der Fehler in `model.message`
und `sheetDocument.lastError`; `preview: true` zeigt eine Vorschau, übernommen wird mit `commitPreview()`,
verworfen mit `cancelPreview()`):

```swift
var sheetAvailable: Bool; var sheetUnavailableReason: String?
func sheetInfo(_ body: Int) -> SheetBodyInfo?; func isSheetBody(_ body: Int) -> Bool; var sheetBodies: [Int]
func createSheetBaseFlange(sketch: Int, regions: [Int] /* genau ein Bereich */, rule: String? = nil, flip: Bool = false, preview: Bool = false) -> Bool
func createSheetContourFlange(sketch: Int, entities: [Int], distance: Double, rule: String? = nil, flip: Bool = false,
                              reverse: Bool = false, preview: Bool = false) -> Bool
func appendSheetCommand(_ command: SheetCommand, to body: Int, title: String? = nil, preview: Bool = false) -> Bool
func appendSheetPathFlange(to body: Int, edge: SIMD3<Double>, sketch: Int, entities: [Int], radius: Double? = nil,
                           preview: Bool = false) -> Bool
func setSheetUnfolded(_ unfolded: Bool, body: Int) -> Bool
func updateSheetStep(body: Int, step: UUID, command: SheetCommand) -> Bool
func deleteSheetStep(body: Int, step: UUID) -> Bool
func copySheetBody(_ body: Int, offset: SIMD3<Double>) -> Bool
func mirrorSheetBody(_ body: Int, planeOrigin: SIMD3<Double>, normal: SIMD3<Double>, keepOriginal: Bool = true) -> Bool
func setSheetRule(_ rule: SheetRule, active: Bool = true); func setActiveSheetRule(_ name: String); func deleteSheetRule(_ name: String)
func flatPattern(of body: Int) throws -> FlatPattern
func exportFlatPatternDXF(of body: Int, options: SheetDXFOptions = SheetDXFOptions()) throws -> URL
func exportBendTableCSV(of body: Int) throws -> URL
func sheetConversionTopology(of body: Int) -> (faces: [SheetModelFace], edges: [SheetModelEdge])
func sheetBendEdges(of body: Int, open: Set<Int>) -> Set<Int>
func suggestSheetConversion(of body: Int, baseFace: Int? = nil, rule: String? = nil) -> SheetConversionPlan?
func checkSheetConversion(of body: Int, baseFace: Int, openEdges: Set<Int>, rule: String? = nil, gap: Double? = nil) -> SheetConversionPlan?
func convertToSheet(_ body: Int, baseFace: Int, openEdges: Set<Int>, rule: String? = nil, plateOnly: Bool = false,
                    gap: Double? = nil, preview: Bool = false) -> Bool
func sheetStep(for feature: Feature) -> (body: Int, step: SheetStep)?
func sheetBodyIsModified(_ body: Int) -> Bool
```

Verlauf: jeder Blechschritt ist ein Feature `FeatureKind.sheetMetal` (Zeitleiste, Undo/Redo, Werte ändern über
`updateFeature` – die Zahlenparameter der Schritte erscheinen als Feature-Parameter `"<Schritt>.<Schlüssel>"`).
Punkte in Befehlen (Kanten, Faltlinien) sind Weltkoordinaten.

## Wünsche UI→Modell

Von der Oberfläche (`App/Sheet/SheetUI*.swift`, `FlatPatternView.swift`). Bis zur Antwort baut die Oberfläche nur
gegen die vorhandene API (Umgehungen stehen als `NOTLÖSUNG (SheetKit/API.md „Wünsche UI→Modell“ n)` in den
SheetUI-Dateien).

1. **Spalt beim Umwandeln** (Kais Wunsch „Spalt je offener Kante, Standard aus Regel“): SolidCraft kennt nur den
   Spalt der Regel (`gap`) für alle offenen Kanten. Bitte `convertToSheet(…, gap: Double? = nil)` und
   `checkSheetConversion(…, gap: Double? = nil)` – nil = Regel. Umsetzung im Modell z. B. über eine abgeleitete
   Regel im Rezept. Ein eigener Spalt **je Kante** geht mit der Engine nicht; die Oberfläche zeigt deshalb je
   offener Kante den gemeinsamen Spalt an. Bis dahin legt die Oberfläche **beim OK** (nicht bei jeder Vorschau,
   REVIEW 23) eine Regel „<Regel> · Spalt <x> mm“ mit `setSheetRule(_, active: false)` an und wandelt mit deren
   Namen als `rule` um (`SheetConvertDriver.gapRule`); die Vorschau zeigt bis dahin den Spalt der Regel.
   **erledigt (Modell-Agent, 17:51 UTC):** `convertToSheet(…, plateOnly:, gap: Double? = nil, preview:)` und
   `checkSheetConversion(…, rule:, gap: Double? = nil)`. SolidCraft `sheet.convert` kennt keinen Spalt-Parameter (nur
   `body, face, bends, rule`; mit `bends` werden Regelwerte abgelehnt), auch keinen je Kante. Umsetzung: abgeleitete
   Regel „<Regel> · Spalt x mm“ **nur im Rezept** des Körpers (nicht in `sheetDocument.rules`) – `gapRule` kann entfallen.
   **Oberfläche umgestellt (UI-Agent):** `gapRule` entfernt, Probe und Vorschau/OK übergeben `gap:`.
2. **Kantenflansch je Kante** (SolidCraft „Pro Kante“): die Oberfläche schickt über `appendSheetCommand` einen
   selbst gebauten `sheet.flange` mit `edges: [[x,y,z] | {"point":[x,y,z], "angle":"105 deg", "height":30}]`.
   Falls das Modell Punkte in Befehlen umrechnet (Körper verschoben), bitte auch `point` in Objekt-Einträgen von
   `edges` umrechnen. Ebenso Ausdrücke als Strings (`"90 deg"`) in `angle`/`height`/`then[].angle` durchreichen.
   **erledigt (Modell-Agent, 17:51 UTC):** Befehle werden unverändert durchgereicht (Objekt-Einträge, Ausdrücke als Strings). Punkte
   werden nie umgerechnet: wurde der Körper außerhalb verschoben, kommt ein `solid.move` ins Rezept. Nur reine
   Zahlen bzw. „<Zahl> deg/mm“ auf oberster Ebene erscheinen als Feature-Parameter; Ausdrücke bleiben unberührt.
3. **Warnung des letzten Befehls**: SolidCraft liefert `warning` (Entlastung ausgelassen, Ecke offen …). Bitte als
   `sheetDocument.lastWarning: String?` (nach jeder Vorschau/Übernahme gesetzt bzw. geleert) – das Panel zeigt sie.
   **erledigt (Modell-Agent, 17:51 UTC):** `sheetDocument.lastWarning` (@Published), bei jedem Blechbefehl geleert und bei Warnungen gesetzt.
4. **Bereiche/Elemente**: `createSheetBaseFlange(regions:)` = Indizes wie `RegionRef.region` (StoredSketch.regions);
   `entities:` (Kontur/Pfad) = Indizes in `StoredSketch.entities`; die Oberfläche bietet `.line` und offene
   `.polyline` an. Bitte bestätigen bzw. korrigieren.
   **erledigt (Modell-Agent, 17:51 UTC):** bestätigt – `regions` = Indizes in `StoredSketch.regions` (wie `RegionRef.region`, genau ein
   Bereich), `entities` = Indizes in `StoredSketch.entities` (`.line` und offene `.polyline`).
5. **Bearbeiten aus der Zeitleiste**: zum Öffnen des passenden Panels mit den gespeicherten Werten wäre
   `func sheetStep(for feature: Feature) -> (body: Int, step: SheetStep)?` hilfreich. Bis dahin bearbeitet die
   Zeitleiste die Zahlenwerte wie gewohnt (`updateFeature`).
   **erledigt (Modell-Agent, 17:51 UTC):** `func sheetStep(for feature: Feature) -> (body: Int, step: SheetStep)?` – Hauptschritt des
   Features (nicht Skizze/Regel/Import) mit den aktuellen Werten aus dem Rezept; ändern mit
   `updateSheetStep(body:step:command:)` (ein Undo-Schritt, Nachbau ab dem Feature).
6. **Perforationslöcher im Flachmuster** (REVIEW 29): SolidCraft zeichnet jedes Loch als Kreis
   (`sheet.perforation_holes(field)`); `sheet.flat_pattern` liefert nur `count`. Bitte z. B.
   `FlatPattern.perforationHoles: [(center: SIMD2<Double>, radius: Double)]` (über einen SheetKit-Zusatzbefehl). Die
   2D-Ansicht zeichnet sie dann als Kreise (Strich 1,4, nur ≥ 1 px); bis dahin steht nur die Anzahl im Panel.
   **erledigt (Swift, Modell-Agent, 17:51 UTC):** `FlatPattern.perforationHoles: [(center: SIMD2<Double>, radius: Double)]`, gefüllt über
   `psk.perforation_holes {body}` → `{"holes":[{"center":[x,y],"radius":r}]}` (nur wenn `perforations` nicht leer;
   Fehler werden ignoriert → leer). **Offen für den Rust-Agent:** Befehl in SheetKit/src/psk.rs ergänzen (je Feld
   `sheet.perforation_holes(field)` wie SolidCraft `FlatView::cache_perforations`, Flachkoordinaten).
   **erledigt (Rust-Agent, ~18:05):** `psk.perforation_holes` in SheetKit/src/psk.rs, Format wie oben erwartet (plus
   `field`, `count`, `truncated`), Flachkoordinaten = `sheet.flat_pattern`; getestet.
7. **Platte erkennen beim Vorschlag** (REVIEW 15/21): `suggestSheetConversion` schlägt bei einer ebenen Platte die
   Kanten Deckfläche–Stirnfläche als Biegungen vor. Die Oberfläche erkennt Platten jetzt selbst
   (`SheetConvertDriver.detectsPlate`: zwei größte Flächen gegenläufig parallel, dünn, alle anderen grenzen an beide;
   Schalter „Ebene Platte“) und ruft dann `convertToSheet(…, openEdges: [], plateOnly: true)` ohne Vorschlag. Bitte im
   Modell gleich behandeln (`SheetConversionPlan.plateOnly`), damit Vorschlag und Probe übereinstimmen. Ebenso REVIEW
   14/16/20/22 (Schalenkörper: nur eine Haut; Zylinder-/Fasenbiegungen): die Oberfläche kann nur gerade Kanten
   zwischen zwei ebenen Flächen umschalten – runde Biegungen bräuchten antippbare Biegeflächen
   (`SheetModelFace` auch für Zylinder, Punkt in `bends`).
   **erledigt (Modell-Agent, 17:51 UTC):** Topologie wie SolidCraft sheet_convert.rs: dünne Körper (Gegenfläche der größten Fläche im
   kleinen Abstand) ohne Stirnflächen → Baum bleibt auf einer Haut; Platte = keine Kandidatenkante →
   `SheetConversionPlan.plateOnly = true`, Vorschlag ohne Biegungen, Probe mit `plateOnly`. Modellierte Biegungen
   (Zylinder zwischen zwei tangentialen Wänden, Fasenstreifen) erscheinen als **eine** Kandidatenkante (ihre längste
   Kante zur ersten Wand; `SheetModelEdge.bendFace`, `bendPoint` = Punkt auf der Biegefläche, `faces` = die beiden
   Wände) – die Oberfläche schaltet sie wie jede Kante um. `SheetModelFace.point` liegt sicher im Inneren (größtes
   Netzdreieck). `SheetConversionPlan.timedOut` = Probe am Zeitlimit abgebrochen.
   **Oberfläche umgestellt (UI-Agent):** Plattenerkennung = `ModelStore.sheetIsPlate` (eigene Heuristik entfernt), Schalter
   „Ebene Platte“ bleibt als Übersteuerung; Kandidaten nur der Haut der Grundfläche (REVIEW 38), Kanten der anderen Haut
   gehen immer als offen ans Modell; Antippen der Biegefläche bzw. ihrer Übergangskanten schaltet die Biegung (REVIEW 39).
