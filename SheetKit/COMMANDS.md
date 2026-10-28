# SheetKit – Befehlsreferenz (aus dem SolidCraft-Quelltext)

> **Hinweis (Prüf-Agent, 17:35):** Diese Datei ist die **handgeprüfte** Referenz (Parameter, Rückgabe-JSON, Dialogfelder,
> deutsche Beschriftung, Icons). Die von `cargo run --example commands` erzeugte Rohliste aller SolidCraft-Befehle steht
> unten im **Anhang A** – das Beispiel bitte künftig nach `COMMANDS-RAW.md` schreiben lassen, nicht über diese Datei.

Quelle (wörtlich geprüft): `crates/engine/src/cmd/sheet.rs` (Parameter, Rückgaben),
`crates/engine/src/params.rs` (Typen), `crates/engine/src/cmd/features.rs` (`add_feature`, `profiles`),
`crates/engine/src/schema/features.rs` (`FeatureResult`), `crates/doc/src/sheet.rs`/`document.rs` (Regeln,
Biegungen), `crates/ui-egui/src/dialogs_sheet.rs` (Dialoge), `crates/ui-egui/src/workspace.rs` (Ribbon),
`assets/locales/de.json` (+ `en.json` für die ID-Auflösung), `assets/icons/ui/design/svg/model/*.svg`.

Kennzeichnung: **[unklar]** = aus dem Quelltext nicht eindeutig; **[nicht übersetzt]** = SolidCraft hat in
`de.json` keinen deutschen Text (SolidCraft zeigt dann Englisch) – dort steht ein Vorschlag in Klammern.

---

## 0. Allgemeine Regeln (gelten für alle Befehle)

### 0.1 Aufruf über die C-ABI
`psk_execute(s, "<befehl>", "<params-json>")` → `{"ok":true,"result":<Rückgabe>}` oder `{"ok":false,"error":"…"}`.
Fehlertexte (engine/src/lib.rs, `#[error]`): Parameterfehler ``invalid parameters for `<befehl>`: <meldung>``,
unbekannter Befehl ``unknown command `<id>`…``, sonst die Meldung selbst (z. B. Auswertungsfehler eines Features).

### 0.2 Typen (params.rs)
| Typ im Dokument | JSON | Regel |
|---|---|---|
| **expr** | Zahl **oder** String | Zahl = mm bzw. Grad je nach Kontext (`8` → `"8"`); String = Ausdruck, z. B. `"20 mm"`, `"90 deg"`, `"Thickness * 2"`, `"180 deg - 122 deg"`. Leerer String gilt als *nicht angegeben*. Max. 4096 Zeichen, Zahl |x| < 1e9. |
| **point3** | `[x,y,z]` oder `{"x":…,"y":…,"z":…}` | nur Zahlen (keine Ausdrücke), Welt-Koordinaten in mm |
| **point2** | `[x,y]` oder `{"x":…,"y":…}` | Skizzen-Koordinaten |
| **bool** | `true`/`false` | |
| **str** | String | |
| **string_list** | `["a","b"]` oder ein einzelner String `"a"` | |
| **sketch** | Zahl (Feature-ID) **oder** String (Skizzenname) | z. B. `5` oder `"Base"` |

Unbekannte Schlüssel auf oberster Ebene werden von den sheet-Befehlen **nicht** abgelehnt (nur in `then[]` und
in Objekt-Einträgen von `edges` gibt es eine Schlüsselprüfung). Ob der Sitzungs-Dispatcher allgemein unbekannte
Parameter prüft („parameter-check mode“, `param_warnings`), ist **[unklar]**.

### 0.3 Rückgabe aller Feature-Befehle (`FeatureResult`)
`sheet.flange`, `sheet.path_flange`, `sheet.perforate`, `sheet.hem`, `sheet.fold`, `sheet.unfold`,
`sheet.refold`, `sheet.convert` geben zurück:
```json
{"feature": 7, "name": "Flange1", "bodies": ["Body1"], "created_bodies": [], "changed_bodies": ["Body1"],
 "removed_bodies": [], "warning": null, "ms": 3.2}
```
| Feld | Typ | Bedeutung |
|---|---|---|
| `feature` | u64 | ID des neuen Features |
| `name` | String | Name des Features |
| `bodies` | [String] | alle Körper danach |
| `created_bodies` | [String] | vom Feature erzeugte Körper |
| `changed_bodies` | [String] | vorhandene, geometrisch geänderte Körper |
| `removed_bodies` | [String] | verschwundene Körper |
| `warning` | String \| null | Warnung (z. B. Entlastung ausgelassen, Ecke offen) – **in der UI anzeigen** |
| `ms` | f64 \| null | Rechenzeit |
| `param_warnings` | [String] | nur vorhanden, wenn nicht leer |

Gemeinsame optionale Parameter aller Feature-Befehle (aus `add_feature`): `name` (str, Feature-Name),
`body_name` (str, Name des neuen Körpers), `body_names` ([str]). Ein Auswertungsfehler des Features lässt den
Befehl fehlschlagen (`ok:false`). `Session::execute` stellt bei **jedem** Fehler das Dokument, die aktive Skizze
und die Sichtbarkeit wieder her („A failed command leaves the design as it was“) – kein eigener Rollback nötig.
Erfolgreiche Befehle mit Undo legen einen Undo-Schritt an (`flat_pattern`, `export_*`, `rules` nicht).

### 0.4 Wie Kanten und Flächen gewählt werden
* **Kante** = ein Punkt `[x,y,z]` (Welt, mm) **auf** der Kante – SolidCraft nimmt in der Oberfläche den
  Pickpunkt der Kante (`edge_points()`), sinnvoll ist die Kantenmitte (`psk.edges` → `mid`).
  - `sheet.flange` (Kantenflansch): Punkte auf **Ober- oder Unterkanten** des Blechs (Kante zwischen großer
    Blechfläche und Stirnfläche), oder auf der fernen Kante eines Flansches (Rückkantung/„return“), oder auf
    einer geraden Seitenkante eines Flansches.
  - `sheet.hem`: Punkte auf Blechkanten.
  - `sheet.path_flange` `edge`: ein Punkt auf einer Ober-/Unterkante.
  - `sheet.convert` `bends`: Punkte auf **scharfen Kanten** des Volumenkörpers (oder Mitte einer Fase, oder
    irgendwo auf einer modellierten Biegezylinderfläche).
* **Fläche** = ein Punkt `[x,y,z]` auf der Fläche (`sheet.convert` `face`, `sheet.fold` `fixed`) oder bei
  `sheet.convert` der Flächenname aus `model.faces` (z. B. `"F1:+z"` oder `"sheet:Body1:F3.1:top"`).
* **Körper** = Name (String) in `body`. Fehlt `body`, nehmen die sheet-Befehle den **letzten** Blechkörper.

### 0.5 Regeln (Dicke, K-Faktor, Radius)
Dicke, K-Faktor, Biegeradius usw. kommen **immer aus der Blechregel**. An `sheet.flange` übergeben werden sie
abgelehnt (`thickness`, `k_factor`, `bend_radius`, `relief_width`, `relief_depth`, `hem_gap`, sowie
`corner_relief`/`corner_relief_shape` außer beim Kantenflansch). Ohne eigene Regel gilt die Standardregel
`"Steel (mm)"` (siehe `sheet.manage_rules`).

---

## 1. `sheet.flange` – Flansch

Icon: `flange` (`assets/icons/ui/design/svg/model/flange.svg`) · de: **Flansch** (`cmd.sheet_flange`) ·
Ribbon: Tab SHEET METAL, Gruppe CREATE (de: ERSTELLEN) · Dialogtitel `FLANGE` [nicht übersetzt] (FLANSCH).

Drei Arten über `type` (`"base"|"edge"|"contour"`, Groß-/Kleinschreibung egal). Ohne `type`: `edges` vorhanden →
`edge`; sonst `curves` vorhanden → `contour`; sonst `base`.

### 1a. Grundflansch (`type: "base"`)
| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `sketch` | sketch | aktive Skizze, sonst letzte Skizze | geschlossenes Profil |
| `profiles` | `"all"` \| Zahl \| `[Zahlen]` \| `[{"point":[x,y]}]` \| `[{"curves":[ids]}]` \| `[[ids]]` | `all` | welche Profile der Skizze |
| `rule` | str | aktive Regel | Name einer Regel (muss existieren oder `"Steel (mm)"` sein) |
| `flip` | bool | false | Dicke wächst **gegen** die Skizzennormale (`document.rs`: „Thickness grows against the sketch normal“) |
| `name`, `body_name` | str | – | siehe 0.3 |

Abgelehnt: alle Regelwerte (0.5), `then`. Mehrere getrennte Profile ergeben **mehrere Körper** (`body_name`,
`body_name (2)`, …).
```json
{"type":"base","sketch":"Base","profiles":"all","flip":false}
```
SolidCraft-Test-Ablauf: `sketch.create {"plane":"XY","name":"Base"}` → `sketch.rectangle.two_point {"p0":[0,0],"p1":[100,60]}`
→ `sketch.finish {}` → `sheet.flange {"sketch":"Base"}`.

### 1b. Konturflansch (`type: "contour"`)
| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `sketch` | sketch | **Pflicht** (kein Rückfall auf aktive Skizze) | Skizze mit offener Linienkette |
| `curves` | string_list | **Pflicht**, 1…1000 | Kurven-IDs der offenen Kette (nur Linien) |
| `distance` | expr (Länge) | **Pflicht** | Breite entlang der Skizzennormalen |
| `rule` | str | aktive Regel | |
| `flip` | bool | false | Material auf der anderen Seite der Kette |
| `reverse` | bool | false | Breite in die andere Richtung der Skizzennormalen |
```json
{"type":"contour","sketch":"Profile","curves":["l1","l2","l3"],"distance":"40 mm","flip":false,"reverse":false}
```

### 1c. Kantenflansch (`type: "edge"`)
Braucht einen vorhandenen Blechkörper (sonst Fehler „there is no sheet metal body …“).
| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `edges` | Liste (1…1000) aus point3 **oder** `{"point":point3, "angle"?:expr, "height"?:expr}` | **Pflicht** | Kanten; Objekt-Eintrag = eigener Winkel/eigene Höhe für diese Kante. Andere Schlüssel im Objekt → Fehler. |
| `height` | expr (Länge) | **Pflicht** | Flanschhöhe bis zur fernen Kante |
| `angle` | expr (Winkel) | `"90 deg"` | Biegewinkel (immer Biegewinkel, nie Innenwinkel) |
| `radius` | expr (Länge) | Regel (`bend_radius`) | innerer Biegeradius |
| `position` | `"inside"\|"outside"\|"bend_outside"\|"middle"\|"material_outside"\|"tangent"` | `"inside"` | wo die Biegung beginnt; `bend_outside` wird als `outside` gespeichert |
| `height_from` | `"outer"\|"inner"\|"tangent"` \| null | `"outer"` (wird nicht gespeichert) | Bezug der Höhe |
| `flip` | bool | false | Flansch zur anderen Seite biegen |
| `body` | str | letzter Blechkörper | |
| `corner_relief_shape` | `"notch"\|"round"\|"rectangular"\|"tear"` \| null | Regel | Eckentlastung zwischen Flanschen **dieses** Features |
| `corner_relief` | expr (Länge) | Regel | Größe der Eckentlastung (quer) |
| `then` | `[{"angle"?:expr, "height":expr, "flip"?:bool}]`, max. 16 | – | weitere Biegungen, jede an der fernen Kante der vorigen; `angle` Standard `"90 deg"`; `flip` fehlt → Flip des Flansches; andere Schlüssel → Fehler. Jede weitere Biegung wird ein **eigenes Feature** (Rückgabe = `FeatureResult` des **letzten**). |
| `rule` | – | – | wird bei edge ignoriert (Dialog sendet ihn nicht) |

```json
{"type":"edge","edges":[[60,0,2],{"point":[120,45,2],"angle":"105 deg","height":"30 mm"}],
 "height":20,"angle":"90 deg","position":"inside","flip":false,
 "corner_relief_shape":"round","corner_relief":"6 mm","then":[{"angle":"45 deg","height":80,"flip":true}]}
```

### 1d. Dialog „Flansch“ (dialogs_sheet.rs `Sm::Flange`)
Auswahlfeld: **„Profile / Edges“** → de **Profil / Kanten** (Profile, Kanten oder Skizzenkurven, mehrfach). Der
Typ ergibt sich aus der Auswahl: eine Kante → Kante (1), eine Skizzenkurve → Kontur (2), sonst Grund (0).

| Zeile (en, wörtlich) | de | Art | Typ | Param / Standard |
|---|---|---|---|---|
| Type | Typ | Anzeige „Base“/„Edge“/„Contour“ [nicht übersetzt] (Grund/Kante/Kontur) | alle | – |
| Height | Höhe | Ausdruck | Kante | `height`, Standard Länge „10“ (`length_default(…,"10")`) |
| Angle | Winkel | Ausdruck | Kante | `angle`, `"90 deg"` |
| Bend Position | Biegeposition | Auswahl: Inside / Outside / Middle / Material Outside / Tangent to Edge → de Innen / Außen / Middle [nicht übersetzt] (Mitte) / Material außen / Tangential an Kante | Kante | `position` = `inside/outside/middle/material_outside/tangent` |
| Height From | Höhe ab | Auswahl: Outer Sharp / Inner Sharp / Tangent → de Außenkante / Innenkante / Tangential | Kante | `height_from` (nur gesendet, wenn ≠ outer) |
| Further Bends | Weitere Biegungen | Knopf „Add bend“ (Biegung hinzufügen), Tooltip „Another bend on the far edge of the last flange“ (Eine weitere Biegung an der gegenüberliegenden Kante des letzten Flansches); neue Zeile `("45 deg","20 mm",false)`, max. 16 | Kante | `then` |
| Bend N (N = 2…) | „Bend N“ [nicht übersetzt] (Biegung N) | Kopfzeile mit Papierkorb (Tooltip „Remove this bend“ = Diese Biegung entfernen) und Text „Winkel · Höhe“ | Kante | – |
| Bend N angle / Bend N height | [nicht übersetzt] | Ausdrücke | Kante | `then[i].angle`, `then[i].height` (leere Höhe → Fehler „bend N needs a height“) |
| Bend N turns | [nicht übersetzt] | Auswahl Same way / Other way → Gleiche Richtung / Entgegengesetzte Richtung | Kante | „Other way“ → `then[i].flip = !flip`; „Same way“ → kein `flip` |
| Abschnitt **Advanced** (Erweitert), zugeklappt | | | Kante | |
| · Bend Radius | Biegeradius | Ausdruck mit Platzhalter „from the rule“ (aus der Regel) | Kante | `radius` (nur wenn nicht leer) |
| · Corner Relief Shape | Form der Eckenentlastung | Auswahl Rule / Notch / Round / Rectangular / Tear → Rule [so in de.json] / Ausklinkung / Rund / Rechteckig / Reißen | Kante | Index 0 = nichts senden, sonst `corner_relief_shape` |
| · Corner Relief | Eckenentlastung | Ausdruck, Platzhalter „aus der Regel“ | Kante | `corner_relief` |
| · Per Edge | Pro Kante | Hinweis „angle, height“ (Winkel, Höhe); nur wenn >1 Kante gewählt | Kante | – |
| · Edge N | „Edge N“ [nicht übersetzt] (Kante N) | zwei Felder nebeneinander (Winkel, Höhe), Platzhalter = Werte oben | Kante | `edges[i] = {"point", "angle"?, "height"?}` |
| Distance | Abstand | Ausdruck, Standard Länge „20“ | Kontur | `distance` |
| Rule | Rule [de.json: „Rule“] | Auswahl „(active rule)“ [nicht übersetzt] + Regelnamen | Grund, Kontur | `rule` (Index 0 → nicht senden) |
| Optionen: Flip | Umkehren | Häkchen | alle | `flip` |
| Optionen: Other side | Andere Seite | Häkchen | nur Kontur | `reverse` |

Wert im Ansichtsfenster (Ziehgriff, `primary`): Kante → „Height“, Kontur → „Distance“.
Gesendete Parameter genau:
- Grund: `{"type":"base","sketch":<id>,"profiles":[idx…],"flip":…,"rule"?}`
- Kontur: `{"type":"contour","sketch":<id>,"curves":[…],"distance":…,"reverse":…,"flip":…,"rule"?}`
- Kante: `{"type":"edge","edges":[…],"height":…,"angle":…,"position":…,"radius"?,"height_from"?,"corner_relief_shape"?,"corner_relief"?,"then"?,"flip":…}` (+ `body` beim Bearbeiten).

---

## 2. `sheet.path_flange` – Pfadflansch

Icon: `path_flange` · de: **„Path Flange“ [nicht übersetzt]** (Pfadflansch; Ribbon-Kurzname „Path“ → **Pfad**) ·
Ribbon CREATE · Dialogtitel `PATH FLANGE` [nicht übersetzt].

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `edge` | point3 | **Pflicht** | Punkt auf Ober-/Unterkante |
| `sketch` | sketch | **Pflicht** | Skizze auf einer Ebene quer zur Kante |
| `curves` | string_list | **Pflicht**, 1…64 (`MAX_PATH_LINES`) | offene Linienkette ab der Kante; jede Linie = ein Flansch so lang wie die Linie, jede Ecke = eine Biegung. Nur Linien (keine Bögen). |
| `radius` | expr (Länge) | Regel | |
| `body` | str | letzter Blechkörper | |
```json
{"edge":[1,0,20],"sketch":"Path","curves":["p1","p2"]}
```
Dialog: Auswahl **„Edge“** [nicht übersetzt] (Kante; Kanten, einfach) und **„Path“** → **Pfad** (Kurven, mehrfach; ein
Klick nimmt die ganze verbundene Kette, sortiert ab dem Ende nahe der Kante). Zeilen: **Flanges** → **Flansche**
(Anzeige der Linienlängen „a · b mm“ bzw. „pick the path“ [nicht übersetzt]), Untertitel „set by the sketch's lines“
[nicht übersetzt], **Bend Radius** → **Biegeradius** (Platzhalter „aus der Regel“). Gesendet:
`{"edge":…,"sketch":…,"curves":[…],"radius"?}`.

---

## 3. `sheet.perforate` – Perforieren

Icon: `perforate` · de: **Perforieren** · Ribbon CREATE · Dialogtitel `ui.perforate_title` = „PERFORATE“ (nur en).

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `diameter` | expr (Länge) | **Pflicht** | Lochdurchmesser |
| `pitch` | expr (Länge) | **Pflicht** | Teilung |
| `margin` | expr (Länge) | = Durchmesser | Abstand zu Rändern, Ausschnitten, Biegungen |
| `pattern` | `"staggered"\|"square"` | `"staggered"` (60°) | |
| `body` | str | letzter Blechkörper | |
Löcher erscheinen nur im Flachmuster (`perforations`), im DXF (Layer PERFORATION) und im Volumen, **nicht** im B-Rep.
```json
{"diameter":"3 mm","pitch":"6 mm","pattern":"staggered"}
```
Dialog: Auswahl **„Body (last if none)“** → **Körper (letzter, wenn keiner)** (Körper oder Fläche). Zeilen:
`ui.diameter` → **Durchmesser** (Standard `"3 mm"`), `ui.perforate_pitch` → „Pitch“ [nur en] (Teilung),
**Margin** → **Rand** (Platzhalter `ui.perforate_margin_default` „from the diameter“ [nur en]),
**Pattern** → **Muster**: „Staggered (60°)“ [nur en] (Versetzt (60°)) / „Square“ (`ui.perforate_square`, nur en;
Quadratisch). Standard `pitch` `"6 mm"`.

---

## 4. `sheet.hem` – Umkantung (Saum)

Icon: `hem` · de: **Umkantung** · Ribbon CREATE · Dialogtitel `HEM` [nicht übersetzt].

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `edges` | Liste point3 (auch `{"point":…}`), 1…1000 | **Pflicht** | Blechkanten |
| `length` | expr (Länge) | **Pflicht** | bis zur Außenfläche |
| `gap` | expr (Länge) | Regel (`hem_gap`, Standard `0.01 mm`) | Innenradius/Spalt |
| `flip` | bool | false | zur anderen Seite |
| `body` | str | letzter Blechkörper | |
```json
{"edges":[[50,0,2.5]],"length":"5 mm","flip":false}
```
Dialog: Auswahl **„Edges“** → **Kanten** (mehrfach). Zeilen: **Type** → **Typ** mit Anzeige „Flat“ → **Flach**;
**Length** → **Länge** (Standard `"5 mm"`, Ziehgriff); `ui.sheet_gap` → **Spalt** (Platzhalter „aus der Regel“);
Option **Flip** → **Umkehren**. Gesendet: `{"edges":[…],"gap"?,"length":…,"flip":…}`.

---

## 5. `sheet.fold` – Falten

Icon: `fold` · de: **Falten** · Ribbon CREATE · Dialogtitel `FOLD` [nicht übersetzt].

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `points` | `[point3, point3]` | – | Biegelinie als zwei Punkte (Alternative zu sketch+curve) |
| `sketch` + `curve` | sketch + str | – | eine Skizzen**linie** auf der Grundfläche des Blechs (folgt Skizzenänderungen) |
| `angle` | expr (Winkel) | `"90 deg"` | |
| `radius` | expr (Länge) | Regel | |
| `position` | `"centerline"\|"start"\|"end"\|"mould"` (`"mold"` auch) | `"centerline"` | Lage der Linie in der Biegung |
| `fixed` | point3 | größere Seite | Punkt auf der Fläche der Seite, die stehen bleibt (muss auf dem Blech liegen, sonst Fehler) |
| `flip` | bool | false | andersherum falten |
| `body` | str | letzter Blechkörper | |
```json
{"sketch":"FoldLine","curve":"l1","angle":"90 deg","position":"centerline","flip":false,"fixed":[20,30,2.5]}
{"points":[[50,0,2.5],[50,60,2.5]],"angle":90}
```
Dialog: Auswahlen **„Bend Line“** [nicht übersetzt] (Biegelinie; Achsen/Skizzenlinien, einfach) und
**„Stationary Side“** [nicht übersetzt] (Feste Seite; ebene Fläche, einfach). Zeilen:
**Bend Line Position** → **Position der Biegelinie**: „Centerline“ → **Mittellinie**, „Start of Bend“,
„End of Bend“, „Outside Mould Line“ [alle drei nicht übersetzt] (Biegungsanfang, Biegungsende, Außenformlinie);
**Angle** → **Winkel** (Standard `"90 deg"`, Ziehgriff); **Bend Radius** → **Biegeradius** (Platzhalter „aus der Regel“);
Option **Flip** → **Umkehren**. Gesendet: `{"sketch","curve","radius"?,"fixed"?,"angle","position","flip"}`.

---

## 6. `sheet.unfold` / `sheet.refold` – Entfalten / Wieder falten

Icons: `unfold`, `refold` · de: **Entfalten**, **Wieder falten** · Ribbon Gruppe FLAT (de: ABWICKLUNG) ·
Dialogtitel `UNFOLD` / `REFOLD` [nicht übersetzt].

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `body` | str | unfold: letzter Blechkörper; refold: letzter entfaltete Blechkörper | alle Biegungen |
```json
{"body":"Body1"}
```
Rückgabe: FeatureResult (Feature `SheetUnfold{refold}` im Verlauf). Dialog: Auswahl **„Body (last if none)“** →
**Körper (letzter, wenn keiner)**, keine weiteren Zeilen.

---

## 7. `sheet.convert` – In Blech umwandeln

Icon: `convert_sheet` · de: **In Blech umwandeln** · Ribbon CREATE (SolidCraft zusätzlich MODEL → MODIFY) ·
Dialogtitel `CONVERT TO SHEET METAL` [nicht übersetzt].

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `body` | str | **Pflicht** | vorhandener Körper |
| `face` | point3 **oder** Flächenname (str, aus `model.faces`) | **Pflicht** | die große ebene (feste) Fläche |
| `bends` | Liste point3 (1…1000) \| null | – | scharfe Kanten, die Biegungen werden (Volumen- oder Schalenkörper). Ohne: Platte gleicher Dicke. |
| `rule` | str | aktive Regel | |
Mit `bends` werden Regelwerte als Parameter abgelehnt.

**Offene Kanten (Wunsch „welche Kante offen ist“):** laut SolidCraft gilt: *„edges between two of those faces
that are no bends are cut open with the rule's gap“* – jede Kante zwischen zwei Blechflächen, die **nicht** in
`bends` steht, wird mit dem Spalt der Regel (`gap`) aufgeschnitten. Die Wahl „offen / Biegung“ je Kante ist
also genau die Liste `bends`: Biegung = Punkt in `bends`, offen = nicht in `bends`. Einen eigenen Parameter
„offene Kanten“ gibt es nicht; der Spalt gilt für alle offenen Kanten gleich (Regel).
```json
{"body":"Tray","face":[50,30,0],"bends":[[50,0,0],[100,30,0],[50,60,0],[0,30,0]],"rule":"Sheet 2 mm"}
{"body":"Plate","face":[50,30,2.5]}
```
Dialog: Auswahlen **„Fixed Face“** → **Feste Fläche** (ebene Fläche, einfach) und **„Bend Edges“** → **Biegekanten**
(Kanten, mehrfach). Zeile **Rule** (Auswahl „(active rule)“ + Regeln). Gesendet:
`{"body","face":[…],"bends"?,"rule"?}`.

---

## 8. `sheet.manage_rules` – Blechregeln

Icon: `sheet_rules` · de: **Blechregeln** (Ribbon-Kurzname „Sheet Rules“ → Blechregeln) · Ribbon Gruppe RULES
(de: REGELN) · Dialogtitel `SHEET METAL RULES` [nicht übersetzt].

| Param | Typ | Standard (neue Regel = Kopie der aktiven bzw. Steel) | Bedeutung |
|---|---|---|---|
| `name` | str (getrimmt, 1…128) | **Pflicht** | neue oder vorhandene Regel |
| `thickness` | expr (Länge) | Steel: `"2.5 mm"` | Blechdicke (> 0) |
| `k_factor` | expr (einheitenlos, 0…1) | `"0.44"` | |
| `bend_radius` | expr (Länge ≥ 0) | `"Thickness"` | |
| `relief_width` | expr | `"Thickness"` | Biegefreistich-Breite |
| `relief_depth` | expr | `"Thickness * 0.5"` | Biegefreistich-Tiefe |
| `corner_relief` | expr | `"Thickness * 4.0"` | Größe Eckentlastung |
| `hem_gap` | expr | `"0.01 mm"` | |
| `gap` | expr | `"Thickness"` | Spalt zwischen Flanschen an Ecken (und offene Kanten bei convert) |
| `corner_relief_shape` | `"notch"\|"round"\|"rectangular"\|"tear"` | `"notch"` | |
| `angle_display` | `"bend"\|"included"` | `"bend"` | Winkel in den DXF-Biegenotizen |
| `active` | bool | true, wenn noch keine Regel aktiv ist | als aktive Regel setzen |
| `delete` | bool | false | Regel löschen |
In Ausdrücken heißt die Dicke der Regel `Thickness`.

Rückgabe (anlegen/ändern):
```json
{"rule":{"name":"Sheet 2 mm","thickness":"2 mm","k_factor":"0.5","bend_radius":"1 mm","relief_width":"Thickness",
  "relief_depth":"Thickness * 0.5","corner_relief":"Thickness * 4.0","corner_relief_shape":"notch","hem_gap":"0.01 mm",
  "gap":"Thickness","angle_display":"bend"},
 "values":{"thickness":2.0,"k_factor":0.5,"bend_radius":1.0,"relief_width":2.0,"relief_depth":1.0,"corner_relief":8.0,
  "corner_relief_shape":"notch","hem_gap":0.01,"gap":2.0,"angle_display":"bend"},
 "errors":[{"feature":"Flange1","error":"…"}]}
```
Rückgabe (löschen): `{"deleted":"<name>"}`. `errors` = Features, die nach der Änderung nicht mehr rechnen.
Hinweis: `k_factor` als Zahl `0.5` übergeben wird als Ausdruck `"0.5"` gespeichert.
```json
{"name":"Sheet 2 mm","thickness":"2 mm","k_factor":0.5,"bend_radius":"1 mm","corner_relief_shape":"round","corner_relief":"8 mm","active":true}
```
Dialog (`Sm::Rules`, Makro `rule_editor`): **Rule** (Auswahl der Regeln + „New rule…“ → **Neue Regel…**); bei neuer
Regel **Name** → **Name** (Vorschlag „Rule<n+1>“); dann je Feld:
**Thickness** → **Dicke**, **K Factor** [nicht übersetzt] (K-Faktor), **Bend Radius** → **Biegeradius**,
**Relief Width** [nicht übersetzt] (Freistichbreite), **Relief Depth** [nicht übersetzt] (Freistichtiefe),
**Corner Relief Shape** → **Form der Eckenentlastung** (Notch/Round/Rectangular/Tear → Ausklinkung/Rund/Rechteckig/Reißen;
steht direkt vor Corner Relief), **Corner Relief** → **Eckenentlastung**, **Hem Gap** [nicht übersetzt] (Saumspalt),
**Flange Gap** [nicht übersetzt] (Flanschspalt; Parameter `gap`), **Angle Display** → **Winkelanzeige** (Bend/Included →
Biegung/Enthalten), **Active rule** → **Aktive Regel** (Häkchen). Knopf **Delete rule** → **Regel löschen** (nur bei
vorhandener Regel, sendet `{"name":n,"delete":true}`). Leere Felder werden nicht gesendet; Namen leer → Fehler
„give the rule a name“. OK sendet `{"name","active", <nicht leere Felder>, "corner_relief_shape", "angle_display"}`.

## 9. `sheet.rules` – Blechregeln auflisten (kein Undo, nur Dokument)

Icon: `sheet_rules` · de: **Blechregeln auflisten**. Keine Parameter.
```json
{"rules":[{"rule":{"name":"…","thickness":"…"},"values":{"thickness":2.5}}],"active":"Steel (mm)"}
```
Ohne eigene Regeln enthält `rules` die Standardregel „Steel (mm)“. `values` ist `null`, wenn die Regel nicht
auswertbar ist.

---

## 10. `sheet.flat_pattern` – Flachmuster erstellen (kein Undo)

Icon: `flat` · de: **Flachmuster erstellen** (Ribbon-Kurzname „Flat Pattern“ → **Flachmuster**) · Ribbon FLAT ·
Dialogtitel `FLAT PATTERN` [nicht übersetzt].

Param: `body` (str, Standard letzter Blechkörper). Fehler, wenn der Körper Änderungen trägt, die das Blech nicht
kennt (`flat_matches_body`).

Rückgabe (`flat_json`, Feldnamen exakt):
```
{
 "body": "Body1",
 "rule": "Steel (mm)",
 "thickness": 2.5,
 "k_factor": 0.44,
 "flat_size_mm": [w, h, t],
 "outline": [ [[x,y],[x,y],…], … ],
 "cutouts": [ [[x,y],…], … ],
 "cutout_shapes": [ {"circle":{"center":[x,y],"radius":r}} |
                    {"segments":[ {"line":[[x,y],[x,y]]} |
                                  {"arc":{"center":[x,y],"radius":r,"start_deg":a,"sweep_deg":s}} |
                                  {"polyline":[[x,y],…]} ]} , … ],
 "pockets": [ {"outline":[[x,y],…], "cutouts":[[[x,y],…],…], "cutout_shapes":[…wie oben…],
               "side":"bottom"|"top"|"internal", "depth_mm":d, "z0_mm":z0, "z1_mm":z1} ],
 "bends": [ {"bend":1, "angle_deg":90.0, "included_angle_deg":90.0, "radius":2.5, "direction":"up"|"down",
             "allowance":a, "length":l, "start":[x,y], "end":[x,y]} ],
 "unfolded": false,
 "perforations": [ {"feature":id, "diameter":d, "pitch":p, "margin":m, "pattern":"square"|"staggered",
                    "count":n, "open_area_mm2":A} ],
 "bend_zones": [ [xmin, xmax, ymin, ymax], … ],
 "bores": [ {"start":[x,y,z], "axis":[x,y,z], "diameter":d, "length":l} ]
}
```
Einzelheiten:
- `outline`: **Liste von Schleifen** (eine je Materialstück), jede eine Punktliste `[x,y]` (Toleranz 0,001 mm),
  **nicht geschlossen** (letzter Punkt ≠ erster; `Loop2::polyline` lässt den Endpunkt jedes Segments weg).
- `cutouts`: alle Löcher aller Stücke als Punktlisten; `cutout_shapes`: dieselben Löcher **in derselben
  Reihenfolge** exakt. Ein Kreis kommt als `circle`, sonst `segments` (Linie, Kreisbogen mit `start_deg`/`sweep_deg`
  in Grad, vorzeichenbehaftet; sonstige Kurven als `polyline`).
- Für `outline` gibt es **kein** `outline_shapes` – nur Punktlisten.
- `bends`: eine Zeile je Biegungsstück; `bend` ist die 1-basierte Nummer der Biegung (bei durch Ausschnitte
  geteilten Biegungen **mehrere Zeilen mit derselben Nummer** – nicht als eindeutige ID verwenden).
  `start`/`end` = Biegemittellinie in Flachkoordinaten. `angle_deg` = Biegewinkel (Betrag),
  `included_angle_deg` = 180 − angle_deg, `direction` = `"up"` bei Winkel ≥ 0.
- `flat_size_mm` = Breite/Höhe der Bounding-Box aller `outline`-Schleifen + Dicke.
- `unfolded` = ob der Körper gerade entfaltet ist.
- `bend_zones`: je Biegung (je Flansch) die Box der Biegezone `[xmin, xmax, ymin, ymax]` (Reihenfolge so!).
- `bores` **nur vorhanden, wenn nicht leer**.
- Es gibt **kein** Feld `bend_table` – die Biegetabelle ist `bends` (bzw. `sheet.export_bend_table`).

Dialog „Flachmuster“ (`Sm::FlatPattern`, keine Vorschau): Auswahl **„Body (last if none)“** → **Körper (letzter, wenn keiner)**.
Panel-Zeilen: **Body** → **Körper** (`body`); **Flat size** → **Abwicklungsgröße** („w × h × t“, 1 Nachkommastelle);
**Bends** → **Biegungen** (Anzahl); je Biegung (max. 50) Zeile „  Bend N“ mit „Up/Down 90.0°  R2.5“ in Biegefarbe
(Up/Down [nicht übersetzt]: Auf/Ab); Knöpfe **Export DXF…** → **DXF exportieren…** und **Export Bend Table…** →
**Biegetabelle exportieren…** (Sichern-Dialog, Dateiname `<Dokument>-<Körper>.dxf|csv`, dann
`sheet.export_dxf`/`sheet.export_bend_table` mit `{"body","path"}`); Statuszeile („Saved <path>“, „Export cancelled“,
„Choose an export file…“ – [nicht übersetzt]). Fehler in Fehlerfarbe.
Ansicht (`overlay`): 2D-Draufsicht ersetzt das Ansichtsfenster, Hintergrund Panelfarbe; `outline` als geschlossene
Linien (Strich 1,8, Textfarbe); `cutouts` (1,4); Perforationslöcher als Kreise (1,4, nur wenn ≥ 1 px);
Taschen (`pockets`) gestrichelt in Akzentfarbe (3/3) mit Tiefenbeschriftung oben mittig; Biegelinien gestrichelt
(8/5, Strich 1,6) in Farbe `bend_up` bzw. `bend_down` (Theme); Legende oben links: „FLAT PATTERN“, „Bend up“,
„Bend down“, ggf. „Pocket boundary (material remains)“ [alle nicht übersetzt]. Ohne Daten: Text
„no sheet metal body“. Navigation: Pan/Zoom ohne Orbit, Einpassen beim Öffnen.

---

## 11. `sheet.export_dxf` – Flachmuster als DXF exportieren (kein Undo)

Icon: `dxf` · de: **Flachmuster als DXF exportieren** (Ribbon-Kurzname „Export DXF“ → **DXF exportieren**) ·
Ribbon OUTPUT (de: AUSGABE). Ribbon-Klick öffnet direkt den Sichern-Dialog für den letzten Blechkörper.

| Param | Typ | Standard | Bedeutung |
|---|---|---|---|
| `body` | str | letzter Blechkörper | nicht zusammen mit `per_body` |
| `path` | str | – | Datei schreiben; ohne → DXF-Text in der Antwort |
| `curves` | `"exact"\|"arcs"` | `exact` | |
| `text` | `"cut"\|"etch"` | `cut` | |
| `bend_notes` | bool | false | Notizen `B1 UP 90%%d R1` auf BEND_NOTES |
| `note_height` | Zahl 0.1…100 (mm) | 3 | |
| `bend_lines` | bool | true | false = BEND_UP/BEND_DOWN weglassen |
| `layers` | `"roles"\|"single"` | `roles` | single = alles auf Layer 0 |
| `per_body` | bool | false | je Blechkörper eine Datei `<path>-<body>.dxf` |
Rückgabe: mit `path` `{"path":"…","bends":n}`; ohne `{"dxf":"<DXF-Text>","bends":n}`; mit `per_body`
`{"files":[{"body","path","bends"} | {"body","dxf","bends"}]}`. `bends` = Anzahl Biegungsstücke.
Layer: OUTLINE (7), CUT (4), TEXT (2), ETCH (6), BEND_UP (1, gestrichelt), BEND_DOWN (5, gestrichelt), BEND_NOTES (8),
POCKET_<BOTTOM|TOP|INTERNAL>_Z…_TO_…_MM (3), PERFORATION (3). Pfad wird über `solidcraft_io::vfs::write`
(nativ `std::fs::write`) geschrieben – auf iOS ein beschreibbarer Pfad (tmp) nötig.
```json
{"body":"Body1","bend_notes":true,"text":"cut","curves":"exact"}
```

## 12. `sheet.export_bend_table` – Biegungstabelle exportieren (kein Undo)

Icon: `bendtable` · de: **Biegungstabelle exportieren** (Ribbon-Kurzname „Bend Table“ → **Biegetabelle**) · Ribbon OUTPUT.

| Param | Typ | Standard |
|---|---|---|
| `body` | str | letzter Blechkörper |
| `format` | `"csv"\|"json"` | `csv` |
| `path` | str | – (ohne: Text in Antwort) |
Rückgabe: `{"path","format","bends"}` bzw. `{"format","text","bends"}`. Bei `json` ist `text` das komplette
`sheet.flat_pattern`-JSON (pretty). CSV-Kopf exakt (CRLF, Textfelder immer in `"`):
```
body,rule,thickness_mm,k_factor,bend,angle_deg,direction,radius_mm,allowance_mm,length_mm,start_x_mm,start_y_mm,end_x_mm,end_y_mm,included_angle_deg
```
Zahlen mit 9 Nachkommastellen.
```json
{"format":"csv"}
```

---

## 13. Hilfsbefehle

### `sketch.create` (Icon `sketch`)
| Param | Typ | Bedeutung |
|---|---|---|
| `plane` | `"XY"\|"XZ"\|"YZ"` \| Name/ID einer Konstruktionsebene \| `{"origin"?:[x,y,z], "x_dir":[…], "y_dir":[…]}` \| `{"face":[x,y,z], "body"?, "index"?, "fixed"?}` | Skizzenebene. **`face`, `origin`, `x_dir`, `y_dir` gehören in `plane`**, daneben → Fehler. Eine ebene Fläche eines Blechkörpers → Skizze hängt am Blech-Panel, **Koordinaten = Flachmuster-Koordinaten**. |
| `offset` | expr | Abstand entlang der Normalen |
| `flip` | bool \| `"x"` \| `"y"` | nicht bei `face` |
| `frame` | `"world"\|"component"` | |
| `project_edges` | bool | Flächenkanten projizieren |
| `name` | str | Skizzenname (für `sketch` in sheet-Befehlen) |
Rückgabe: `{"sketch":<id>,"name":"…","projected":…,"attachment":"exact_face"|"sheet_face"|"internal_legacy_face"|"fixed"}`
(+ ggf. `frame`/`note`). Die neue Skizze wird **aktiv**.

### `sketch.line` (Icon `line`)
`points`: `[[x,y] | "l1.end" | {at, ref} …]` (x/y Zahl oder Ausdruck), `closed?`, `construction?`, `ids?: [..]`
(eigene Kurven-IDs, z. B. `["p1","p2"]` für n−1 Linien), `infer?`, `connect?` (Standard true).
Rückgabe: `{"curves":[ids],"constraints":[…],"sketch":…,"created":{"points","curves","constraints","dimensions"}}`.
```json
{"points":[[0,0],[28.28,-28.28],[108.28,-28.28]],"ids":["p1","p2"]}
```

### Weitere Skizzenbefehle (Namen exakt)
- `sketch.rectangle.two_point` `{"p0":[x,y],"p1":[x,y]}` → zusätzlich `sides{bottom,right,top,left}`, `corners{…}` (Icon `rect`)
- `sketch.rectangle.center` `{"center","corner"}`; `sketch.rectangle.three_point` `{"p0","p1","p2"}`;
  `sketch.rectangle.rounded` `{"p0","p1","radius"}`
- `sketch.circle.center` `{"center":[x,y],"radius":r}` oder `"diameter"` (Icon `circle`); `sketch.circle.two_point` `{"p0","p1"}`;
  `sketch.circle.three_point` `{"p0","p1","p2"}`
- `sketch.arc.three_point` `{"start","end","through"}` (Icon `arc3`); `sketch.arc.center_point`
  `{"center","start","end"}` (gegen Uhrzeigersinn) oder `{"center","start","sweep":Grad}`
- `sketch.ellipse` `{"center","major":[x,y] (Ende der großen Achse),"minor":[x,y] | "minor_radius"}`
- `sketch.spline.fit_point` `{"points":[…] (2…500),"periodic"?}`; `sketch.spline.control_point` `{"points"}` (kubisch, 2…500)
- Es gibt **kein** `sketch.arc` / `sketch.circle` / `sketch.rect` ohne Zusatz.
- `sketch.finish` `{}` beendet die Skizze (Tests rufen es vor `sheet.flange` auf).

### `file.insert_step` (Icon `import`)
`path` (STEP/IGES/.FCStd/.3dm), `name?`, `up?: "z"|"y"`, `names?: auto|solid|product|instance`, `matrix?`, `tolerance?`.
Körper landen in einer **neuen Komponente**. Rückgabe (`add_step`): `{"path","feature","name","bodies":[…],
"created_bodies":[…],"warnings":[…],"system", "exporter"?, "exporter_up"?, "stand_up"?}` + Komponentenfelder
(`component`, `component_name`, `occurrence`, … über `placed.report`). Die Körpernamen kommen aus dem STEP, **nicht**
aus `name` (das ist Feature-/Komponentenname).

### `file.export` (Icon `export`)
`path`, `format?: stl|stla|obj|step|3mf|3mf-tagged|urdf|json` (Standard aus Endung), `bodies?: [names]`,
`quality?`. Rückgabe `{"path","bytes","format"}`. Für den exakten B-Rep eines Körpers nimmt der Vertrag `psk.export_step`.

### `model.edges` / `model.faces` (Abfrage, kein Undo)
`model.edges {"body"}` → `{"body","edges":[{"index","name","mid","length","start","end"}]}`.
`model.faces {"body"}` → je Fläche `index`, `name`, `exact`, `area`, `centroid`, `plane_normal`, `point`
(Punkt auf der Fläche), `cylinder?`, `sheet_face?` (`sheet:<body>:<panel>:<side>`).

---

## 14. Ribbon „Blech“ in SolidCraft (workspace.rs), Reihenfolge

| Gruppe (de) | Befehle |
|---|---|
| SKETCH (SKIZZE) | `sketch.create` |
| CREATE (ERSTELLEN) | `sheet.flange`, `sheet.path_flange`, `sheet.hem`, `sheet.fold`, `sheet.perforate`, `sheet.convert` |
| FLAT (ABWICKLUNG) | `sheet.unfold`, `sheet.refold`, `sheet.flat_pattern` |
| OUTPUT (AUSGABE) | `sheet.export_dxf`, `sheet.export_bend_table` |
| RULES (REGELN) | `sheet.manage_rules` |

Icons (alle unter `assets/icons/ui/design/svg/model/`): `flange.svg`, `path_flange.svg`, `perforate.svg`,
`hem.svg`, `fold.svg`, `unfold.svg`, `refold.svg`, `convert_sheet.svg`, `sheet_rules.svg`, `flat.svg`, `dxf.svg`,
`bendtable.svg`, Tab-Icon `sheet.svg`. (In PencilCAD als Asset `sc.<name>`.)

## 15. Deutsche Befehlsnamen (de.json `cmd.*`)
| Befehl | de |
|---|---|
| sheet.flange | Flansch |
| sheet.path_flange | — (nicht übersetzt; en „Path Flange“) |
| sheet.perforate | Perforieren |
| sheet.hem | Umkantung |
| sheet.fold | Falten |
| sheet.unfold | Entfalten |
| sheet.refold | Wieder falten |
| sheet.convert | In Blech umwandeln |
| sheet.manage_rules | Blechregeln |
| sheet.rules | Blechregeln auflisten |
| sheet.flat_pattern | Flachmuster erstellen |
| sheet.export_dxf | Flachmuster als DXF exportieren |
| sheet.export_bend_table | Biegungstabelle exportieren |

---

## Anhang A – Rohliste aller SolidCraft-Befehle (generiert mit `cargo run --example commands`)

### SolidCraft-Befehle für das Blechmodul

Automatisch erzeugt aus `solidcraft-engine` (Commit 98b57a3588170ec1a1c7acc91b4bf8a60ea29865) mit
`cargo run --example commands > COMMANDS.md` – nicht von Hand ändern.

Längen in mm, Winkel in Grad; Ausdrücke wie `"20 mm"`, `"45 deg"` oder `"W / 2"` sind erlaubt,
wo die Beschreibung `expr` nennt. Punkte `[x,y,z]` sind Weltkoordinaten. Zusätzlich gibt es die
`psk.*`-Befehle aus API.md.

#### `body.rename` – Rename Body

body: its name, name: the new name (features that use the body follow)

#### `file.export` – Export

path; format?: stl|stla|obj|step|3mf|3mf-tagged|urdf|json (default from extension; 3mf-tagged: 3MF whose triangles carry their B-rep face, at full precision, for meshing and analysis tools; docs/formats/3mf-face-tags.md; urdf: the whole assembly as a robot, with STL meshes written next to it; docs/urdf.md); bodies?: [names] (JSON and URDF export the complete design); urdf only: mesh_prefix? (before each mesh file name, e.g. package://robot/meshes/), effort? (default 1000), velocity? (default 10); quality?: standard|fine|finest (STL, OBJ and 3MF: how closely the mesh follows curved faces, a chord tolerance of 2e-4, 5e-5 or 1e-5 of each body's size; default standard)

#### `file.export_view_dxf` – Export Current View as DXF

camera: Camera (current view); hidden?: omit|dashed (default omit); tolerance?: 0.0001..1 mm (curve chord tolerance, default 0.01); path?: .dxf file (else returns dxf text). Visible placed bodies and shown sketches' profile curves (no construction geometry, points, dimensions or constraints); 2D LINE/LWPOLYLINE entities on VISIBLE/HIDDEN layers (sketch curves on SKETCH), mm; finished sketches are hidden behind bodies, the active sketch is drawn on top; perspective projected onto the camera target plane; no viewport crop or overlays.

#### `file.insert_step` – Insert STEP

path: STEP, IGES, FreeCAD .FCStd or Rhino .3dm file (its bodies join the design as an Import base feature in a new component named after the file, placed in the active component; an assembly's products become nested components, a repeated part one component with an occurrence per placement, all held as one rigid group until component.unlock → component, component_name, occurrence, subcomponents?, rigid_joints?); name? (the feature's and the component's); up?: z|y (default z: the file's axes are kept; y: the file has Y up, so the import's component is turned a quarter turn about X, Y becoming Z → stand_up: its occurrence); names?: auto|solid|product|instance (default auto: keep meaningful solid names, replace placeholders with the nearest named product, else instance; solid: the solid's own name; product: the part's name; instance: the occurrence's name, else the product's); matrix?: [12 or 16 numbers] (where the new component's occurrence sits in the active component, after `up`: a rigid row-major 3x4 rotation-and-translation or 4x4 matrix, flat or as rows, as occurrence.move takes it; a scale, shear or mirror is refused before the file is read); tolerance? (see occurrence.move)

#### `inspect.measure` – Measure

bodies?: [names] (default all) → closed per body; volume_mm3, center_of_mass, density_g_cm3 and mass_g only for closed, consistently oriented bodies; area, bbox and counts for all; total.open_bodies_skipped counts bodies excluded from volume/mass totals; or items: [1-2 selections] (face/edge: type, body, point; index optional) → length/area/volume; diameter, radius, circumference or arc_length/angle_deg of circles, arcs and cylinders; slot sizes; min (distance_mm, from, to), max, center_distance (centre to centre, or from an axis) and angle

#### `model.edges` – List Edges

body: name

#### `model.faces` – List Faces

body: name → per face: index, name (what face.delete, sheet.convert `face`, solid.shell … take in place of a point), exact, area, centroid (not always on the face), plane_normal, point (a point on the face that picks it), cylinder? ({origin, axis, radius} of a cylindrical face), sheet_face? (a folded sheet's face: `sheet:<body>:<panel>:<side>`, panel base or a flange's tag F<feature>.<k>, side top | bottom | rim.<edge> | bend.inner | bend.outer; taken wherever a face name is, and it holds while sizes change and flanges come and go)

#### `model.threads` – List Threads

(keine Parameter)

#### `sheet.convert` – Convert to Sheet Metal

body; face: [x,y,z] on its large flat face (a plate of even thickness; recesses in one face up to half the thickness deep, such as an engraved label, become pockets of the sheet), or that face's name from model.faces; rule?; bends?: [[x,y,z] on sharp edges] (a solid or a shelled body: `face` is the fixed face and the flat faces reached from it across these edges become the sheet; a shell keeps its thickness, a solid takes the rule's inward; edges between two of those faces that are no bends are cut open with the rule's gap; a point in the middle of a chamfer between two faces, or on a bend modelled with its radius (a cylinder between two flat faces tangent to it, either skin), makes it one bend of the rule's radius at their virtual sharp; the faces' holes become cut-outs and their engravings, up to half the thickness deep, pockets)

#### `sheet.export_bend_table` – Export Bend Table

body?, format?: csv|json (default csv), path? → bend table in mm and degrees, including rule and flat centre-line coordinates; angle_deg is the bend angle and included_angle_deg the angle left between the bend's sides (180° less it); a bend that cut-outs split has a row for each piece

#### `sheet.export_dxf` – Export Flat Pattern as DXF

body?, path?, curves?: exact|arcs (default exact: an ellipse as ELLIPSE, splines, text outlines and other Béziers as SPLINE; arcs: tangent arcs and lines within 0.001 mm, for machines that read only those), text?: cut|etch (default cut: letters that text cut through the sheet are cut contours on layer TEXT; etch: single contours on layer ETCH and the sheet keeps its material there; text machined to a depth is always on ETCH), bend_notes?: bool (default false: a note beside each bend line on layer BEND_NOTES, `B1 UP 90%%d R1`, its angle the included angle when the body's rule has angle_display: included), note_height?: mm (default 3), bend_lines?: bool (default true; false leaves BEND_UP and BEND_DOWN out, for a cutter that would cut them), layers?: roles|single (default roles, the layers below; single: every entity on layer 0), per_body?: bool (a file for every sheet body, `<path>-<body>.dxf`, or their DXF texts without a path → files: [{body, path | dxf, bends}]; not with `body`) → DXF (AutoCAD 2000, mm): layers OUTLINE (the outer contour), CUT (what is cut out inside it), TEXT or ETCH (letters), BEND_UP and BEND_DOWN (dashed centre lines), BEND_NOTES, POCKET_<BOTTOM|TOP|INTERNAL>_Z<from>_TO_<to>_MM (one per side and depth) and PERFORATION; inner contours come before the outline

#### `sheet.flange` – Flange

base: sketch + profiles? (rule?, flip?) | contour: sketch + curves (open chain of lines) + distance (rule?, flip?, reverse?) | edge: edges: [[x,y,z] on top/bottom edges, or {point: [x,y,z], angle?, height?} for an edge with its own angle and height] + height (along the flange, to its far edge), angle? (default 90 deg), radius? (default: rule), height_from?: outer|inner|tangent (where the height is measured from: the outer virtual sharp (default), the inner virtual sharp, or past 90 deg the line square to the flange touching the bend's outside (tangent; up to 90 deg the outer sharp)), position?: inside|outside|middle|material_outside|tangent (where the bend starts: the outer virtual sharp on the edge (default), the bend starting at the edge (bend_outside is the same), half way, the inner virtual sharp on the edge, or the bend's outer face tangent to the edge's face (below 90 deg the bend's end on that face)), flip?, body?, corner_relief_shape?: notch|round|rectangular|tear and corner_relief? (size across): the relief at the corners these flanges make (default: the rule's); then?: [{angle?, height, flip?}] further bends (at most 16), each a flange on the far edge of the one before, flip: true turns that bend the other way (edge only); type?: base|edge|contour (default from the inputs); name?, body_name? (the new body). Thickness, K-factor and bend radius come from the rule (sheet.manage_rules); passing them here is refused, and so is the corner relief on a base or contour flange

#### `sheet.flat_pattern` – Create Flat Pattern

body? → flat size, outline loops and cut-outs (flat coordinates, as point lists), cutout_shapes (the same cut-outs exactly, in the same order: {circle: {center, radius}} for a round hole, else {segments: [{line: [a, b]} | {arc: {center, radius, start_deg, sweep_deg}} | {polyline: [...]}]}), pockets (with their own cutout_shapes), bend lines and the bend table

#### `sheet.fold` – Fold

line: sketch + curve (a sketch line on the sheet's base face; followed when the sketch changes) or points: [[x,y,z], [x,y,z]]; angle? (default 90 deg); radius? (default: rule); position?: centerline|start|end|mould (where the line sits in the bend, default centerline); fixed?: [x,y,z] on the side that stays (default: the larger side); flip? (fold the other way); body?

#### `sheet.hem` – Hem

edges: [[x,y,z] on sheet edges]; length (to the outer face); gap? (inner radius, default: rule); flip?; body?

#### `sheet.manage_rules` – Sheet Metal Rules

name (new or existing); thickness?, k_factor?, bend_radius?, relief_width?, relief_depth?, corner_relief?, hem_gap?, gap? (expressions; `Thickness` is the rule's; gap: between flanges that meet at a corner, whose ends are closed toward each other at any angle); corner_relief_shape?: notch|round|rectangular|tear (what is cut where two bends meet at a corner of the base: round and rectangular a relief `corner_relief` across; tear none, each bend's end is cut straight from the corner to its flange's end; default notch); angle_display?: bend|included (how the DXF bend notes read the bend angles: the bend angle, default, or the included angle left between the bend's sides, 180° less it; the bend table gives both, and a flange's `angle` is always the bend angle); active?: bool; delete?: bool

#### `sheet.path_flange` – Path Flange

edge: [x,y,z] on a top or bottom edge of the sheet; sketch + curves: an open chain of sketch lines drawn on a plane across that edge, from the edge out (each line one flange as long as the line, to the outer face from the virtual sharp; each corner one bend, turning the way the lines turn); radius? (default: rule); body?. One feature, one body

#### `sheet.perforate` – Perforate

diameter, pitch: expr; margin?: expr (clear of edges, cut-outs and bends; default: the diameter); pattern?: staggered (60°, default) | square; body? - a perforation field over the whole flat sheet: holes in the flat pattern (perforations), the DXF (layer PERFORATION) and the measured volume, not cut into the B-rep (#732)

#### `sheet.refold` – Refold

body? (default: the last unfolded sheet)

#### `sheet.rules` – List Sheet Metal Rules

→ rules with their expressions and values, and the active one

#### `sheet.unfold` – Unfold

body? (default: the last sheet body) — all bends

#### `sketch.arc.center_point` – Center Point Arc

center, start, end (counter-clockwise from start) | center, start, sweep: signed degrees; construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.arc.tangent` – Tangent Arc

start: end point of a line or arc ("l1.end"), end: [x,y]; curve?: the curve to be tangent to (default: the one ending at start). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.arc.three_point` – 3-Point Arc

start, end, through: [x,y] or point ref (a referenced through point stays on the arc); construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.arc3d` – 3D Arc

start, through, end: [x,y,z] world points: an exact circular arc through them, from start through through to end (needs 3D Sketch on). Stored exactly (centre, radius, angles), so path consumers can treat it as a true arc. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.auto_constrain` – AutoConstrain

tolerance?: mm (default 0.01), angle_tolerance?: deg (default 1), dimensions?: bool (default true): infer constraints, then dimension until fully constrained

#### `sketch.auto_constrain_from_datum` – AutoConstrain from datum

datum: point ref (default origin); like AutoConstrain with positions measured from the datum

#### `sketch.auto_project` – Auto-Project Edges on Reference

value?: bool (default toggles): project a face's edges when a sketch is created on it

#### `sketch.blend_curve` – Blend Curve

a, b: end points of two curves ("l1.end", "a2.start"), continuity?: g1|g2|g3|g4 (default g1: a tangent spline; g2…g4 match the reference curves' curvature, curvature rate and 4th derivative as well, as one Bézier of degree 5, 7 or 9). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.break` – Break

curve: id, at: [x,y] (split at intersections) | points: [[x,y]…] (1…1000 positions projected onto the curve; duplicates are merged). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.break_link` – Break Link

link?: link id (j1) | entities?: [curve or point ids]: linked geometry becomes normal sketch geometry

#### `sketch.cancel` – Cancel Sketch

Leaves the sketch without keeping what changed since it was created or opened for editing: the design goes back to how it was then (a new sketch is removed), as one step that Undo brings back. Refused when the undo history no longer leads back to that point (use Undo instead)

#### `sketch.centerline` – Centerline

curves: [line ids], value?: bool (default toggles): centerline line type (not in profiles; an axis)

#### `sketch.chain` – Chain

curve: id: the curves joined to it end to end (what a double-click selects)

#### `sketch.chamfer.distance_angle` – Distance and Angle Chamfer

point | a, b: a corner of two lines; distance: along a, angle: deg from a. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.chamfer.equal_distance` – Equal Distance Chamfer

point | a, b: a corner of two lines; distance. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.chamfer.two_distance` – Two Distance Chamfer

point | a, b: a corner of two lines; distance: along a, distance2: along b. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.circle.center` – Center Diameter Circle

center: [x,y] or point ref, radius | diameter: number; through?: point ref (a point the circle passes through, kept on it: where the tool's second click snapped); construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.circle.three_point` – 3-Point Circle

p0, p1, p2; construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.circle.three_tangent` – 3-Tangent Circle

curves: [three lines/circles/arcs], near: [x,y] (which of the solutions). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.circle.two_point` – 2-Point Circle

p0, p1: diameter ends; construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.circle.two_tangent` – 2-Tangent Circle

curves: [two lines/circles/arcs], radius | diameter: expr, near: [x,y] (which of the solutions). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.conic` – Conic Curve

start, end, apex: [x,y] or point refs; rho?: 0…1 (default 0.5: parabola). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.constrainer` – Sketch Constrainer

entities: [one or two sketch entity ids]: applies the constraint the geometry nearly has (horizontal/vertical, parallel, perpendicular, collinear, coincident, concentric, equal, tangent)

#### `sketch.constraint.coincident` – Coincident

a, b: points, a point and a curve or sketch axis (x / y: the sketch's own axes, unless a curve has that id; an axis becomes a linked construction line on it, reported in created), or two distinct lines (joins their closest endpoints), or two circles/arcs (the second lies on the first: concentric and equal, `constraints` lists both); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.collinear` – Collinear

a, b: lines or sketch axes (x / y: the sketch's own axes, unless a curve has that id; an axis becomes a linked construction line on it, reported in created); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.concentric` – Concentric

a, b: circles/arcs; any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.curvature` – Curvature

a, b: two curves sharing an end point (curvature continuous, G2)

#### `sketch.constraint.equal` – Equal

a, b: lines or circles/arcs; or curves: [2 to 200 lines or circles/arcs], each made equal to the first, in one step; any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.fix` – Fix/UnFix

entity: point or curve | entities: [points and curves]; fixed?: bool (default: fix them all unless all are fixed, then unfix)

#### `sketch.constraint.horizontal_vertical` – Horizontal/Vertical

line: id | points: [a, b] (point ids or {midpoint: line_id}; accepted midpoints reuse or create a point with a Midpoint constraint); mode?: horizontal|vertical

#### `sketch.constraint.midpoint` – MidPoint

point, line | a, b in pick order: a point and a line (either way round), or two lines whose midpoints meet (the first stays, the second moves); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.parallel` – Parallel

a, b: lines or sketch axes (x / y: the sketch's own axes, unless a curve has that id; an axis becomes a linked construction line on it, reported in created); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.perpendicular` – Perpendicular

a, b: lines or sketch axes (x / y: the sketch's own axes, unless a curve has that id; an axis becomes a linked construction line on it, reported in created); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.polygon` – Polygon

lines: [line ids] of a closed chain: equal sides with every corner on one circle (a regular polygon)

#### `sketch.constraint.symmetry` – Symmetry

a, b: two points or two curves (lines mirror their ends, circles/arcs their centres); line: symmetry line id, or x / y for the sketch's own axes (a curve with that id wins; an axis becomes a linked construction line on it, reported in created); or point (or a point id as line, "origin" too): symmetric about that point, each pair joined by a construction line it is the midpoint of; any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.constraint.tangent` – Tangent

a, b: curves or sketch axes (x / y: the sketch's own axes, unless a curve has that id; an axis becomes a linked construction line on it, reported in created); any of them may be a model edge {edge: [x,y,z], body?} or vertex {vertex: [x,y,z], body?}, projected into the sketch first (reported in created)

#### `sketch.construction` – Normal/Construction

curves: [ids], value?: bool (default: construction unless all of them already are)

#### `sketch.copy` – Copy Sketch Entities

entities?: [curve or point ids] (default: the selected sketch geometry); the constraints and dimensions among them come along

#### `sketch.create` – Create Sketch

plane: XY|XZ|YZ | construction plane name or id | {origin?: [x,y,z] numbers in mm, default [0,0,0] (not an expression), x_dir, y_dir} (in world coordinates unless frame says otherwise; a named plane is the active component's own) | {face: [world x,y,z], body?: exact world body, index?: face index, path?: complete occurrence ids, fixed?: bool}; new face attachments require a unique certified source (a flat face of a sheet metal body attaches to its panel instead, in the flat pattern's coordinates), fixed:true explicitly freezes the selected plane; offset?: expr, flip?: bool | "x" | "y" (not on a face: sketch the plane from its other side, so the normal and the default extrude direction are reversed; a half turn about the plane's own x or y axis, true picks the one keeping the sketch's y axis upward; offset still moves along the unflipped normal), frame?: world (default) | component (which coordinates an explicit plane is in; the reply's `frame` says which, with a `note` when the active component is moved or turned), project_edges?: bool, name?

#### `sketch.cut` – Cut Sketch Entities

entities?: [curve or point ids] (default: the selected sketch geometry): copies them as sketch.copy does, then deletes them (one undo step)

#### `sketch.delete` – Delete Sketch Entities

entities: [curve, point or constraint ids]

#### `sketch.dimension` – Sketch Dimension

entities: [refs] (a line midpoint is "mid:line_id"), type?: auto|distance|horizontal|distance_x|vertical|distance_y|length|radius|diameter|angle, value?: number or expression (default: current; a bare number is in the design's units, e.g. 2 means 2 in in an inch design; give a unit such as "50 mm" to override), or `name = expression` (e.g. "width = 40"; also `#name = expression`), which adds the user parameter `name` with that expression and dimensions with `name` (refused when the name is taken or reserved; the reply's `defined` names it); text_at?: [x, y]. Two points or a line off the axes: with auto, text_at across from them is the distance between them, above or below them horizontal, beside them vertical. Two midpoints: placing text above or below their bounding box measures horizontally, beside it vertically. Two lines: the angle between them (acute, or 180° − it when the value is nearer that) unless text_at picks a sector. A line and a circle or arc: the distance from the line to its edge (the gap, or how far the edge reaches past a line that cuts it; 0 is tangent); dimension the centre point for the distance to the centre. A point and a circle or arc: the distance from the point to its edge (or how far within it a point inside lies). Two circles or arcs: the gap between their edges (or how far they overlap when they cross, or the narrowest gap between them when one lies inside the other); dimension their centre points for the distance between centres. An arc and one of its end points: the arc's length (type arc_length does it from the arc alone). A dimension the sketch already determines is refused (naming what determines it); if_redundant?: "driven" places it as a driven (reference) dimension instead. scale_sketch?: bool (the dimension tool sends true): when this is the sketch's first length dimension and nothing in the sketch fixes a size (no other driving length dimension, nothing fixed or projected), the whole sketch scales about its origin to the value instead of distorting. Returns measured in unit (mm or deg), and scaled: the factor when the sketch was scaled

#### `sketch.dimension_text` – Move Dimension Text

dimension: constraint id or parameter name; at: [x,y] text centre (sketch coordinates) | reset: true (default place)

#### `sketch.drag` – Drag Sketch Geometry

entity: point or curve, from: [x,y] where it was grabbed, to: [x,y], live?: bool: points and the material point grabbed on a line move toward `to` within the design constraints. When exact placement is impossible, bounded feasible steps minimize cursor distance. Splines slide by to - from; a circle or arc grabbed on its edge takes the radius to `to`. `with?`: [point or curve ids] moves the rest of a selection with the entity as one translation (circles keep their radii). Long moves retain the solution branch; arcs cannot sweep through their starts. Returns `reached`: progress projected onto the requested move (0..1), `at`: the grabbed position for the next frame, and `retry`: budget-limited progress can continue in another frame. `live: true` shares a work budget across held-solve decomposition and cursor correction; ordinary recovery and the final model evaluation retain their existing limits, not a wall-clock deadline. Later features stay stale until `sketch.drag_end`; `dof` stays from before the drag

#### `sketch.drag_end` – End Sketch Drag

constraint?: {command: a sketch.constraint.* id, params}: ends a drag made of `sketch.drag` `live: true` frames: adds the constraint it let go on (not kept if it over-constrains the sketch), then evaluates the whole model once; returns the constraint's result and the sketch's solved state and degrees of freedom

#### `sketch.draw.dimensioned` – Draw Dimensioned Sketch Geometry

command: sketch creation command, params: object, dimensions: object of role to numeric or expression value; creates geometry and all driving dimensions atomically in one undo step. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.drawing_bounds` – Drawing Size

path | text: SVG or DXF (by `format`: "svg" | "dxf", default by the file name, else SVG); returns min, max, width and height in the file's own size

#### `sketch.edit` – Edit Sketch

sketch: id or name

#### `sketch.edit_text` – Edit Text

link: the text's link id (or entity: one of its curves), text? or text_expression? (as in sketch.text; typed words replace the expression), at?, height?, angle?: deg (numbers or expressions as in sketch.text; a number replaces an expression, and so does moving the text), font?: family or file path (empty: the built-in font), bold?, italic?: bool (an installed family's bold or italic face; italic without one is slanted), align?: left|center|right (the lines against `at`, or along the path), letter_spacing?: extra mm between letters, line_spacing?: times the font's line distance (default 1), path?: a curve id of the sketch the baseline follows ("": none; `at` and `angle` then do not place the text; the curve becomes construction, a guide the letters stand on), reverse?: bool (the other way along the path) (each kept when left out); or edits: [{link or entity, text?, at?, …}]: several texts changed together, the design rebuilt once (all or nothing; returns edits: each one's result); live?: bool: one frame of an interactive change (the sketch is solved, the features after it stay as they were until `sketch.drag_end`). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.ellipse` – Ellipse

center, major: end of the major axis [x,y], minor: a point the ellipse passes through on the minor side [x,y] | minor_radius. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.export_dxf` – Save As DXF

sketch?: id|name (default active); path?: file to write (else the DXF text is returned)

#### `sketch.extend` – Extend

curve: id, at: [x,y] near the end to extend (a line runs on to the nearest curve, or the previewed reach when nothing is in the way; an arc grows along its circle and closes into a whole circle when nothing stops it)

#### `sketch.fillet` – Fillet

point: corner shared by two curves ("l1.end") | points: [corners] (all rounded alike: one radius, the rest equal) | a, b: two lines or arcs meeting at a corner; radius: expr. A corner that dimensions or constraints measure to stays as a virtual sharp corner on both curves' extensions (`virtual_corners`; the moved ones in `moved_to_virtual_corner`). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.finish` – Finish Sketch

(keine Parameter)

#### `sketch.finish_auto_constrain` – Finish with AutoConstrain

like AutoConstrain, then Finish Sketch

#### `sketch.fit_curves_to_section` – Fit Curves to Mesh Section

body: name (a mesh or solid body): its section with the sketch plane, fitted with lines and arcs, as normal (unlinked) geometry. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.glyphs` – Constraint Glyphs

sketch?: id|name: every constraint with where to draw its glyph (sketch coordinates)

#### `sketch.include_3d` – Include 3D Geometry

refs: like Project (edges, vertices, sketch curves and points); curves out of the sketch plane are flattened onto it. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.infinite` – Infinite Line

curves: [line ids], value?: bool (default toggles): infinite line type (#1359): construction geometry drawn across the whole view through the line's two points; off, a normal line

#### `sketch.insert_dxf` – Insert DXF

path | text: ASCII DXF (blocks expanded); at?: [x,y] offset, scale? | width? | height?: mm, the drawing's size before rotation, aspect kept (win over scale); angle?: degrees, about the drawing's origin (or its centre); align?: "origin" (default: `at` is where the file's origin goes) | "center" (`at` is where the drawing's middle goes and it turns and scales about it); tolerance?: mm within which ends join (default 0.0001); plane?: (when no sketch is active, a new sketch on it; default XY). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.insert_svg` – Insert SVG

path | text: SVG; at?: [x,y] offset, scale? | width? | height?: mm, the drawing's size before rotation, aspect kept (win over scale); angle?: degrees, about the drawing's origin (or its centre); align?: "origin" (default: `at` is where the file's origin goes) | "center" (`at` is where the drawing's middle goes and it turns and scales about it); tolerance?: mm within which ends join (default 0.0001); plane?: (when no sketch is active, a new sketch on it; default XY). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.inspect` – Inspect Sketch

sketch?: id|name (default active)

#### `sketch.intersect` – Intersect

refs: [{body}, {face: [x,y,z], body?}, {edge: [x,y,z], body?}, {sketch, curve}]: section curves (or points) with the sketch plane, linked. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.intersection_curve` – Intersection Curve

a, b: {body} | {face: [x,y,z], body?}: where they meet, as linked 3D curves. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.isoparametric_curve` – Isoparametric Curve

face: [x,y,z] point on the face (the curve passes through it), body?, direction?: u|v|[x,y,z] (default u): linked 3D curve. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.line` – Line

points: [[x,y] | "l1.end" | {at, ref}…] (x and y each a number or an expression over the design's parameters, "W / 2": such a point is fixed where it comes to and follows the parameters; likewise wherever a point argument also takes a point id), closed?: bool, construction?: bool, ids?: [..], infer?: bool (add horizontal/vertical); connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.line.midpoint` – Midpoint Line

mid: [x,y], point ref or snap ("mid:<line>", "on:<curve>:x,y", model vertex/edge); end: [x,y]; construction?. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.line3d` – 3D Line

points: [[x,y,z]…] world points (2 or more): one 3D line per segment, joined end to end (needs 3D Sketch on). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.loose_ends` – Loose Ends

sketch?: id|name (default active): the ends of profile curves (not construction, projected or text) that can make a profile fail. open: [{point, curve, at}] ends that touch no other profile curve (no profile runs through them); untied: [{point, curve, at, touches: {point}|{curve}}] ends that touch another curve only by position (the profile closes now, but nothing keeps it closed when a dimension changes)

#### `sketch.loose_ends.tie` – Tie Loose Ends

sketch?: id|name (default active); points?: [point ids] (default: every untied end): ties each untied end to what it touches, coincident with another curve's end or on another curve. Returns constraints: [ids added], and the untied ends left

#### `sketch.mirror` – Mirror

entities: [curve/point ids], line: mirror line id (symmetry constraints are added). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.move` – Move/Copy Sketch Entities

entities: [ids], translate?: [dx,dy], angle?: deg, center?: [x,y], copy?: bool, rotate_constraints?: bool (default true; false keeps constraints unchanged); a rotation turns the constraints tied to the sketch axes when all their geometry moves (horizontal and vertical relations and dimensions swap at odd quarter turns and stay at half turns, line angles turn with the line) and removes the horizontal and vertical ones that cannot hold at other angles; picking a text outline or linked point transforms its whole text source once, and copies remain editable text. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.move3d` – Move 3D Point

wire: drawn 3D curve or point id, index?: fit point (default 0), to: [x,y,z] | by: [dx,dy,dz]; points joined to it move too

#### `sketch.move_point` – Drag Sketch Point

point: ref, to: [x,y]

#### `sketch.offset` – Offset

curves: [ids], distance: number in mm or length expression (creates an editable dimension; positive = left of the chain, or toward `side`), side?: [x,y], chain?: bool (default true: the connected chain); direction?: one_side|symmetric (default one_side) or symmetric?: bool (the same distance each way; no `side`, whose job it takes over), distance2?: positive length expression (Two Sides: an independent distance the other way, as for `solid.extrude`). Each side is its own offset association, listed in `sides`; flip?: bool reverses the primary side; `param`/`param2` name the driving dimensions. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.offset.break` – Break Offset Association

curve: derived offset curve id (retains geometry and makes its points editable)

#### `sketch.options` – Sketch Palette Options

sketch?: id|name (default active); any of show_profile, show_points, show_dimensions, show_constraints, show_projected, show_construction, grid, snap, slice, sketch_3d: bool. Returns them all

#### `sketch.paste` – Paste Sketch Entities

at?: [x, y] (sketch point the copy's centre goes to) | translate?: [x, y]; without either, offset from the original in its own sketch and at the same coordinates in another; sketch?: target (default: the active sketch)

#### `sketch.pattern.circular` – Circular Pattern

entities: [ids], center: [x,y] or point ref, count: 2…500 (number or unitless expression, retained through edits), angle?: total deg, number or expression (default 360); alignment?: left|center|right (default right); reversed?: bool (default false). Quantity includes the original. Center balances copies around it; reversed flips the direction and extra side for even totals. Partial arcs span angle with angle/(count-1) spacing; full turns use angle/count. Adds associative pattern constraints; a coordinate center creates a constrainable point. Returns pattern and center ids. pattern?: existing pattern id to edit (omitted values retained; surviving instance ids retained). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.pattern.rectangular` – Rectangular Pattern

entities: [ids], count, spacing; count2?, spacing2?; counts: positive integer numbers or expressions, at most 500 instances total; spacings: length numbers or expressions; direction?, direction2?: sketch line ids (live references); dir?, dir2?: [x,y] vectors (defaults: sketch x, perpendicular to direction 1); alignment?, alignment2?: left|center|right (default right). Signed spacings reverse each direction. reversed?, reversed2?: bool (default false); reverses placement and the extra side of even centered totals. Quantities include the original. Adds associative pattern constraints. Returns pattern id. pattern?: existing pattern id to edit (omitted values retained; surviving instance ids retained). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.point` – Point

point: [x,y] (each a number or an expression over the design's parameters: the point is then fixed where it comes to and follows them) or a snap: "mid:<line>" (held at the line's midpoint), "on:<curve>:x,y" (on the curve near x,y), {vertex: [x,y,z]} or {on_edge: [x,y,z]} of the model; id?; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.point3d` – 3D Point

point: [x,y,z] world point (needs 3D Sketch on). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.polygon.circumscribed` – Circumscribed Polygon

center, radius (to edge midpoints), sides, angle?: deg; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.polygon.edge` – Edge Polygon

p0, p1: one edge, sides; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.polygon.inscribed` – Inscribed Polygon

center, radius (to vertices), sides, angle?: deg; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.project` – Project

refs: [{edge: [x,y,z], body?} | {face: [x,y,z], body?} (its edge loops) | {body: name} (silhouette) | {vertex: [x,y,z], body?} | {sketch, curve} | {sketch, point} | "origin" | {axis: X|Y|Z} | {plane: XY|XZ|YZ|name}]. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.project_to_surface` – Project To Surface

curves: [{sketch, curve}…] (curves of other sketches), face: [x,y,z] point on the target face, body?: projected along the active sketch's normal onto the face, as linked 3D curves. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.rectangle.center` – Center Rectangle

center, corner; construction?: bool. Returns sides {bottom, right, top, left} (line ids) and corners {bottom_left, bottom_right, top_right, top_left} (point ids); connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.rectangle.rounded` – Rounded Rectangle

p0, p1: opposite corners [x,y]; radius: expr (the corner radius, less than half the shorter side); construction?. A 2-point rectangle whose four corners are filleted alike: one radius dimension (`param`), the other arcs equal to it. Returns sides {bottom, right, top, left} (line ids) and arcs (the corner arcs: bottom-left, bottom-right, top-right, top-left); connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.rectangle.three_point` – 3-Point Rectangle

p0, p1: first edge; p2: point on the opposite edge; construction?: bool; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.rectangle.two_point` – 2-Point Rectangle

p0, p1: opposite corners [x,y]; construction?. Returns sides {bottom, right, top, left} (line ids) and corners {bottom_left, bottom_right, top_right, top_left} (point ids); connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.redefine` – Redefine Sketch Plane

sketch: id or name; plane: as sketch.create; frame?: as sketch.create; author_path?: exact owner occurrence ids; explicitly rebinds or freezes the plane while preserving geometry and dimension names

#### `sketch.scale` – Sketch Scale

entities: [curve/point ids], base: [x,y] or point ref, factor: number

#### `sketch.slot.arc_center` – Center Point Arc Slot

center, start: centre arc start, end: direction of the centre arc end (counter-clockwise) or sweep: degrees (0 < sweep < 360), width; returns centre_arc. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.slot.arc_three_point` – Three Point Arc Slot

start, through, end: points on the centre arc, width. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.slot.center_point` – Center Point Slot

center: slot centre, end: one arc centre, width. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.slot.center_to_center` – Center to Center Slot

p0, p1: arc centres, width; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.slot.overall` – Overall Slot

p0, p1: overall ends, width; connect?: bool (default true: a new point landing exactly on an existing point, the origin too, is made coincident with it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.snap` – Snap Inference

at: [x,y], from?: [x,y] (previous click), radius?: mm (snap distance, default 1): what a click there would snap to and infer

#### `sketch.solve` – Solve Sketch

reports the solver status and degrees of freedom

#### `sketch.spline.control_point` – Control Point Spline

points: control points (2…500), cubic. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.spline.control_point_5` – Control Point Spline (Degree 5)

points: control points (2…500), degree 5. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.spline.fit_point` – Fit Point Spline

points: [[x,y] or point refs…] (2…500): the spline passes through them, periodic?: boolean (default false); periodic cubic fit closes smoothly through at least 3 distinct samples. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.spline.insert_point` – Add Spline Point

curve: fit point spline id, at: [x,y]: a fit point is inserted where the curve passes nearest to it, between its neighbours (the curve still runs through it and all its old points; constraints on them stay); end?: start|end: `at` becomes the spline's new first or last point instead, and the curve runs on to it (refused when that end is joined to other geometry). Control point splines take no new points yet. Returns point: the new point's id

#### `sketch.spline3d` – 3D Spline

points: [[x,y,z]…] world fit points (2 or more): a smooth 3D curve through them (needs 3D Sketch on). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.spun_profile` – Spun Profile

body: name, axis: a line of the active sketch (curve id) | X|Y|Z: the body's outline revolved about the axis, in the sketch plane. Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.text` – Text

text: string (\n breaks lines), or text_expression: the words built from text parameters (parameters.add with unit text) and quoted texts joined by + ("Label + '-L'"): the text keeps it, its words follow the parameters (a parameter edit or a configuration row relabels it) and `exprs` returns it as `text`; at: baseline start [x,y], height?: capital height mm (default 5), angle?: deg; at's x and y, height and angle each take a number or an expression over the design's parameters as a string ("plate_width / 2", "label_size"): the text keeps the expression, follows the parameters, and returns it in `exprs`; an expression naming no parameter is the number it comes to, a bare number in one is in the design's units, font?: an installed font's family or full name, or a .ttf/.otf file path (~ and %VAR% expand; default: the built-in Liberation Sans), bold?, italic?: bool (an installed family's bold or italic face; italic without one is slanted), align?: left|center|right (the lines against `at`, or along the path), letter_spacing?: extra mm between letters, line_spacing?: times the font's line distance (default 1), path?: a curve id of the sketch the baseline follows ("": none; `at` and `angle` then do not place the text; the curve becomes construction, a guide the letters stand on), reverse?: bool (the other way along the path). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.toggle_driven` – Toggle Driven Dimension

constraint: dimension id, driven?: bool (default toggles); a driving dimension gets a parameter with its current value

#### `sketch.transform` – Transform

entities: [curve/point ids], factor?: number (scale), angle?: degrees (turn), center?: [x,y] or point ref (what scales and turns stay put; default [0,0]), translate?: [dx,dy] (applied last); scales, turns and moves in one step

#### `sketch.trim` – Trim

curve: id, at: [x,y] (the piece to remove: between the nearest intersections around it). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `sketch.trim.path` – Trim Along Path

points: [[x,y]…] (2…2000 positions: a path drawn across the sketch). Every piece the path crosses is removed as `sketch.trim` removes the piece at that crossing, in the order the path crosses them; a piece crossed again after it is gone is not trimmed twice; projected geometry, infinite lines, offset outputs and pieces trim refuses are passed over (why in `skipped`). dry_run?: bool (report without changing the design). One undo step → trimmed: [each trim's result], removed: [[[x,y]…]] (each removed piece as a polyline). Returns created: {points, curves, constraints, dimensions}: the ids of what it added (stable and never reused: usable right away in sketch.dimension, sketch.constraint.*, sketch.delete…)

#### `solid.box` – Box

length, width, height: expr; corner?: [x,y,z] | center?: [x,y,z] (numbers in mm or length expressions; default: the origin); operation?, targets?: [body], name?, body_name?

#### `solid.shell` – Shell

faces: [[x,y,z] points on the faces to remove, or face names from model.faces]; thickness: expr; direction?: inside|outside|both; tangent_chain?: bool (also open faces joined smoothly to the picked ones); body?

