import SwiftUI

/// Gruppen der linken Werkzeugleiste im 3D-Modus (Kai: kleinere, eindeutige Gruppen statt weniger großer Menüs).
/// Reihenfolge wie der Arbeitsablauf: zeichnen, Körper erzeugen, bearbeiten, kombinieren, bewegen, prüfen.
/// Schnittansicht, Isolieren und Löschen liegen als direkte Knöpfe in der rechten Leiste.
enum ToolGroup: String, CaseIterable, Identifiable {
    case sketch = "Skizze"
    case extrude = "Extrudieren"
    case shapes = "Formen"
    case fillets = "Abrundungen"
    case holes = "Löcher"
    case faces = "Flächen"
    case combine = "Kombinieren"
    case move = "Verschieben"
    case pattern = "Vervielfältigen"
    case construct = "Konstruieren"
    case inspect = "Prüfen"
    case insert = "Einfügen"
    case visualize = "Ansicht"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .sketch: "sc.sketch"
        case .extrude: "sc.extrude"
        case .shapes: "sc.box"
        case .fillets: "sc.fillet"
        case .holes: "sc.hole"
        case .faces: "sc.presspull"
        case .combine: "sc.combine"
        case .move: "sc.move"
        case .pattern: "sc.pattern"
        case .construct: "sc.plane"
        case .inspect: "sc.measure"
        case .insert: "sc.import"
        case .visualize: "sc.appearance"
        }
    }

    /// Farbfamilie: Erzeugen blau, Ändern orange, Bewegen violett
    var category: ToolCategory {
        switch self {
        case .sketch, .extrude, .shapes: .create
        case .holes: .hole
        case .fillets, .faces: .modify
        case .combine: .combine
        case .move: .arrange
        case .pattern: .pattern
        case .construct: .construct
        case .inspect: .inspect
        case .insert: .insert
        case .visualize: .view
        }
    }

    /// Erklärung im Schild (eigene Texte, weil manche Namen auch in der Skizze vorkommen)
    var tip: String {
        switch self {
        case .sketch: "Neue Skizze beginnen: Ebene oder ebene Körperfläche antippen, dann mit dem Stift zeichnen."
        case .extrude: "Extrudieren (Bereich oder ebene Fläche am Pfeil ziehen) und Dünn extrudieren (Linien als Wand)."
        case .shapes: "Körper aus Skizzen formen – Achsendrehung, Sweep, Loft, Helix – oder Grundkörper wie Quader, Zylinder und Kugel einfügen."
        case .fillets: "Kanten abrunden oder fasen."
        case .holes: "Bohrung mit Senkung oder Senkkopf, Gewindebohrung und Gewinde an Bolzen, Bohrungen oder jeder Fläche."
        case .faces: "Flächen versetzen, ersetzen oder neigen, Körper aushöhlen, Kanten versetzen oder abdrücken, Umhüllen und Prägen."
        case .combine: "Körper vereinigen, abziehen, schneiden oder teilen, Negativform um einen Körper."
        case .move: "Körper oder Skizzen verschieben, drehen, kopieren, von Punkt zu Punkt übersetzen, ausrichten oder skalieren."
        case .pattern: "Körper spiegeln oder als Muster in Reihe bzw. im Kreis vervielfältigen."
        case .construct: "Hilfsebenen, -achsen und -punkte, z. B. eine versetzte Ebene zum Skizzieren."
        case .inspect: "Messen und Druckprüfung (Überhang, dünne Wände). Schnittansicht und Isolieren liegen rechts."
        case .insert: "Normteile (Schrauben, Muttern, Lager), Vorlagen (Gehäuse, Stirnrad), STEP-, STL- und 3MF-Dateien, Bild als Vorlage (aus Fotos, Dateien oder direkt mit der Kamera), Körper eines anderen Projekts, eine Variable, Netze bearbeiten."
        case .visualize: "Anzeigemodus, orthografische Projektion, Körperfarbe und Zeichnung."
        }
    }

    /// Skizze ist eine direkte Aktion ohne Untermenü; jede andere Kachel öffnet ihre Werkzeuge.
    var hasFlyout: Bool { self != .sketch }
}

/// Werkzeugkategorien wie die Abschnitte der Fusion-360-Werkzeugleiste – jede mit eigener Symbolfarbe.
enum ToolCategory: String {
    case neutral = ""
    case finish = "Fertig"
    case create = "Erstellen"
    case hole = "Löcher"
    case modify = "Ändern"
    case combine = "Kombinieren"
    case arrange = "Verschieben"
    case pattern = "Vervielfältigen"
    case construct = "Konstruieren"
    case inspect = "Prüfen"
    case insert = "Einfügen"
    case view = "Ansicht"
    // Skizzenmodus nach SolidCraft (Create / Modify / Pattern / Constrain / Reference / Inspect)
    case sketchPattern = "Muster"
    case constrain = "Bedingen"
    case reference = "Referenz"

    /// Symbolfarbe (inaktiv) und Füllung (aktiv)
    var color: Color {
        switch self {
        case .neutral: .primary
        case .finish: Color(red: 0.16, green: 0.62, blue: 0.30)
        case .create: Color(red: 0.10, green: 0.45, blue: 0.86)
        case .hole: Color(red: 0.02, green: 0.60, blue: 0.88)
        case .modify: Color(red: 0.92, green: 0.50, blue: 0.08)
        case .combine: Color(red: 0.86, green: 0.33, blue: 0.20)
        case .arrange: Color(red: 0.43, green: 0.35, blue: 0.86)
        case .pattern: Color(red: 0.68, green: 0.32, blue: 0.78)
        case .construct: Color(red: 0.80, green: 0.56, blue: 0.0)
        case .inspect: Color(red: 0.0, green: 0.56, blue: 0.60)
        case .insert, .view: Color(red: 0.38, green: 0.44, blue: 0.53)
        case .sketchPattern: Color(red: 0.68, green: 0.32, blue: 0.78)
        // SolidCraft-Akzent der Bedingungen #C16358 bzw. der projizierten Geometrie #963CBE
        case .constrain: Color(red: 0.76, green: 0.39, blue: 0.35)
        case .reference: Color(red: 0.59, green: 0.24, blue: 0.75)
        }
    }

    var fill: Color { self == .neutral ? .accentColor : color }
}

/// Eintrag in einem Untermenü der Werkzeugleiste.
struct ToolItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    var isEnabled = true
    var isActive = false
    var action: () -> Void = {}
}

/// Kachelgröße und Abstand der Werkzeuggruppen im 3D-Modus.
private struct GroupSize: Equatable {
    let tile: CGFloat
    let gap: CGFloat

    /// Von groß nach klein; die Leiste nimmt die erste, die in die Höhe passt.
    static let sizes: [GroupSize] = [
        GroupSize(tile: 52, gap: 10),
        GroupSize(tile: 46, gap: 8),
        GroupSize(tile: 42, gap: 6),
        GroupSize(tile: 38, gap: 5),
    ]
}

/// Eintrag der linken Leiste im Skizzen- und Kontextmodus: Aktion oder Untermenü.
private struct RailEntry: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    /// Farbe und Abschnitt (Überschrift erscheint, wenn die Kategorie wechselt)
    var category: ToolCategory = .neutral
    var isActive = false
    /// Ausgegraut und nicht antippbar (z. B. „Löschen“ ohne Auswahl)
    var isEnabled = true
    var flyout: [ToolItem]?
    /// Bei Werkzeugen mit Varianten: Antippen startet das Werkzeug (zuletzt gewählte Variante),
    /// langes Drücken öffnet die Varianten. Ohne primary öffnet Antippen das Untermenü (Gruppen wie „Mehr“).
    var primary: (() -> Void)?
    var action: () -> Void = {}
    /// Statt einer Kachel ein Raster aus Bildknöpfen in zwei Spalten (Bedingungen wie im SolidCraft-Mockup)
    var grid: [RailGridCell]?
}

/// Knopf im Raster der linken Leiste (Bedingung): passend = farbig, wartend = getönt mit Rahmen.
private struct RailGridCell: Identifiable {
    let id: String
    let title: String
    let icon: String
    var detail: String?
    var isApplicable = false
    var isPending = false
    var action: () -> Void = {}
}

/// Linke Werkzeugleiste (Aufbau wie bei Shapr3D, Symbole und Abschnitte wie Fusion 360):
/// im Skizzenmodus die Skizzenwerkzeuge, mit Auswahl die passenden Aktionen, sonst die Werkzeuggruppen.
struct ToolRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    @Binding var openGroup: ToolGroup?
    let importSTEP: () -> Void

    @State private var openEntry: String?
    /// Zuletzt gewählte Variante unter „Schneiden“ (Antippen startet sie wieder)
    @State private var cutTool: SketchTool = .trim
    /// Zugeklappte Abschnitte im Skizzenmodus. „Ändern“ ist anfangs offen (Kai fand „Beschneiden“ im zugeklappten
    /// Abschnitt nicht), „Prüfen“ zu, „Erstellen“ immer offen.
    @State private var collapsedSections: Set<ToolCategory> = [.inspect]
    /// Auswahl ins Leere gezogen: Lasso statt Rahmen (lange drücken auf „Auswählen“)
    @AppStorage(LassoSelection.key) private var lassoSelects = false

    private let headerHeight: CGFloat = 18
    /// Kachelgröße der Werkzeuggruppen: die größte, mit der alle Gruppen in die Höhe passen
    /// (iPad 11"/13", hoch und quer); die gewählte merkt sich die Leiste für die Lage des Untermenüs.
    @State private var groupSize = GroupSize.sizes[0]
    /// Gemessene Breite der Gruppenleiste (Kacheln + Beschriftung), Ankerpunkt des Untermenüs
    @State private var railWidth: CGFloat = 0
    /// Platz unten links für Rückgängig/Wiederholen
    private let bottomReserve: CGFloat = 70

    var body: some View {
        if sketch.isActive {
            entryRail(sketchEntries, tile: 44, header: sketchHeader, collapsible: true)
        } else if showsContext {
            entryRail(contextEntries, tile: 44, header: nil)
        } else {
            modelTools
        }
    }

    // MARK: Leiste mit Einträgen

    /// Abschnittsüberschrift vor dem Eintrag, wenn dort eine neue Kategorie beginnt.
    private func sectionStart(_ entries: [RailEntry], _ index: Int) -> ToolCategory? {
        let category = entries[index].category
        guard category != .neutral, category != .finish else { return nil }
        return index == 0 || entries[index - 1].category != category ? category : nil
    }

    /// Eintrag ausgeblendet, weil sein Abschnitt zugeklappt ist (das aktive Werkzeug bleibt sichtbar).
    private func isHidden(_ entry: RailEntry, collapsible: Bool) -> Bool {
        collapsible && collapsedSections.contains(entry.category) && !entry.isActive && openEntry != entry.id
    }

    private func entryRail(_ entries: [RailEntry], tile: CGFloat, header: String?, collapsible: Bool = false) -> some View {
        let gap: CGFloat = 6
        let list = VStack(alignment: .leading, spacing: gap) {
            if let header {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .floatingSurface(.regularMaterial, in: Capsule(), elevation: .flat)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if let section = sectionStart(entries, index) {
                    if collapsible, section != .create {
                        SectionHeader(category: section, isCollapsed: collapsedSections.contains(section))
                            .frame(height: headerHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if collapsedSections.contains(section) {
                                    collapsedSections.remove(section)
                                } else {
                                    collapsedSections.insert(section)
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .hoverTip(collapsedSections.contains(section) ? "Aufklappen" : "Zuklappen")
                    } else {
                        SectionHeader(category: section)
                            .frame(height: headerHeight)
                    }
                }
                if !isHidden(entry, collapsible: collapsible), let cells = entry.grid {
                    RailGrid(cells: cells, size: tile, isEnabled: entry.isEnabled)
                } else if !isHidden(entry, collapsible: collapsible) {
                RailTile(title: entry.title, subtitle: entry.subtitle, systemImage: entry.systemImage,
                         category: entry.category, isActive: entry.isActive, isOpen: openEntry == entry.id,
                         size: tile, hasVariants: entry.flyout != nil && entry.primary != nil)
                    .onTapGesture {
                        if let primary = entry.primary {
                            openEntry = nil
                            primary()
                        } else if entry.flyout != nil {
                            openEntry = openEntry == entry.id ? nil : entry.id
                        } else {
                            openEntry = nil
                            entry.action()
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        guard entry.flyout != nil else {
                            // Ohne Varianten: kurze Erklärung als Kapsel unten
                            if let text = ToolTips.detail(for: entry.title) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                workspace.explain(ToolExplanation(title: entry.title, text: text))
                            }
                            return
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openEntry = entry.id
                    }
                    .allowsHitTesting(entry.isEnabled)
                    .opacity(entry.isEnabled ? 1 : 0.45)
                    .accessibilityAddTraits(.isButton)
                    .hoverTip(entry.title, entry.primary == nil ? nil
                              : (ToolTips.detail(for: entry.title).map { $0 + " " } ?? "") + "Lange drücken: alle Varianten.")
                }
            }
        }
        return HStack(alignment: .top, spacing: 12) {
            ViewThatFits(in: .vertical) {
                list
                ScrollView(showsIndicators: false) { list }
            }
            if let openEntry, let index = entries.firstIndex(where: { $0.id == openEntry }),
               let items = entries[index].flyout {
                let sections = (0...index).filter { sectionStart(entries, $0) != nil }.count
                let heightAbove = (0..<index).filter { !isHidden(entries[$0], collapsible: collapsible) }
                    .reduce(CGFloat(0)) { sum, k in sum + entryHeight(entries[k], tile: tile) + gap }
                Flyout(title: entries[index].title, category: entries[index].category, items: items) {
                    self.openEntry = nil
                }
                .padding(.top, heightAbove + CGFloat(sections) * (headerHeight + gap) + (header == nil ? 0 : 30))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(Theme.spring, value: openEntry)
    }

    /// Höhe eines Eintrags in der Leiste (Kachel bzw. Raster), für die Lage des Untermenüs.
    private func entryHeight(_ entry: RailEntry, tile: CGFloat) -> CGFloat {
        guard let cells = entry.grid else { return tile }
        return RailGrid.height(count: cells.count, size: tile)
    }

    // MARK: Skizzenmodus

    /// Skizzenname und Ebene (ersetzt die frühere Kachel „Aktive Ebene“)
    private var sketchHeader: String {
        let name: String
        if let index = workspace.editingSketchIndex, model.sketches.indices.contains(index) {
            name = model.sketches[index].name
        } else {
            name = "Skizze \(model.sketches.count + 1)"
        }
        return "\(name) · \(sketch.isChoosingPlane ? "Ebene wählen" : activePlaneName)"
    }

    private func toolEntry(_ tool: SketchTool, category: ToolCategory, subtitle: String? = nil) -> RailEntry {
        RailEntry(id: "sketch.\(tool.rawValue)", title: tool.rawValue, subtitle: subtitle,
                  systemImage: tool.systemImage, category: category, isActive: sketch.tool == tool, action: {
            sketch.tool = tool
        })
    }

    private func toolItem(_ tool: SketchTool, title: String? = nil, subtitle: String? = nil, icon: String? = nil,
                          isActive: Bool? = nil, then: @escaping () -> Void = {}) -> ToolItem {
        ToolItem(id: "item.\(tool.rawValue).\(title ?? "")", title: title ?? tool.rawValue,
                 subtitle: subtitle ?? tool.subtitle, systemImage: icon ?? tool.systemImage,
                 isActive: isActive ?? (sketch.tool == tool)) {
            sketch.tool = tool
            then()
        }
    }

    private static func polygonName(_ sides: Int) -> String {
        switch sides {
        case 3: "Dreieck"
        case 4: "Viereck"
        case 5: "Fünfeck"
        case 6: "Sechseck"
        case 8: "Achteck"
        default: "\(sides)-Eck"
        }
    }

    /// Name der Skizzenebene: Standardebene, sonst Fläche bzw. Konstruktionsebene.
    private var activePlaneName: String {
        guard !sketch.plane.isOnFace else { return "Fläche" }
        return BasePlane.allCases.first { $0.normal == sketch.plane.normal }?.rawValue ?? "Ebene"
    }

    private var arcItems: [ToolItem] {
        ArcMode.allCases.map { mode in
            ToolItem(id: "arc.\(mode.rawValue)", title: "Bogen", subtitle: mode.rawValue, systemImage: mode.systemImage,
                     isActive: sketch.tool == .arc && sketch.arcMode == mode) {
                sketch.tool = .arc
                sketch.arcMode = mode
            }
        }
    }

    private var circleItems: [ToolItem] {
        CircleMode.allCases.map { mode in
            ToolItem(id: "circle.\(mode.rawValue)", title: mode.rawValue, subtitle: "Kreis", systemImage: mode.systemImage,
                     isActive: sketch.tool == .circle && sketch.circleMode == mode) {
                sketch.tool = .circle
                sketch.circleMode = mode
            }
        }
    }

    private var polygonItems: [ToolItem] {
        PolygonMode.allCases.map { mode in
            ToolItem(id: "polygon.\(mode.rawValue)", title: "Radius bis \(mode.rawValue)",
                     subtitle: mode == .inscribed ? "Innen (Umkreis)" : "Außen (Inkreis)",
                     systemImage: SketchTool.polygon.systemImage,
                     isActive: sketch.tool == .polygon && sketch.polygonMode == mode) {
                sketch.tool = .polygon
                sketch.polygonMode = mode
            }
        }
    }

    private var slotItems: [ToolItem] {
        SlotMode.allCases.map { mode in
            ToolItem(id: "slot.\(mode.rawValue)", title: mode.rawValue, subtitle: "Langloch", systemImage: mode.systemImage,
                     isActive: sketch.tool == .slot && sketch.slotMode == mode) {
                sketch.tool = .slot
                sketch.slotMode = mode
            }
        }
    }

    /// Bedingungen als Raster 2 × 6 wie im SolidCraft-Mockup (`sketch.png`): erst Symbol, dann Elemente antippen;
    /// passt die Auswahl schon, wirkt die Bedingung sofort (Ablauf wie die frühere ConstraintColumn rechts).
    private var constraintCells: [RailGridCell] {
        let kinds = [ConstraintKind.lock] + ConstraintKind.allCases.filter { $0 != .lock && $0 != .dimension }
        return kinds.map { kind in
            RailGridCell(id: kind.rawValue, title: kind.rawValue, icon: kind.systemImage, detail: kind.selectionHint,
                         isApplicable: sketch.canApply(kind), isPending: sketch.pendingAction == .constraint(kind)) {
                sketch.start(.constraint(kind))
            }
        }
    }

    /// Aufteilung wie die Registerkarte SKETCH in SolidCraft: Fertig stellen, Erstellen, Ändern, Muster, Bedingen,
    /// Referenz, Prüfen. Die Eigenschaften des gewählten Werkzeugs stehen rechts in der Skizzenpalette.
    private var sketchEntries: [RailEntry] {
        let polygonSubtitle = "\(Self.polygonName(sketch.polygonSides)) · \(sketch.polygonMode.rawValue)"
        // Schneiden: Beschneiden (antippen oder wischen), Teilen an Punkt, Unterbrechen, Verlängern
        let cutTools: [SketchTool] = [.trim, .splitAtPoint, .breakCurve, .extend]
        let shownCut: SketchTool = cutTools.contains(sketch.tool) ? sketch.tool : cutTool
        // Spline: Fit-/Kontrollpunkte setzen, Freihand, Punkt einfügen
        let splineKindItems: [ToolItem] = SplineKind.allCases.map { kind -> ToolItem in
            let icon: String? = kind == .control ? "sc.spline_cv" : nil
            return toolItem(.spline, title: kind.rawValue, subtitle: "Spline", icon: icon,
                            isActive: sketch.tool == .spline && sketch.splineInput == .points && sketch.splineKind == kind) {
                sketch.splineInput = .points
                sketch.splineKind = kind
            }
        }
        let splineInputItems: [ToolItem] = [SplineInput.freehand, SplineInput.insert].map { input in
            ToolItem(id: "spline.\(input.rawValue)", title: input.rawValue,
                     subtitle: input == .freehand ? "Strich wird glatte Spline" : "Spline antippen",
                     systemImage: input.systemImage,
                     isActive: sketch.tool == .spline && sketch.splineInput == input) {
                sketch.tool = .spline
                sketch.splineInput = input
            }
        }
        let splineItems = splineKindItems + splineInputItems
        let planeReady = !sketch.isChoosingPlane
        let detachPending = sketch.pendingAction == .detach
        return [
            RailEntry(id: "sketch.finish", title: "Skizzieren beenden", systemImage: "checkmark", category: .finish, action: {
                workspace.finishSketch()
            }),
            // Pfeil: zeichnet nicht, sondern wählt, verschiebt und zieht Eck- und Endpunkte
            // Ins Leere ziehen wählt mit Rahmen bzw. Lasso (lange drücken: Variante wählen)
            RailEntry(id: "sketch.select", title: SketchTool.select.rawValue,
                      subtitle: lassoSelects ? "Lasso" : SketchTool.select.subtitle,
                      systemImage: lassoSelects ? "lasso" : SketchTool.select.systemImage, isActive: sketch.tool == .select,
                      flyout: [
                          ToolItem(id: "select.box", title: "Rahmen", subtitle: "Nach rechts umschlossen, nach links berührt",
                                   systemImage: "rectangle.dashed", isActive: sketch.tool == .select && !lassoSelects) {
                              lassoSelects = false
                              sketch.tool = .select
                          },
                          ToolItem(id: "select.lasso", title: "Lasso", subtitle: "Frei umfahren, Umschlossenes wählen",
                                   systemImage: "lasso", isActive: sketch.tool == .select && lassoSelects) {
                              lassoSelects = true
                              sketch.tool = .select
                          },
                      ], primary: { sketch.tool = .select }),
            // ERSTELLEN
            toolEntry(.polyline, category: .create),
            RailEntry(id: "sketch.rectangle", title: "Rechteck", subtitle: sketch.rectangleMode.rawValue,
                      systemImage: sketch.rectangleMode.systemImage, category: .create,
                      isActive: sketch.tool == .rectangle,
                      flyout: RectangleMode.allCases.map { mode in
                          ToolItem(id: "rect.\(mode.rawValue)", title: mode.rawValue, subtitle: "Rechteck",
                                   systemImage: mode.systemImage,
                                   isActive: sketch.tool == .rectangle && sketch.rectangleMode == mode) {
                              sketch.tool = .rectangle
                              sketch.rectangleMode = mode
                          }
                      }, primary: { sketch.tool = .rectangle }),
            RailEntry(id: "sketch.circle", title: "Kreis", subtitle: sketch.circleMode.rawValue,
                      systemImage: sketch.circleMode.systemImage, category: .create, isActive: sketch.tool == .circle,
                      flyout: circleItems, primary: { sketch.tool = .circle }),
            // Bogen als eigene Familie (Kai: „von A nach B, dann den Bogen aufziehen“)
            RailEntry(id: "sketch.arc", title: "Bogen", subtitle: sketch.arcMode.rawValue,
                      systemImage: sketch.arcMode.systemImage, category: .create, isActive: sketch.tool == .arc,
                      flyout: arcItems, primary: { sketch.tool = .arc }),
            RailEntry(id: "sketch.polygon", title: "Polygon", subtitle: polygonSubtitle,
                      systemImage: SketchTool.polygon.systemImage, category: .create, isActive: sketch.tool == .polygon,
                      flyout: polygonItems, primary: { sketch.tool = .polygon }),
            RailEntry(id: "sketch.slot", title: "Langloch", subtitle: sketch.slotMode.rawValue,
                      systemImage: sketch.slotMode.systemImage, category: .create, isActive: sketch.tool == .slot,
                      flyout: slotItems, primary: { sketch.tool = .slot }),
            RailEntry(id: "sketch.spline", title: "Spline",
                      subtitle: sketch.splineInput == .points ? sketch.splineKind.rawValue : sketch.splineInput.rawValue,
                      systemImage: sketch.splineInput.systemImage, category: .create, isActive: sketch.tool == .spline,
                      flyout: splineItems, primary: { sketch.tool = .spline }),
            toolEntry(.ellipse, category: .create),
            toolEntry(.point, category: .create),
            toolEntry(.text, category: .create),
            RailEntry(id: "sketch.construction", title: "Konstruktion", subtitle: sketch.constructionMode ? "Ein" : "Aus",
                      systemImage: "sc.construction", category: .create, isActive: sketch.constructionMode, action: {
                sketch.constructionMode.toggle()
                sketch.options.lineType = sketch.constructionMode ? .construction : .normal
            }),
            // ÄNDERN
            // Schneiden mit der Schere zuoberst: Antippen startet die zuletzt gewählte Variante, lange drücken zeigt alle
            RailEntry(id: "sketch.cut", title: "Schneiden", subtitle: shownCut.rawValue,
                      systemImage: shownCut.systemImage, category: .modify,
                      isActive: cutTools.contains(sketch.tool),
                      flyout: cutTools.map { tool in toolItem(tool) { cutTool = tool } },
                      primary: { sketch.tool = cutTool }),
            toolEntry(.offset, category: .modify),
            toolEntry(.fillet, category: .modify),
            toolEntry(.chamfer, category: .modify),
            toolEntry(.scale, category: .modify),
            RailEntry(id: "sketch.delete", title: "Löschen", subtitle: sketch.selection.isEmpty ? nil : "Auswahl",
                      systemImage: "sc.delete", category: .modify, isEnabled: !sketch.selection.isEmpty, action: {
                sketch.deleteSelection()
            }),
            // MUSTER
            toolEntry(.mirror, category: .sketchPattern),
            toolEntry(.circPattern, category: .sketchPattern),
            toolEntry(.rectPattern, category: .sketchPattern),
            // BEDINGEN: Bemaßung, dann das Raster der Bedingungen
            RailEntry(id: "sketch.dimension", title: ConstraintKind.dimension.rawValue, subtitle: "Element antippen",
                      systemImage: ConstraintKind.dimension.systemImage, category: .constrain, isEnabled: planeReady,
                      action: {
                // Maße erscheinen zur Auswahl im Viewport (Maßfeld mit Schloss)
                if sketch.pendingAction != nil { sketch.cancelPending() }
                sketch.tool = .select
                sketch.notice = ConstraintKind.dimension.selectionHint
            }),
            RailEntry(id: "sketch.constraints", title: "Bedingungen", systemImage: "sc.c_hv", category: .constrain,
                      isEnabled: planeReady, grid: constraintCells),
            RailEntry(id: "sketch.detach", title: "Trennen", subtitle: detachPending ? "Aktiv" : nil,
                      systemImage: "link.badge.plus", category: .constrain, isActive: detachPending,
                      isEnabled: planeReady, action: {
                sketch.start(.detach)
            }),
            // REFERENZ
            toolEntry(.project, category: .reference),
            // PRÜFEN
            toolEntry(.measure, category: .inspect),
            RailEntry(id: "sketch.section", title: "Schnittansicht", subtitle: workspace.sketchSection ? "Ein" : "Aus",
                      systemImage: "sc.section", category: .inspect, isActive: workspace.sketchSection, action: {
                workspace.sketchSection.toggle()
            }),
        ]
    }

    // MARK: Kontext (Auswahl im 3D-Modus)

    private var hasSelection: Bool {
        model.selection != nil || !model.selectedEdges.isEmpty || !model.selectedBodies.isEmpty
            || !model.selectedRegions.isEmpty
    }

    private var showsContext: Bool {
        workspace.tool == .select && hasSelection && !workspace.showsAllTools
    }

    private var selectionSummary: String {
        if !model.selectedRegions.isEmpty {
            return model.selectedRegions.count == 1 ? "1 Bereich" : "\(model.selectedRegions.count) Bereiche"
        }
        if !model.selectedEdges.isEmpty {
            return model.selectedEdges.count == 1 ? "1 Kante" : "\(model.selectedEdges.count) Kanten"
        }
        if model.selection != nil {
            return model.selectedFaces.count == 1 ? "1 Außenfläche" : "\(model.selectedFaces.count) Außenflächen"
        }
        return model.selectedBodies.count == 1 ? "1 Körper" : "\(model.selectedBodies.count) Körper"
    }

    /// Nach Kategorien sortiert wie die Werkzeuggruppen: Erstellen, Kombinieren, Ändern, Verschieben, Vervielfältigen,
    /// Konstruieren, Prüfen.
    private var contextEntries: [RailEntry] {
        let hasRegions = !model.selectedRegions.isEmpty
        let face = model.selection
        let planarFace = face != nil && model.faceHandle != nil
        var entries = [
            RailEntry(id: "context.clear", title: "Alle abwählen", subtitle: "(\(selectionSummary))",
                      systemImage: "xmark.circle", action: {
                model.resetSelection()
            }),
        ]
        if hasRegions, let sketchIndex = model.selectedRegions.first?.sketch, model.sketches.indices.contains(sketchIndex) {
            entries.append(RailEntry(id: "context.editSketch", title: "Skizze bearbeiten",
                                     subtitle: model.sketches[sketchIndex].name, systemImage: "pencil.line", action: {
                workspace.editSketch(sketchIndex)
            }))
        }

        // ERSTELLEN
        if hasRegions || planarFace {
            entries.append(RailEntry(id: "context.extrude", title: "Extrudieren", subtitle: "Pfeil ziehen",
                                     systemImage: ToolGroup.extrude.systemImage, category: .create, isActive: true, action: {
                model.message = "Am blauen Pfeil ziehen oder den Abstand unten eingeben."
            }))
        }
        if hasRegions {
            entries.append(RailEntry(id: "context.revolve", title: "Achsendrehung",
                                     systemImage: "sc.revolve", category: .create, action: {
                workspace.activate(.revolve)
            }))
            // Wie Shapr3D nach beendeter Skizze: Profil weiterverarbeiten oder die Skizze öffnen
            entries.append(RailEntry(id: "context.sweep", title: "Sweep",
                                     systemImage: "sc.sweep", category: .create, action: {
                workspace.activate(.sweep)
            }))
            entries.append(RailEntry(id: "context.loft", title: "Loft", systemImage: "sc.loft",
                                     category: .create, action: {
                workspace.activate(.loft)
            }))
        }
        entries.append(RailEntry(id: "context.sketch", title: "Skizze", systemImage: ToolGroup.sketch.systemImage,
                                 category: .create, action: {
            workspace.startSketch()
        }))
        if hasRegions || planarFace {
            entries.append(RailEntry(id: "context.text", title: "Text", systemImage: "sc.text", category: .create, action: {
                if let region = model.selectedRegions.first, model.sketches.indices.contains(region.sketch) {
                    workspace.startSketch(on: model.sketches[region.sketch].plane)
                } else {
                    workspace.startSketch()
                }
                sketch.tool = .text
            }))
        }

        // KOMBINIEREN
        if model.selectedBodies.count > 1 {
            entries += BooleanKind.allCases.map { kind in
                RailEntry(id: "context.\(kind.rawValue)", title: kind.rawValue,
                          subtitle: kind == .union ? "\(model.selectedBodies.count) → 1" : nil,
                          systemImage: kind.systemImage, category: .combine, action: {
                    workspace.combineSelectedBodies(kind)
                })
            }
        }

        // ÄNDERN (Flächen)
        if face != nil {
            entries.append(RailEntry(id: "context.offsetFace", title: "Fläche versetzen",
                                     subtitle: model.selectedFaces.count > 1 ? "\(model.selectedFaces.count) Flächen" : nil,
                                     systemImage: "sc.offset_face", category: .modify, action: {
                workspace.activate(.offsetFace)
            }))
        }
        if planarFace {
            entries.append(RailEntry(id: "context.replaceFace", title: "Fläche ersetzen",
                                     systemImage: "sc.replace_face", category: .modify, action: {
                workspace.activate(.replaceFace)
            }))
            entries.append(RailEntry(id: "context.offsetEdges", title: "Kante versetzen",
                                     systemImage: SketchTool.offset.systemImage, category: .modify, action: {
                workspace.activate(.offsetEdges)
            }))
        }
        if hasRegions {
            entries.append(RailEntry(id: "context.wrap", title: "Umhüllen und Prägen",
                                     systemImage: "sc.emboss", category: .modify, action: {
                workspace.activate(.wrap)
            }))
            entries.append(RailEntry(id: "context.imprint", title: "Kante abdrücken",
                                     systemImage: "sc.project_surface", category: .modify, action: {
                workspace.activate(.imprint)
            }))
        }

        // VERSCHIEBEN (mit Kopieren)
        entries.append(RailEntry(id: "context.move", title: "Verschieben/Rotieren", systemImage: "sc.move",
                                 category: .arrange, action: {
            startMove(copies: false)
        }))
        if model.selectedBody != nil, !hasRegions {
            entries.append(RailEntry(id: "context.copy", title: "Kopieren", subtitle: "Verschieben mit Kopie",
                                     systemImage: "sc.copy", category: .arrange, action: {
                startMove(copies: true)
            }))
        }
        if !model.selectedBodies.isEmpty || face != nil || !model.selectedEdges.isEmpty {
            entries.append(RailEntry(id: "context.translate", title: "Übersetzen", subtitle: "Punkt zu Punkt",
                                     systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                     category: .arrange, action: {
                workspace.activate(.translate)
            }))
        }
        if hasRegions {
            entries.append(RailEntry(id: "context.scaleSketch", title: "Skizze skalieren",
                                     systemImage: "sc.sketch_scale", category: .arrange, action: {
                workspace.activate(.scaleSketch)
            }))
        } else {
            entries.append(RailEntry(id: "context.scale", title: "Skalieren",
                                     systemImage: "sc.scale", category: .arrange, action: {
                workspace.activate(.scale)
            }))
        }

        // VERVIELFÄLTIGEN
        entries += PatternKind.allCases.map { kind in
            RailEntry(id: "context.\(kind.rawValue)", title: kind.rawValue, systemImage: kind.systemImage,
                      category: .pattern, action: {
                workspace.activate(.pattern(kind))
            })
        }

        // KONSTRUIEREN
        if planarFace {
            entries.append(RailEntry(id: "context.axis", title: "Achse senkrecht", systemImage: "sc.axis_normal_to_face",
                                     category: .construct, action: {
                workspace.createNormalAxis()
            }))
            entries.append(RailEntry(id: "context.plane", title: "Ebene Versatz", systemImage: ConstructionKind.plane.systemImage,
                                     category: .construct, action: {
                workspace.activate(.construct(.plane))
            }))
        }

        // PRÜFEN
        entries += [
            RailEntry(id: "context.measure", title: "Messen", systemImage: "sc.measure", category: .inspect, action: {
                workspace.activate(.measure)
            }),
            RailEntry(id: "context.section", title: "Schnittansicht", subtitle: workspace.section == nil ? "Aus" : "Ein",
                      systemImage: "sc.section", category: .inspect, isActive: workspace.section != nil, action: {
                workspace.activate(.section)
            }),
            RailEntry(id: "context.isolate", title: "Isolieren", subtitle: model.isIsolated ? "Ein" : "Aus",
                      systemImage: "scope", category: .inspect, isActive: model.isIsolated, action: {
                workspace.toggleIsolate()
            }),
        ]

        if hasRegions, let sketchIndex = model.selectedRegions.first?.sketch, model.sketches.indices.contains(sketchIndex) {
            entries.append(RailEntry(id: "context.hideSketch", title: "Ausblenden", systemImage: "eye.slash", action: {
                model.resetSelection()
                model.setSketchHidden(true, sketch: sketchIndex)
            }))
        }
        entries += [
            RailEntry(id: "context.more", title: "Alle Werkzeuge", systemImage: "square.grid.2x2", action: {
                workspace.showsAllTools = true
            }),
            RailEntry(id: "context.delete", title: "Löschen", systemImage: "sc.delete", action: {
                if let region = model.selectedRegions.first {
                    model.deleteSketch(region.sketch)
                } else {
                    model.deleteSelected()
                }
            }),
        ]
        return entries
    }

    // MARK: Werkzeuggruppen

    /// „Zurück“ (zur Auswahl) steht über den Gruppen
    private var showsBackTile: Bool { workspace.showsAllTools && hasSelection }

    /// Zahl der Kacheln über der Gruppe (mit „Zurück“, falls angezeigt)
    private func row(of group: ToolGroup) -> Int {
        let index = ToolGroup.allCases.firstIndex(of: group) ?? 0
        return showsBackTile ? index + 1 : index
    }

    private var modelTools: some View {
        let sizes = GroupSize.sizes
        let smallest = sizes[sizes.count - 1]
        // Größte Kachel, mit der alles in die Höhe passt; sonst kleinste Kachel und scrollen
        return ViewThatFits(in: .vertical) {
            groupColumn(sizes[0])
            groupColumn(sizes[1])
            groupColumn(sizes[2])
            groupColumn(smallest)
            ScrollView(showsIndicators: false) { groupColumn(smallest) }
        }
        // Breite der Leiste samt Beschriftungen messen: das Untermenü beginnt rechts daneben
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { railWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in railWidth = width }
            }
        }
        // Untermenü rechts neben der Leiste; es verbreitert die Leiste nicht.
        // Fester Versatz statt Ausrichtungslinie: die wurde im Overlay ignoriert, das Fenster lag
        // dann über der Leiste und links aus dem Bild (Build 134).
        .overlay(alignment: .topLeading) {
            if let openGroup {
                groupFlyout(openGroup)
                    .offset(x: railWidth + 12)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.bottom, bottomReserve)
        .animation(Theme.spring, value: openGroup)
    }

    /// Obere Gruppen: Untermenü beginnt auf Höhe der Kachel; untere: es endet dort und wächst nach oben,
    /// damit es auch bei den letzten Gruppen genug Platz hat.
    private func groupFlyout(_ group: ToolGroup) -> some View {
        let rows: Int = ToolGroup.allCases.count + (showsBackTile ? 1 : 0)
        let row: Int = self.row(of: group)
        let step: CGFloat = groupSize.tile + groupSize.gap
        let fromTop = row * 2 < rows
        let top: CGFloat = fromTop ? CGFloat(row) * step : 0
        let bottom: CGFloat = fromTop ? 0 : CGFloat(rows - 1 - row) * step
        return Flyout(title: group.rawValue, category: group.category, items: items(for: group)) {
            self.openGroup = nil
        }
        .padding(.top, top)
        .padding(.bottom, bottom)
        .frame(maxHeight: .infinity, alignment: fromTop ? .top : .bottom)
    }

    private func groupColumn(_ size: GroupSize) -> some View {
        VStack(alignment: .leading, spacing: size.gap) {
            if showsBackTile {
                Button {
                    workspace.showsAllTools = false
                } label: {
                    RailTile(title: "Zurück", subtitle: "Auswahl", systemImage: "chevron.backward", size: size.tile)
                }
                .buttonStyle(.plain)
            }
            ForEach(ToolGroup.allCases) { group in
                Button {
                    tapped(group)
                } label: {
                    RailTile(title: group.rawValue, systemImage: group.systemImage, category: group.category,
                             isActive: isActive(group), isOpen: openGroup == group, size: size.tile)
                }
                .buttonStyle(.plain)
                .hoverTip(group.rawValue, group.tip)
            }
        }
        // Nur die angezeigte Variante erscheint: ihre Größe gilt für die Lage des Untermenüs
        .onAppear { groupSize = size }
    }

    private func tapped(_ group: ToolGroup) {
        guard group.hasFlyout else {
            openGroup = nil
            workspace.startSketch()
            return
        }
        openGroup = openGroup == group ? nil : group
    }

    private func isActive(_ group: ToolGroup) -> Bool {
        switch workspace.tool {
        case .insert, .revolve, .sweep, .loft:
            return group == .shapes
        case .part(let kind):
            return group == kind.group
        case .hole:
            return group == .holes
        case .boolean, .split, .mold:
            return group == .combine
        case .shell, .offsetEdges, .offsetFace, .replaceFace, .wrap, .imprint:
            return group == .faces
        case .move, .translate, .scale, .align, .scaleSketch:
            return group == .move
        case .mirror, .pattern:
            return group == .pattern
        case .construct:
            return group == .construct
        case .measure, .printCheck:
            return group == .inspect
        case .canvas, .meshSculpt:
            return group == .insert
        case .color:
            return group == .visualize
        case .section:
            // Schnittansicht liegt in der rechten Leiste
            return false
        case .select:
            switch group {
            case .sketch: return sketch.isActive
            case .fillets: return !model.selectedEdges.isEmpty
            case .extrude: return !model.selectedRegions.isEmpty || model.faceHandle != nil
            default: return false
            }
        }
    }

    /// Wie bei Shapr3D: Skizzenbereich oder ebene Fläche antippen, dann am Pfeil ziehen.
    private func startExtrude() {
        if workspace.tool != .select {
            workspace.activate(.select)
        }
        if model.faceHandle == nil, model.selectedRegions.isEmpty {
            model.message = model.sketches.isEmpty
                ? "Erst eine Skizze mit geschlossenem Profil zeichnen, oder eine ebene Fläche antippen."
                : "Skizzenbereich oder ebene Fläche antippen, dann am blauen Pfeil ziehen."
        }
    }

    /// Verschieben ohne bzw. mit Kopie (Kai: „Kopieren kommt beim Verschieben rein“).
    private func startMove(copies: Bool) {
        workspace.activate(.move)
        // Skizzen werden nur verschoben, nie kopiert
        model.moveCopies = copies && model.movingSketch == nil
    }

    /// Bohrung ohne bzw. mit Gewinde (Schalter „Gewinde“ in der Bohrungskarte).
    private func startHole(threaded: Bool) {
        workspace.activate(.hole)
        if threaded {
            workspace.setHoleThread(workspace.holeSpec.thread ?? HoleThread())
        } else if workspace.holeSpec.thread != nil {
            workspace.setHoleThread(nil)
        }
    }

    // MARK: Einträge

    private func item(_ tool: ModelTool, _ title: String, subtitle: String? = nil, _ systemImage: String) -> ToolItem {
        ToolItem(id: "tool.\(title)", title: title, subtitle: subtitle, systemImage: systemImage,
                 isActive: workspace.tool == tool) {
            workspace.activate(tool)
        }
    }

    private func items(for group: ToolGroup) -> [ToolItem] {
        switch group {
        case .sketch:
            return []
        case .extrude:
            let extruding = workspace.tool == .select && (!model.selectedRegions.isEmpty || model.faceHandle != nil)
            return [
                ToolItem(id: "extrude.extrude", title: "Extrudieren", subtitle: "Bereich oder Fläche, Pfeil ziehen",
                         systemImage: "sc.extrude", isActive: extruding) {
                    startExtrude()
                },
                item(.part(.thinLines), "Dünn extrudieren", subtitle: "Linien als Wand", PartTool.thinLines.systemImage),
            ]
        case .shapes:
            var items: [ToolItem] = [
                item(.revolve, "Achsendrehung", subtitle: "Bereich um Achse", "sc.revolve"),
                item(.sweep, "Sweep", subtitle: "Bereich entlang Pfad", "sc.sweep"),
                item(.loft, "Loft", subtitle: "Durch Querschnitte", "sc.loft"),
                item(.part(.helix), "Helix", subtitle: "Feder, Spirale", PartTool.helix.systemImage),
            ]
            items += Primitive.allCases.map { primitive in
                item(.insert(primitive), primitive.rawValue, subtitle: "Grundkörper", primitive.systemImage)
            }
            return items
        case .fillets:
            return EdgeOperation.allCases.map { operation in
                ToolItem(id: "tools.\(operation.rawValue)", title: operation.rawValue, subtitle: "Kanten",
                         systemImage: operation == .fillet ? "sc.fillet" : "sc.chamfer",
                         isActive: workspace.tool == .select && !model.selectedEdges.isEmpty
                             && model.edgeOperation == operation) {
                    workspace.startEdgeOperation(operation)
                }
            }
        case .holes:
            let drilling = workspace.tool == .hole
            let threaded = workspace.holeSpec.thread != nil
            return [
                ToolItem(id: "holes.hole", title: "Bohrung", subtitle: "Senkung, Senkkopf, Einsätze",
                         systemImage: "sc.hole", isActive: drilling && !threaded) {
                    startHole(threaded: false)
                },
                ToolItem(id: "holes.tapped", title: "Gewindebohrung", subtitle: "Kernloch mit Gewinde",
                         systemImage: "sc.hole", isActive: drilling && threaded) {
                    startHole(threaded: true)
                },
                item(.part(.thread), "Gewinde", subtitle: "Bolzen, Bohrung, jede Fläche", PartTool.thread.systemImage),
            ]
        case .faces:
            return [
                item(.offsetFace, "Fläche versetzen", subtitle: "Auch Bohrungen", "sc.offset_face"),
                item(.replaceFace, "Fläche ersetzen", subtitle: "Bis Zielfläche", "sc.replace_face"),
                item(.part(.draft), "Verjüngung", subtitle: "Flächen neigen", PartTool.draft.systemImage),
                item(.shell, "Schale", subtitle: "Fläche öffnen", "sc.shell"),
                item(.offsetEdges, "Kante versetzen", subtitle: "Fläche antippen", SketchTool.offset.systemImage),
                item(.imprint, "Kante abdrücken", subtitle: "Skizze auf Fläche", "sc.project_surface"),
                item(.wrap, "Umhüllen und Prägen", subtitle: "Auf Zylinder", "sc.emboss"),
            ]
        case .combine:
            var items: [ToolItem] = BooleanKind.allCases.map { kind in
                item(.boolean(kind), kind.rawValue, subtitle: "Körper", kind.systemImage)
            }
            items.append(item(.split, "Körper teilen", subtitle: "Ebene, Körper, Skizze", "sc.split_body"))
            items.append(item(.mold, "Negativform", subtitle: "Form aus Block", "cube.transparent"))
            return items
        case .move:
            let moving = workspace.tool == .move
            return [
                ToolItem(id: "move.move", title: "Verschieben/Rotieren", subtitle: "Körper oder Skizze",
                         systemImage: "sc.move", isActive: moving && !model.moveCopies) {
                    startMove(copies: false)
                },
                ToolItem(id: "move.copy", title: "Kopieren", subtitle: "Verschieben mit Kopie",
                         systemImage: "sc.copy", isActive: moving && model.moveCopies) {
                    startMove(copies: true)
                },
                item(.translate, "Übersetzen", subtitle: "Punkt zu Punkt", "point.topleft.down.to.point.bottomright.curvepath"),
                item(.align, "Ausrichten", subtitle: "Körper", "sc.align"),
                item(.scale, "Skalieren", subtitle: "Körper", "sc.scale"),
                item(.scaleSketch, "Skizze skalieren", subtitle: "Bereich antippen", "sc.sketch_scale"),
            ]
        case .pattern:
            return [
                item(.mirror, "Spiegeln", subtitle: "Körper", "sc.mirror"),
                item(.pattern(.linear), "Muster linear", subtitle: "Körper in Reihe", PatternKind.linear.systemImage),
                item(.pattern(.circular), "Muster kreisförmig", subtitle: "Körper im Kreis", PatternKind.circular.systemImage),
            ]
        case .construct:
            return ConstructionKind.allCases.map { kind in
                item(.construct(kind), kind.rawValue, subtitle: "Konstruktion", kind.systemImage)
            }
        case .inspect:
            return [
                item(.measure, "Messen", subtitle: "Länge, Fläche, Abstand", "sc.measure"),
                item(.printCheck, "Druckprüfung", subtitle: "Überhang, Wände", "printer"),
            ]
        case .insert:
            return [
                item(.part(.standard), "Normteile", subtitle: "Schrauben, Muttern, Lager", PartTool.standard.systemImage),
                item(.part(.template), "Vorlagen", subtitle: "Gehäuse, Stirnrad", PartTool.template.systemImage),
                ToolItem(id: "insert.step", title: "STEP-Datei", subtitle: ".step / .stp",
                         systemImage: "sc.import", action: importSTEP),
                ToolItem(id: "insert.mesh", title: "STL / 3MF", subtitle: "Netz als Körper (3D-Druck)",
                         systemImage: "triangle", action: importSTEP),
                ToolItem(id: "insert.vector", title: "SVG / DXF", subtitle: "Als Skizze (Laser, CNC, Logos)",
                         systemImage: "sc.svg", action: importSTEP),
                item(.meshSculpt, "Netz bearbeiten", subtitle: "Pinsel, STL/3MF", "paintbrush.pointed"),
                // Bild als Vorlage aus drei Quellen; danach gleich kalibrieren (WorkspaceView.insertImage)
                ToolItem(id: "insert.image", title: "Bild aus Fotos", subtitle: "Fotoalbum, als Vorlage",
                         systemImage: "sc.canvas") {
                    workspace.isPickingImage = true
                },
                ToolItem(id: "insert.imageFile", title: "Bild aus Dateien", subtitle: "PNG, JPEG, HEIC, PDF",
                         systemImage: "folder") {
                    workspace.isImportingImageFile = true
                },
                ToolItem(id: "insert.camera", title: "Foto aufnehmen",
                         subtitle: CameraCapture.isAvailable ? "Kamera, als Vorlage" : "Keine Kamera verfügbar",
                         systemImage: "camera", isEnabled: CameraCapture.isAvailable) {
                    workspace.isTakingPhoto = true
                },
                ToolItem(id: "insert.project", title: "Projekt", subtitle: "Körper eines anderen Projekts",
                         systemImage: "folder.badge.plus") {
                    workspace.showsProjectPicker = true
                },
                ToolItem(id: "insert.variable", title: "Variable", subtitle: model.variables.isEmpty ? "Name = Wert"
                             : "\(model.variables.count) im Projekt", systemImage: "sc.params") {
                    workspace.showsVariables = true
                },
            ]
        case .visualize:
            var items = DisplayMode.allCases.map { mode in
                ToolItem(id: "visualize.\(mode.rawValue)", title: mode.rawValue, systemImage: mode.systemImage,
                         isActive: workspace.displayMode == mode) {
                    workspace.displayMode = mode
                }
            }
            items.append(ToolItem(id: "visualize.ortho", title: "Orthografisch", subtitle: "Projektion",
                                  systemImage: "cube.transparent", isActive: workspace.isOrthographic) {
                workspace.isOrthographic.toggle()
            })
            items.append(item(.color, "Farbe", subtitle: "Körper", "sc.appearance"))
            items.append(ToolItem(id: "visualize.drawing", title: "Zeichnung", subtitle: "PDF, DXF",
                                  systemImage: "doc.richtext") {
                workspace.showsDrawing = true
            })
            return items
        }
    }
}

/// Abschnittsüberschrift der Leiste (ERSTELLEN, ÄNDERN …) mit Kategoriefarbe.
private struct SectionHeader: View {
    let category: ToolCategory
    /// nil = nicht aufklappbar; sonst Pfeil nach rechts (zu) bzw. unten (offen)
    var isCollapsed: Bool?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(category.color)
                .frame(width: 6, height: 6)
            Text(category.rawValue.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(category.color)
            if let isCollapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(category.color)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .floatingSurface(.regularMaterial, in: Capsule(), elevation: .flat)
    }
}

/// Kachel der Werkzeugleiste mit Beschriftung daneben.
/// SF Symbols zweifarbig in der Kategoriefarbe (wie die Werkzeugsymbole in Fusion 360), aktiv farbig gefüllt;
/// mehrfarbige SolidCraft-Bilder („sc.“) aktiv auf hellem Grund in Kategoriefarbe mit Rahmen, damit sie lesbar bleiben.
struct RailTile: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var category: ToolCategory = .neutral
    var isActive = false
    var isOpen = false
    var size: CGFloat = 52
    /// Kleines Dreieck unten rechts: lange drücken zeigt weitere Varianten (wie Shapr3D/Fusion 360)
    var hasVariants = false

    private var isCustom: Bool { ToolIcon.isCustom(systemImage) }

    /// Vollfarbe mit weißem Symbol: aktives SF Symbol bzw. „Skizzieren beenden“ (wie in Fusion 360 immer ein grüner Haken)
    private var filled: Bool { category == .finish || (isActive && !isCustom) }

    /// Aktives SolidCraft-Bild: heller Grund in Kategoriefarbe und kräftiger Rahmen
    private var tinted: Bool { isActive && isCustom && category != .finish }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.27, style: .continuous) }

    var body: some View {
        HStack(spacing: 8) {
            tile
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.labelFont)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .floatingSurface(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous),
                             elevation: .flat)
        }
        .contentShape(Rectangle())
        .animation(Theme.snappy, value: isActive)
    }

    private var tile: some View {
        glyph
            .frame(width: size, height: size)
            .background { tileBackground }
            .overlay(alignment: .bottomTrailing) { variantMark }
            .overlay { border }
            .tileShadow(filled || tinted ? category.fill : nil)
    }

    @ViewBuilder private var glyph: some View {
        if isCustom {
            ToolIcon(systemImage, size: size * 0.62)
        } else {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.4, weight: category == .finish ? .bold : .medium))
                .foregroundStyle(filled ? Color.white : category.color)
        }
    }

    @ViewBuilder private var tileBackground: some View {
        if filled {
            shape.fill(LinearGradient(colors: [category.fill.opacity(0.82), category.fill],
                                      startPoint: .top, endPoint: .bottom))
        } else if tinted {
            shape.fill(Color(.systemBackground))
                .overlay(shape.fill(category.fill.opacity(0.22)))
        } else {
            shape.fill(Color(.systemBackground))
                .overlay(shape.fill(LinearGradient(colors: [category.color.opacity(0.0), category.color.opacity(0.10)],
                                                   startPoint: .top, endPoint: .bottom)))
        }
    }

    @ViewBuilder private var variantMark: some View {
        if hasVariants {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 6, weight: .bold))
                .rotationEffect(.degrees(-45))
                .foregroundStyle(filled ? Color.white.opacity(0.85) : category.color.opacity(0.8))
                .padding(5)
        }
    }

    @ViewBuilder private var border: some View {
        if isOpen || tinted {
            shape.strokeBorder(category.fill, lineWidth: 2)
        } else if !filled, category != .neutral {
            shape.strokeBorder(category.color.opacity(0.18), lineWidth: 1)
        } else if !filled {
            shape.strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
        }
    }
}

/// Raster aus Bildknöpfen in zwei Spalten auf gemeinsamem Grund (Bedingungen im Skizzenmodus).
private struct RailGrid: View {
    let cells: [RailGridCell]
    let size: CGFloat
    var isEnabled = true

    static let spacing: CGFloat = 4

    /// Höhe für count Knöpfe in zwei Spalten (mit Innenabstand)
    static func height(count: Int, size: CGFloat) -> CGFloat {
        let rows = CGFloat((count + 1) / 2)
        return rows * size + max(0, rows - 1) * spacing + 2 * spacing
    }

    var body: some View {
        let columns = [GridItem(.fixed(size), spacing: Self.spacing), GridItem(.fixed(size), spacing: Self.spacing)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
            ForEach(cells) { cell in
                Button(action: cell.action) {
                    RailGridIcon(cell: cell, size: size, isEnabled: isEnabled)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(cell.title)
                .accessibilityAddTraits(cell.isPending ? .isSelected : [])
                .hoverTip(cell.title, cell.detail)
            }
        }
        .padding(Self.spacing)
        .floatingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
        .disabled(!isEnabled)
    }
}

/// Symbol im Raster: passend farbig, sonst grau und blass; wartend getönt mit Rahmen.
private struct RailGridIcon: View {
    let cell: RailGridCell
    let size: CGFloat
    let isEnabled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous)
        let active = isEnabled && (cell.isApplicable || cell.isPending)
        glyph(active: active)
            .frame(width: size, height: size)
            .background(cell.isPending ? Color.accentColor.opacity(0.22) : Color.clear, in: shape)
            .overlay {
                if cell.isPending {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(shape)
    }

    @ViewBuilder private func glyph(active: Bool) -> some View {
        if ToolIcon.isCustom(cell.icon) {
            ToolIcon(cell.icon, size: size * 0.58)
                .saturation(active ? 1 : 0)
                .opacity(active ? 1 : (isEnabled ? 0.55 : 0.3))
        } else {
            Image(systemName: cell.icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.6 : 0.3))
        }
    }
}

/// Untermenü einer Werkzeuggruppe.
private struct Flyout: View {
    let title: String
    var category: ToolCategory = .neutral
    let items: [ToolItem]
    let close: () -> Void

    var body: some View {
        // Lange Listen scrollen, wenn sie nicht auf den Bildschirm passen.
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .frame(width: 240)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(alignment: .top) {
            // Farbstreifen der Kategorie oben
            UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.panel, topTrailingRadius: Theme.Radius.panel, style: .continuous)
                .fill(category.fill)
                .frame(height: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .hairlineBorder(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .elevationShadow(.floating)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(category == .neutral ? Color.secondary : category.color)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
            ForEach(items) { item in
                Button {
                    item.action()
                    close()
                } label: {
                    HStack(spacing: 12) {
                        itemIcon(item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
                .hoverTip(item.title, ToolTips.detail(for: item.title) ?? item.subtitle)
            }
        }
        .padding(10)
    }

    /// Symbol eines Eintrags: SF Symbol aktiv weiß auf Vollfarbe; SolidCraft-Bild aktiv auf hellem Grund mit Rahmen.
    @ViewBuilder private func itemIcon(_ item: ToolItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous)
        let idle: Color = category.color.opacity(category == .neutral ? 0.06 : 0.1)
        if ToolIcon.isCustom(item.systemImage) {
            ToolIcon(item.systemImage, size: 26)
                .frame(width: 36, height: 36)
                .background(item.isActive ? category.fill.opacity(0.22) : idle, in: shape)
                .overlay {
                    if item.isActive {
                        shape.strokeBorder(category.fill, lineWidth: 2)
                    }
                }
        } else {
            Image(systemName: item.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(item.isActive ? Color.white : category.color)
                .background(item.isActive ? category.fill : idle, in: shape)
        }
    }
}
