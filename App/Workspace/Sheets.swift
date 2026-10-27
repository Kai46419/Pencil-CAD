import SwiftUI

// MARK: Variablen

/// Einfügen › Variable: benannte Werte des Projekts (wie Shapr3D „Variables“ bzw. Fusion 360 „Parameter“).
/// Jede Variable darf eine Formel mit anderen Variablen sein; Skizzenmaße mit Variablen folgen beim Sichern.
struct VariablesSheet: View {
    @ObservedObject var model: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var list: [ProjectVariable] = []
    @State private var newName = ""
    @State private var newExpression = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if list.isEmpty {
                        Text("Noch keine Variable. Unten anlegen, z. B. „wand“ = „2 mm“.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($list) { $variable in
                        HStack(spacing: 10) {
                            TextField("Name", text: $variable.name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .frame(width: 140)
                            Text("=")
                                .foregroundStyle(.secondary)
                            TextField("Wert oder Formel", text: $variable.expression)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text(valueText(variable.name))
                                .monospacedDigit()
                                .foregroundStyle(values[variable.name] == nil ? Color.red : Color.secondary)
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                    }
                    .onDelete { list.remove(atOffsets: $0) }
                } header: {
                    Text("Variablen")
                } footer: {
                    Text("In jedem Zahlenfeld und in Skizzenmaßen nutzbar, z. B. „2 × wand“, „breite / 2 + 5“, "
                         + "„sqrt(a^2 + b^2)“. Einheiten: mm, cm, m, in, ft, deg. Ein Skizzenmaß mit Variable (ƒ) "
                         + "folgt ihr; Körper daraus werden über den Verlauf (Zeitleiste) neu berechnet.")
                }
                Section("Neue Variable") {
                    HStack(spacing: 10) {
                        TextField("Name, z. B. wand", text: $newName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(width: 160)
                        Text("=")
                            .foregroundStyle(.secondary)
                        TextField("Wert, z. B. 2 mm", text: $newExpression)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                        Button("Hinzufügen", systemImage: "plus.circle.fill", action: add)
                            .disabled(newName.isEmpty || newExpression.isEmpty)
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Funktionen") {
                    Text(Formula.functionNames.joined(separator: ", ") + ", pi, e")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Variablen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                }
            }
            .onAppear { list = model.variables }
        }
    }

    private var values: [String: Double] { Formula.resolve(list) }

    private func valueText(_ name: String) -> String {
        guard let value = values[name] else { return "Fehler" }
        return "= " + NumberField.format(value)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let expression = newExpression.trimmingCharacters(in: .whitespaces)
        guard Formula.isValidName(name) else {
            problem = "„\(name)“ geht nicht als Name: Buchstaben, Ziffern und _, nicht mit einer Ziffer beginnend, "
                + "keine Einheit oder Funktion."
            return
        }
        guard !list.contains(where: { $0.name == name }) else {
            problem = "„\(name)“ gibt es schon."
            return
        }
        problem = nil
        list.append(ProjectVariable(name: name, expression: expression))
        newName = ""
        newExpression = ""
    }

    private func save() {
        let names = list.map(\.name)
        if let invalid = names.first(where: { !Formula.isValidName($0) }) {
            problem = "„\(invalid)“ geht nicht als Name."
            return
        }
        if Set(names).count != names.count {
            problem = "Jeder Name darf nur einmal vorkommen."
            return
        }
        if let broken = list.first(where: { values[$0.name] == nil }) {
            problem = "„\(broken.name)“ lässt sich nicht ausrechnen (Tippfehler oder Kreisbezug?)."
            return
        }
        model.setVariables(list)
        dismiss()
    }
}

// MARK: Projekt einfügen

/// Einfügen › Projekt: ein anderes Projekt wählen, seine Körper kommen als Kopie in einen eigenen Ordner.
struct ProjectPickerSheet: View {
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let current: UUID
    let pick: (Project) -> Void

    var body: some View {
        NavigationStack {
            List {
                let others = projects.projects.filter { $0.id != current }
                if others.isEmpty {
                    Text("Es gibt noch kein anderes Projekt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(others) { project in
                    Button {
                        pick(project)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            thumbnail(project)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .foregroundStyle(.primary)
                                Text(project.modified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Projekt einfügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private func thumbnail(_ project: Project) -> some View {
        Group {
            if let image = UIImage(contentsOfFile: project.thumbnailURL.path(percentEncoded: false)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 48)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Hilfe

/// Hilfeseiten im Menü „Hilfe“ der Titelleiste.
enum HelpTopic: String, CaseIterable, Identifiable {
    case gestures = "Gesten und Stift"
    case sketch = "Skizzieren"
    case model = "Modellieren"
    case formulas = "Formeln und Variablen"
    case news = "Neu in diesem Build"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .gestures: "hand.draw"
        case .sketch: "pencil.and.outline"
        case .model: "cube"
        case .formulas: "x.squareroot"
        case .news: "star"
        }
    }

    var paragraphs: [String] {
        switch self {
        case .gestures:
            [
                "Ein Finger dreht die Ansicht, zwei Finger verschieben und zoomen. Der Stift zeichnet und wählt.",
                "Stift schweben lassen: die Fläche, der Skizzenbereich oder die Kante darunter leuchtet hellblau – so "
                    + "sieht man vor dem Antippen, was getroffen wird.",
                "Stift drücken (Apple Pencil Pro) oder doppeltippen öffnet das Werkzeugrad.",
                "Mit zwei Fingern tippen nimmt den letzten Schritt zurück, mit drei Fingern tippen wiederholt ihn.",
                "In der Skizze: Stift 1 s ruhig über einem Punkt halten merkt ihn; zwei gemerkte Punkte zeigen Abstand "
                    + "und Mitte. Finger auflegen, während der Stift zeichnet, macht aus der Linie einen tangentialen Bogen.",
                "Rahmen aufziehen (mit dem Stift ins Leere ziehen): nach rechts ganz umschlossene, nach links auch "
                    + "angeschnittene Körper.",
            ]
        case .sketch:
            [
                "Skizze beginnen, Ebene oder ebene Körperfläche antippen, dann zeichnen. Der grüne Haken beendet die Skizze.",
                "Maße direkt am Element antippen: die Rechner-Tastatur kann rechnen (+ − × ÷, Klammern, mm/cm/m, °), "
                    + "Variablen einsetzen und mit ⌨︎ auf die Bildschirmtastatur wechseln. Das Schloss legt ein Maß fest "
                    + "oder löst es.",
                "Fang (Magnet rechts): Raster, Skizzenleitlinien (waagerecht/senkrecht, 15°-Winkel), Skizzenleitpunkte "
                    + "(Enden, Mitten, Zentren, Schnittpunkte), 3D-Leitpunkte (Ecken und Kantenmitten der Körper) und "
                    + "entfernte Kanten. Unter „Zeigen“ lassen sich die Leitpunkte und die Einrasthinweise am Stift abschalten.",
                "Einschränkungen rechts: Elemente antippen, dann die Einschränkung. Was zur Auswahl nicht passt, ist "
                    + "ausgegraut. „Trennen“ löst die Einschränkungen der Auswahl, „Konstruktion erstellen“ macht sie zu "
                    + "Hilfslinien.",
            ]
        case .model:
            [
                "Skizzenbereich oder ebene Fläche antippen und am blauen Pfeil ziehen. Weitere Flächen antippen zieht sie "
                    + "gemeinsam.",
                "Fläche versetzen: auch runde Flächen und Bohrungen; „Gesamt“ setzt das Gesamtmaß, „Durchmesser“ den "
                    + "Durchmesser. Fläche ersetzen verlängert Flächen bis an eine Zielfläche.",
                "Umhüllen und Prägen legt Text oder ein Logo um einen Zylinder. Kante abdrücken überträgt eine Skizze als "
                    + "Kanten auf den Körper.",
                "Verschieben: Pfeile ziehen entlang einer Achse, die farbigen Quadrate in einer Ebene, die Ringe drehen "
                    + "um X (rot), Y (grün) und Z (blau). „Kopieren“ lässt das Original stehen. Übersetzen bringt einen "
                    + "Körper von einem Punkt genau auf einen anderen.",
                "Im Browser „Ebenen“ lassen sich Körper in Ordner legen (lange drücken › In Ordner) und nach Körpern, "
                    + "Skizzen oder Konstruktion filtern.",
            ]
        case .formulas:
            [
                "Jedes Zahlenfeld rechnet: „40 / 2“, „3 × 12,5“, „1,5 cm“, „30°“, „sqrt(2) × 10“.",
                "Einfügen › Variable legt benannte Werte an, z. B. wand = 2 mm, breite = 40. Danach geht überall "
                    + "„breite − 2 × wand“.",
                "Ein Skizzenmaß mit Variable trägt ein ƒ und folgt, wenn die Variable sich ändert; Körper aus der Skizze "
                    + "werden über den Verlauf neu berechnet. Auch Werte in der Zeitleiste (Abstand, Radius …) können "
                    + "Formeln mit Variablen sein.",
                "Funktionen: " + Formula.functionNames.joined(separator: ", ") + ". Winkelfunktionen rechnen in Grad.",
            ]
        case .news:
            [
                "Bild als Vorlage aus drei Quellen: Einfügen › Bild aus Fotos, Bild aus Dateien (PNG, JPEG, HEIC, "
                    + "PDF-Seite 1) oder Foto aufnehmen mit der Kamera – danach startet gleich das Kalibrieren auf Maß.",
                "Werkzeuge neu sortiert wie in Fusion 360: Bohrung, Spiegeln, Muster und Negativform liegen jetzt unter "
                    + "Erstellen, Ändern enthält nur noch Änderungen an Körpern, Transformieren nur Lage und Größe.",
                "Verschieben/Rotieren feiner: Drehgriffe sind jetzt schlanke Bögen fester Bildschirmgröße (unabhängig "
                    + "von Zoom und Körpergröße) im Viertel zur Kamera; der Griff unter dem Stift leuchtet auf, beim Ziehen "
                    + "bleibt nur der gegriffene sichtbar. Beim Drehen: voller Ring (Rückseite blass), Striche alle 15° "
                    + "ab dem Ansatz, überstrichener Winkel als Segment und Grad-Etikett.",
                "Schnittansicht mit Pfeil: blauer Ziehpfeil senkrecht zur Schnittebene – ziehen führt den Schnitt "
                    + "live durch den Körper, der Versatz steht am Pfeil und in der Karte.",
                "Neuer Körper: jeder angetippte Skizzenbereich wird ein eigener Körper, auch wenn Bereiche sich berühren.",
                "In Einzelkörper trennen löst jetzt auch sich berührende, noch nicht verschmolzene Teile eines Körpers.",
                "Fläche nach innen ziehen: Bohrungen und Senkungen in der Fläche werden mit gekürzt statt als Röhre "
                    + "stehen zu bleiben.",
                "Oberflächen als Feinschliff: Eigenschaften-Fenster › Oberfläche (oder Kontextmenü des Körpers im "
                    + "Ebenen-Browser) mit Vorschau-Kugeln – Chrom, Spiegel, Gold, Kupfer, Messing, Edelstahl gebürstet, "
                    + "Aluminium eloxiert, Holz (Eiche, Nussbaum …), Beton, Carbon, Glas, Gummi, Lacke matt/glänzend und "
                    + "RAL-Farben (Olivgrün 6003, Gelboliv 6014, Bronzegrün 6031 …), PLA-Farben. Eigene Farbe mit matt, "
                    + "seidenmatt, glänzend und Metall. Spiegelnde Flächen zeigen eine Studio-Umgebung; das Gewicht "
                    + "kommt weiter vom Werkstoff.",
                "Skizze: Radius eines Bogens ändern (Maß oder Ziehen an der Wölbung) bewegt nur den Bogen – seine Enden "
                    + "gleiten auf den Nachbarlinien, der Rest bleibt stehen. Gewählte Bögen und Kreise haben einen blauen "
                    + "Griff zum Ziehen des Radius.",
                "Skalieren: Der Körper verschwindet nicht mehr bei großen Faktoren (Faktor 0,01–100, die Ansicht zoomt "
                    + "nach dem Loslassen heraus); Skalieren startet immer bei 1×.",
                "Ansichtswürfel: mit Stift oder Finger ziehen dreht die Ansicht weich und läuft kurz nach; Antippen "
                    + "einer Seite, Kante oder Ecke schwenkt animiert dorthin.",
                "Skizzenlinien in Graphit: beim Zeichnen und fertig dieselbe feine Linie mit kleinen Endpunkten, "
                    + "Profilflächen dezent grau statt blau.",
                "Gewindebohrung überall: Im Werkzeug Gewinde setzt Antippen einer Fläche, die kein Bolzen und keine "
                    + "Bohrung ist (Oberseite, Unterseite, Seite oder Rundung), eine Gewindebohrung am Tippunkt ins "
                    + "Material – senkrecht zur Fläche, mit Tiefe oder durchgehend, mehrere Stellen möglich. Auch das "
                    + "Werkzeug Bohrung geht jetzt auf gewölbten Flächen.",
                "Abziehen mit Vorschau: das Ergebnis erscheint sofort, das Ziel ist orange umrandet, Werkzeuge sind "
                    + "halbtransparent rot; in der Karte stehen die Rollen („Als Ziel“ tauscht sie). Neu: Spiel in mm "
                    + "(Vorlagen FDM 0,2 · Harz 0,1) dickt das Werkzeug vor dem Abziehen auf.",
                "Ändern › Negativform: Körper antippen – ein Block mit Rand (Standard 10 mm) entsteht um ihn, der Körper "
                    + "wird mit Spiel herausgeschnitten, auf Wunsch in zwei Hälften geteilt. Der Körper bleibt erhalten.",
                "Neue Skizze: Die Ebenen Oben, Vorne, Rechts liegen beschriftet und größer neben den Körpern, unten gibt "
                    + "es Kacheln dafür (auch für eigene Konstruktionsebenen). Ebene Körperflächen leuchten unter dem "
                    + "Stift auf – antippen und darauf skizzieren.",
                "Gewinde: Kernloch jetzt nach Bohrertabelle (ISO 2306, z. B. M6 → Ø 5,0; UNC/UNF/G/NPT nach üblichen "
                    + "Tabellen), Druckspiel kommt dazu. Neben dem Druckspiel gibt es Vorlagen (FDM 0,3 · Harz 0,1 · "
                    + "Fräsen 6H/6g 0); die letzte Wahl wird gemerkt.",
                "Gewinde „Kosmetisch“: keine Gewindegeometrie, Bohrung nur mit Kernloch, Bolzen bleibt – dünne Ringe "
                    + "zeigen das Gewinde. Jedes Gewinde steht jetzt als Eigenschaft am Körper (Eigenschaften-Fenster: "
                    + "„Gewinde: M6×1 · 12 mm · innen · modelliert“) und wird mit dem Projekt gespeichert.",
                "Gewinde robuster und genauer: die Schraubenlinie wird je Umdrehung gebaut (lange Gewinde wie M3 × 60 mm "
                    + "stimmen jetzt und rechnen etwa doppelt so schnell), Gänge und Kernloch werden in einem Schritt "
                    + "abgezogen. Sackloch-Gewinde enden wahlweise bis Grund, mit Auslauf nach DIN 76 oder nach Maß.",
                "Gewinde (Erstellen › Gewinde): Zylinderfläche antippen – Bolzen bekommen ein Außen-, Bohrungen ein "
                    + "Innengewinde, die passende Normgröße wird vorgeschlagen. Metrisch ISO (Regel- und Feingewinde "
                    + "M1–M64), UNC/UNF, Whitworth, Rohrgewinde G, R und NPT (kegelig), Trapez, Rund- und Sägengewinde; "
                    + "Steigung, Länge, Versatz, Links/Rechts und 1–4 Gänge wählbar. Das Gewinde wird echt modelliert "
                    + "(druckbar), mit Druckspiel (Standard 0,2 mm) und Anschnitt am freien Ende. Auch im Werkzeug "
                    + "Bohrung gibt es jetzt die Option „Gewinde“ (Kernloch nach Norm plus Innengewinde).",
                "STL und 3MF importieren (Import-Knopf bzw. Einfügen › STL / 3MF): das Netz wird repariert und ein "
                    + "echter Körper – bohren, schneiden, vereinigen und ebene Flächen extrudieren gehen.",
                "Beim Import: doppelte Punkte verschweißt, kaputte Dreiecke entfernt, kleine Löcher geschlossen. "
                    + "Über 60.000 Dreiecke wird vorher reduziert; die Meldung sagt, was passiert ist.",
                "Ändern › Netz bearbeiten: mit dem Stift anheben, absenken, glätten, abflachen. Fester drücken "
                    + "verstärkt; unten Radius, Stärke, Verfeinern, Reduzieren und Löcher schließen.",
                "Messen (Prüfen › Messen): Kante antippen zeigt die ganze Länge, bei Kreisen und Bögen auch Radius und "
                    + "Durchmesser. Fläche antippen zeigt den Inhalt in mm² und Länge × Breite (Zylinder: Durchmesser "
                    + "und Höhe). „Punkt zu Punkt“: der zweite Punkt rastet parallel zu X, Y, Z bzw. senkrecht zur "
                    + "Fläche ein (gestrichelte Leitlinie in Achsfarbe), dazu ΔX/ΔY/ΔZ.",
                "Viele angrenzende Skizzenbereiche (z. B. Zähne einer Gewindestange) werden vor dem Extrudieren zu "
                    + "einem Profil zusammengefasst – schneller und ohne Absturz.",
                "Eigenschaften (rechte Leiste, „i“): Körper, Fläche oder Kante antippen – das Fenster zeigt L × B × H, "
                    + "Volumen, Oberfläche, Gewicht, Schwerpunkt bzw. Flächenart, mm², L × B, Ø, Kantenlänge und Radius. "
                    + "Darunter „3D-Druck“: Düse, Wandlinien, Schichthöhe, Decken/Böden, Füllung, Filament und Preis "
                    + "eingeben (bleiben gespeichert) – geschätzt wie ein Slicer in Gramm, Metern und Euro.",
                "Körper antippen zeigt seine Außenmaße (L × B × H) im Hinweis oben.",
                "Skalieren: am Pfeil ziehen oder Faktor eingeben, immer gleichmäßig um die Mitte.",
                "Foto kalibrieren geht jetzt auch in der Skizze und startet nach dem Einfügen gleich. Beim Ziehen mit dem "
                    + "Stift zeigt eine Lupe die Stelle, der Punkt sitzt beim Absetzen. Danach ist das Foto gesperrt "
                    + "(Schloss im Bild-Werkzeug löst es).",
                "Zeichnungen: Unter dem Projektnamen steht „Created by Kai Rosenfeld“ – änderbar im Zeichnungsfenster "
                    + "(„Erstellt von“).",
                "Der KI-Assistent ist entfernt; ein gespeicherter API-Schlüssel wird beim Start gelöscht.",
                "Rundung ändern: Runde Fläche (z. B. extrudierter Bogen) mit der Auswahl antippen – am Pfeil ziehen "
                    + "ändert den Radius, unten lassen sich Radius oder Ø eingeben. Geht auch bei Bohrungen.",
                "Fläche versetzen startet gleich mit 1 mm und Vorschau, erklärt sich in der Karte und versetzt ebene "
                    + "und runde Flächen notfalls nacheinander. Geht es nicht, nennt die Meldung den Grund und den "
                    + "größten möglichen Wert.",
                "Jedes Werkzeug zeigt beim Öffnen unten kurz, was es macht (antippen schließt). Lange drücken auf "
                    + "eine Werkzeugkachel zeigt die Erklärung erneut.",
                "Konstruieren › Ebene auf einer Körperfläche startet mit Abstand 0 – direkt auf der Fläche. Versatz "
                    + "nur, wenn du ihn eingibst.",
                "Neue Skizze mit gewähltem Körper: einfach eine ebene Fläche des Körpers antippen – die Ansicht "
                    + "bleibt stehen, Körperflächen gehen vor den Standardebenen.",
                "Schlanke Maße: kleinere Schilder mit dünnem Schloss. Feste (grüne) Maße erscheinen nur als kleines "
                    + "Schloss – antippen öffnet das Maß. Abschalten in der Skizzenpalette („Feste Maße als Schloss“).",
                "Parametrischer Verlauf: Zeitleiste unten (Menü … › Zeitleiste ein-/ausblenden). Schritt antippen ändert "
                    + "Abstand, Radius, Winkel … (auch als Formel mit Variablen), unterdrückt oder löscht ihn – die "
                    + "folgenden Schritte werden neu berechnet. Ebenso nach dem Bearbeiten einer Skizze und beim Ändern "
                    + "von Variablen. Rot = beim Nachbau fehlgeschlagen und übersprungen. Import und ähnliche "
                    + "direkte Änderungen bleiben als fester Stand stehen.",
                "Formeln in Skizzenmaßen rechnen in der Projekteinheit („10“ im Zollprojekt = 10 in, „10 mm“ bleibt "
                    + "10 mm); Winkel an der Ecke kippen beim Nachrechnen nicht mehr.",
                "Maß ändern bewegt nur die gewählte Form: Beim Radius gleiten die Bogenenden auf den angrenzenden "
                    + "Linien, der Rest der Kontur bleibt stehen. Erst wenn das nicht reicht, gehen Nachbarn mit (Hinweis).",
                "Gemerkte Mitten antippen statt Lasso, Sweep nimmt Bereich und Kante, skalierte Komponente wird "
                    + "eigenständig, Zeichnungsansichten rechnen im Hintergrund.",
                "Skizze: Bemaßte Formen bleiben starr – ist alles bemaßt, verschiebt Ziehen nur noch das ganze Teil. "
                    + "Bögen klappen nicht mehr um, und ein Maß, das die Form zusammenklappen würde, wird abgelehnt.",
                "Winkel an der Ecke (z. B. 27° statt 153°) mit Schloss. Jedes änderbare Maß hat ein Schloss: rot antippen "
                    + "legt den aktuellen Wert fest. Die Schilder „•“ und Schloss an den Ecken sind weg.",
                "Bogen per Finger und Knopf „Bogen“ setzen wieder am Linienende an. Ein Bogenstrich zwischen zwei "
                    + "Linienenden schließt tangential (bei parallelen Linien als Halbkreis) – Radius danach am Maß ändern.",
                "Spline von einer Linie zur anderen ist sofort fertig, die geschlossene Fläche erscheint gleich. "
                    + "Spline › Freihand glättet einen Stiftstrich, Spline › Punkt einfügen setzt einen neuen Punkt.",
                "Auswählen: Rahmen oder Lasso (lange drücken auf „Auswählen“ bzw. „Rahmenauswahl“), jetzt auch in der Skizze.",
                "Einheiten mm, cm oder Zoll in Ebenen › Dokumenteinstellungen. Das Raster wird beim Herauszoomen gröber, "
                    + "der Fang bleibt beim gewählten Wert.",
                "Bild › Maßstab (zwei Punkte, echtes Maß) und Bild › Kontur erkennen (Umrisse werden zur Skizze).",
                "Einfügen › Normteile (Schrauben, Muttern, Scheiben M2–M10, Kugellager) und Vorlagen (Gehäuse mit Deckel, "
                    + "Stirnrad).",
                "Dünn extrudieren (Wand innen, mittig, außen), variable Rundung (Anfangs- und Endradius), Verjüngung "
                    + "(Entformungsschräge), Helix für Federn und Gewinde, Sweep entlang Körperkanten.",
                "Anzeigemodi „Verdeckte Kanten“ (gestrichelt) und „Zebra“ (Lichtstreifen für glatte Übergänge).",
                "Zeichnung erstellen (Menü …): Vorder-, Drauf-, Seitenansicht und Isometrie mit Gesamtmaßen und "
                    + "Schriftfeld, als PDF oder DXF.",
                "Komponenten: „Als Komponente“ im Ebenen-Browser – Kopien bleiben verknüpft, ändert man eine, ändern "
                    + "sich alle. „Verknüpfung lösen“ macht eine Kopie eigenständig.",
                "Frischere Oberfläche: feine Ränder, weichere Schatten, Knöpfe geben beim Drücken nach.",
                "Loft › Führung hinzufügen: eine Skizzenkurve führt die Querschnitte (eine zweite steuert die "
                    + "Verdrehung). Ohne Führung lässt „Start/Ende tangential“ den Loft senkrecht zur Skizzenebene "
                    + "aus- bzw. einlaufen.",
                "Spline-Tangenten: Fit-Spline im Pfeil-Werkzeug wählen, an den Griffen der Punkte ziehen ändert "
                    + "Richtung und Stärke (orange = eigene Tangente). Griff antippen stellt die automatische wieder her.",
                "Material (lange drücken auf einen Körper im Ebenen-Browser): PLA, PETG, ABS, TPU, Aluminium, Stahl, "
                    + "Messing, Holz … – Messen und Druckprüfung zeigen das Gewicht im Material, Metalle glänzen.",
            ]
        }
    }
}

struct HelpSheet: View {
    let topic: HelpTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(topic.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .padding(.vertical, 4)
            }
            .navigationTitle(topic.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
