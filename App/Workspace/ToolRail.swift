import SwiftUI

/// Gruppen der linken Werkzeugleiste im 3D-Modus nach dem SolidCraft-Ribbon (B.1): Skizze · Erstellen · Ändern ·
/// Anordnen · Konstruieren · Prüfen · Einfügen · Ansicht. Inhalt der Gruppen: ModelRibbon.swift.
/// Schnittansicht, Isolieren und Löschen liegen zusätzlich als direkte Knöpfe in der rechten Leiste.
enum ToolGroup: String, CaseIterable, Identifiable {
    case sketch = "Skizze"
    case create = "Erstellen"
    case modify = "Ändern"
    case arrange = "Anordnen"
    case construct = "Konstruieren"
    case inspect = "Prüfen"
    case insert = "Einfügen"
    case visualize = "Ansicht"

    // Frühere Gruppen (PartTools, Befehlssuche, Karten): zeigen auf die neue Gruppe
    static let extrude = ToolGroup.create
    static let shapes = ToolGroup.create
    static let holes = ToolGroup.create
    static let fillets = ToolGroup.modify
    static let faces = ToolGroup.modify
    static let combine = ToolGroup.modify
    static let move = ToolGroup.arrange
    static let pattern = ToolGroup.arrange

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .sketch: "sc.sketch"
        case .create: "sc.extrude"
        case .modify: "sc.fillet"
        case .arrange: "sc.move"
        case .construct: "sc.plane"
        case .inspect: "sc.measure"
        case .insert: "sc.import"
        case .visualize: "sc.appearance"
        }
    }

    /// Farbfamilie: Erzeugen blau, Ändern orange, Anordnen violett
    var category: ToolCategory {
        switch self {
        case .sketch, .create: .create
        case .modify: .modify
        case .arrange: .arrange
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
        case .create: "Körper erzeugen: Extrudieren, Drehen, Sweep, Loft, Bohrung und Gewinde, Grundkörper."
        case .modify: "Kanten abrunden oder fasen, Flächen ziehen, versetzen, ersetzen oder neigen, Schale, Körper kombinieren, teilen oder skalieren."
        case .arrange: "Körper verschieben, drehen, kopieren, ausrichten, spiegeln oder als Muster vervielfältigen."
        case .construct: "Hilfsebenen, -achsen und -punkte, z. B. eine versetzte Ebene zum Skizzieren."
        case .inspect: "Messen, Schnittansicht, Druckprüfung (Überhang, dünne Wände) und Isolieren."
        case .insert: "Normteile (Schrauben, Muttern, Lager), Vorlagen (Gehäuse, Stirnrad), STEP-, STL- und 3MF-Dateien, Bild als Vorlage (aus Fotos, Dateien oder direkt mit der Kamera), Körper eines anderen Projekts, eine Variable, Netze bearbeiten."
        case .visualize: "Anzeigemodus, orthografische Projektion, Körperfarbe, Zeichnung und Kontextvorschläge."
        }
    }

    /// Skizze ist eine direkte Aktion ohne Untermenü; jede andere Gruppe öffnet ihre vollständige Liste.
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
    /// Zwischenüberschrift im Untermenü (ÄNDERN: KANTEN, FLÄCHEN, KÖRPER, SPEZIAL)
    var heading: String?
    /// Tastenkürzel rechts
    var shortcut: String?
    /// Stecknadel: Schlüssel zum Anheften in die Leiste (nil = nicht anheftbar)
    var pinID: String?
}

/// Größe der senkrechten Ribbon-Leiste im 3D-Modus: Kachelgröße und Kacheln je Gruppe.
private struct RibbonSize: Equatable {
    let tile: CGFloat
    let gap: CGFloat
    /// Höchstens so viele Kacheln je Gruppe (hervorgehobene und angeheftete)
    let tiles: Int

    /// Von groß nach klein; die Leiste nimmt die erste, die in die Höhe passt.
    static let sizes: [RibbonSize] = [
        RibbonSize(tile: 44, gap: 6, tiles: 4),
        RibbonSize(tile: 40, gap: 5, tiles: 2),
        RibbonSize(tile: 38, gap: 4, tiles: 1),
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
    /// Kurze Beschriftung unter der Kachel in der Skizzenleiste (nil = title)
    var label: String?
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

/// Abschnitt der Skizzenleiste (category nil = obere Zeile mit „Beenden“ und „Auswählen“).
private struct RailSection: Identifiable {
    let id: String
    let category: ToolCategory?
    var entries: [RailEntry]
}

/// Zelle im Zwei-Spalten-Raster der Skizzenleiste: Werkzeugkachel oder Bedingungsknopf.
private enum RailCell: Identifiable {
    case entry(RailEntry)
    case grid(RailGridCell, isEnabled: Bool)

    var id: String {
        switch self {
        case .entry(let entry): "entry.\(entry.id)"
        case .grid(let cell, _): "grid.\(cell.id)"
        }
    }
}

/// Lage der Kacheln mit Untermenü in der Skizzenleiste
private struct RailEntryFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
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
    /// Gemessene Breite der Gruppenleiste (Kacheln + Beschriftung), Ankerpunkt des Untermenüs
    @State private var railWidth: CGFloat = 0
    /// Gemessene Höhe der Leiste und Lage jeder Gruppe darin (Koordinatenraum „ribbon“), für die Lage des Untermenüs
    @State private var railHeight: CGFloat = 0
    @State private var groupFrames: [ToolGroup: CGRect] = [:]
    /// Lage der Skizzenkacheln mit Untermenü (Koordinatenraum „sketchRail“) und Höhe der Skizzenleiste
    @State private var sketchFrames: [String: CGRect] = [:]
    @State private var sketchRailHeight: CGFloat = 0
    /// Angeheftete Befehle (Stecknadel im Gruppenmenü, ModelRibbon.pinsKey)
    @AppStorage("ribbon.pins") private var pinsText = ""
    /// Kontextvorschläge (Shapr3D): mit Auswahl Aktionen statt Gruppen links (Std. aus, ModelRibbon.contextKey)
    @AppStorage("model.contextSuggestions") private var contextSuggestions = false
    /// Platz unten links für Rückgängig/Wiederholen
    private let bottomReserve: CGFloat = 70

    var body: some View {
        if sketch.isActive {
            sketchRail
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
                    sectionHeader(section, collapsible: collapsible && section != .create)
                }
                if !isHidden(entry, collapsible: collapsible), let cells = entry.grid {
                    RailGrid(cells: cells, size: tile, isEnabled: entry.isEnabled)
                } else if !isHidden(entry, collapsible: collapsible) {
                RailTile(title: entry.title, subtitle: entry.subtitle, systemImage: entry.systemImage,
                         category: entry.category, isActive: entry.isActive, isOpen: openEntry == entry.id,
                         size: tile, hasVariants: entry.flyout != nil && entry.primary != nil)
                    .onTapGesture { tapEntry(entry) }
                    .onLongPressGesture(minimumDuration: 0.35) { pressEntry(entry) }
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
                // Nur so breit wie die Leiste: sonst nimmt die ScrollView die ganze Bildschirmbreite ein und fängt
                // jeden Strich auf der Zeichenfläche als Scrollen ab
                ScrollView(showsIndicators: false) { list }
                    .fixedSize(horizontal: true, vertical: false)
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

    /// Abschnittskopf (ERSTELLEN, ÄNDERN …), auf Wunsch zuklappbar.
    @ViewBuilder private func sectionHeader(_ section: ToolCategory, collapsible: Bool) -> some View {
        if collapsible {
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

    /// Antippen: Werkzeug starten (zuletzt gewählte Variante), Untermenü öffnen bzw. Aktion ausführen.
    private func tapEntry(_ entry: RailEntry) {
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

    /// Langes Drücken: Varianten zeigen; ohne Varianten eine kurze Erklärung als Kapsel unten.
    private func pressEntry(_ entry: RailEntry) {
        guard entry.flyout != nil else {
            if let text = ToolTips.detail(for: entry.title) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                workspace.explain(ToolExplanation(title: entry.title, text: text))
            }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        openEntry = entry.id
    }

    /// Höhe eines Eintrags in der Leiste (Kachel bzw. Raster), für die Lage des Untermenüs.
    private func entryHeight(_ entry: RailEntry, tile: CGFloat) -> CGFloat {
        guard let cells = entry.grid else { return tile }
        return RailGrid.height(count: cells.count, size: tile)
    }

    // MARK: Skizzenmodus

    /// Kachelgröße, Spaltenbreite (Kachel + Platz für die Beschriftung), Abstand und Innenabstand der Skizzenleiste
    private let sketchTile: CGFloat = 44
    private let sketchColumn: CGFloat = 48
    private let sketchGap: CGFloat = 4
    private let sketchPadding: CGFloat = 5

    /// Feste Breite der Skizzenleiste: zwei Spalten. Breiter wird sie nie (sonst fängt sie Striche über dem Viewport ab).
    private var sketchRailWidth: CGFloat { 2 * sketchColumn + sketchGap + 2 * sketchPadding }

    /// Skizzenname (ersetzt die frühere Kachel „Aktive Ebene“)
    private var sketchName: String {
        if let index = workspace.editingSketchIndex, model.sketches.indices.contains(index) {
            return model.sketches[index].name
        }
        return "Skizze \(model.sketches.count + 1)"
    }

    /// Skizzenname und Ebene, zweizeilig in Leistenbreite
    private var sketchTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sketchName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(sketch.isChoosingPlane ? "Ebene wählen" : activePlaneName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .floatingSurface(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous),
                         elevation: .flat)
    }

    /// Skizzenleiste: zwei Kacheln je Zeile auf einer gemeinsamen schmalen Fläche, Abschnitte zuklappbar.
    /// Das Untermenü (Varianten) liegt rechts daneben auf Höhe der Kachel und verbreitert die Leiste nicht.
    private var sketchRail: some View {
        let entries = sketchEntries
        let sections = railSections(entries)
        let list = VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                sketchSection(section)
            }
        }
        .padding(sketchPadding)
        .frame(width: sketchRailWidth, alignment: .leading)
        return VStack(alignment: .leading, spacing: 6) {
            sketchTitle
            ViewThatFits(in: .vertical) {
                list
                ScrollView(showsIndicators: false) { list }
                    .frame(width: sketchRailWidth)
            }
            .frame(width: sketchRailWidth)
            .floatingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
        }
        .frame(width: sketchRailWidth, alignment: .leading)
        .coordinateSpace(name: "sketchRail")
        .onPreferenceChange(RailEntryFramesKey.self) { frames in
            sketchFrames = frames
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sketchRailHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in
                        sketchRailHeight = height
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            sketchFlyout(entries)
        }
        .animation(Theme.spring, value: openEntry)
    }

    /// Untermenü des offenen Eintrags: obere Kacheln öffnen es nach unten, untere nach oben.
    @ViewBuilder private func sketchFlyout(_ entries: [RailEntry]) -> some View {
        if let openEntry, let entry = entries.first(where: { $0.id == openEntry }), let items = entry.flyout {
            let frame = sketchFrames[openEntry] ?? .zero
            let fromTop = frame.midY * 2 < max(sketchRailHeight, 1)
            Flyout(title: entry.title, category: entry.category, items: items) {
                self.openEntry = nil
            }
            .padding(.top, fromTop ? max(frame.minY, 0) : 0)
            .padding(.bottom, fromTop ? 0 : max(sketchRailHeight - frame.maxY, 0))
            .frame(maxHeight: .infinity, alignment: fromTop ? .top : .bottom)
            .offset(x: sketchRailWidth + 10)
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    /// Aufeinanderfolgende Einträge gleicher Kategorie bilden einen Abschnitt; „Beenden“ und „Auswählen“ die obere Zeile.
    private func railSections(_ entries: [RailEntry]) -> [RailSection] {
        var result: [RailSection] = []
        for entry in entries {
            let category: ToolCategory? = entry.category == .neutral || entry.category == .finish ? nil : entry.category
            let id = category?.rawValue ?? "top"
            if let last = result.last, last.id == id {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(RailSection(id: id, category: category, entries: [entry]))
            }
        }
        return result
    }

    /// Zeilen zu je zwei Zellen; ein Raster (Bedingungen) beginnt in einer neuen Zeile.
    private func sketchRows(_ entries: [RailEntry]) -> [[RailCell]] {
        var rows: [[RailCell]] = []
        var current: [RailCell] = []
        for entry in entries where !isHidden(entry, collapsible: true) {
            if let cells = entry.grid {
                if !current.isEmpty {
                    rows.append(current)
                    current = []
                }
                for cell in cells {
                    current.append(.grid(cell, isEnabled: entry.isEnabled))
                    if current.count == 2 {
                        rows.append(current)
                        current = []
                    }
                }
                if !current.isEmpty {
                    rows.append(current)
                    current = []
                }
            } else {
                current.append(.entry(entry))
                if current.count == 2 {
                    rows.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private func sketchSection(_ section: RailSection) -> some View {
        let rows = sketchRows(section.entries)
        return VStack(alignment: .leading, spacing: sketchGap) {
            if let category = section.category {
                sectionHeader(category, collapsible: category != .create)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: sketchGap) {
                    ForEach(row) { cell in
                        railCell(cell)
                    }
                }
            }
        }
    }

    @ViewBuilder private func railCell(_ cell: RailCell) -> some View {
        switch cell {
        case .entry(let entry):
            compactTile(entry)
        case .grid(let item, let isEnabled):
            Button(action: item.action) {
                RailGridIcon(cell: item, size: sketchTile, isEnabled: isEnabled)
            }
            .buttonStyle(.pressable)
            .disabled(!isEnabled)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(item.isPending ? .isSelected : [])
            .hoverTip(item.title, item.detail)
            .frame(width: sketchColumn)
        }
    }

    /// Kachel mit kleiner Beschriftung darunter; Variante und Erklärung im Schild.
    private func compactTile(_ entry: RailEntry) -> some View {
        RailTile(title: entry.label ?? entry.title, subtitle: entry.subtitle, systemImage: entry.systemImage,
                 category: entry.category, isActive: entry.isActive, isOpen: openEntry == entry.id,
                 size: sketchTile, hasVariants: entry.flyout != nil && entry.primary != nil, labelBelow: true)
            .frame(width: sketchColumn)
            .contentShape(Rectangle())
            .onTapGesture { tapEntry(entry) }
            .onLongPressGesture(minimumDuration: 0.35) { pressEntry(entry) }
            .allowsHitTesting(entry.isEnabled)
            .opacity(entry.isEnabled ? 1 : 0.45)
            .accessibilityLabel(entry.title)
            .accessibilityAddTraits(.isButton)
            .hoverTip(entry.title, entryTip(entry))
            .background {
                if entry.flyout != nil {
                    GeometryReader { proxy in
                        Color.clear.preference(key: RailEntryFramesKey.self,
                                               value: [entry.id: proxy.frame(in: .named("sketchRail"))])
                    }
                }
            }
    }

    /// Schild: gewählte Variante, Erklärung und Hinweis auf die Varianten
    private func entryTip(_ entry: RailEntry) -> String? {
        var parts: [String] = []
        if let subtitle = entry.subtitle {
            parts.append(subtitle + ".")
        }
        if let detail = ToolTips.detail(for: entry.title) {
            parts.append(detail)
        }
        if entry.primary != nil {
            parts.append("Lange drücken: alle Varianten.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
            }, label: "Beenden"),
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
            // BEDINGEN: Bemaßung und Trennen in einer Zeile, dann das Raster der Bedingungen
            RailEntry(id: "sketch.dimension", title: ConstraintKind.dimension.rawValue, subtitle: "Element antippen",
                      systemImage: ConstraintKind.dimension.systemImage, category: .constrain, isEnabled: planeReady,
                      action: {
                // Maße erscheinen zur Auswahl im Viewport (Maßfeld mit Schloss)
                if sketch.pendingAction != nil { sketch.cancelPending() }
                sketch.tool = .select
                sketch.notice = ConstraintKind.dimension.selectionHint
            }),
            RailEntry(id: "sketch.detach", title: "Trennen", subtitle: detachPending ? "Aktiv" : nil,
                      systemImage: "link.badge.plus", category: .constrain, isActive: detachPending,
                      isEnabled: planeReady, action: {
                sketch.start(.detach)
            }),
            RailEntry(id: "sketch.constraints", title: "Bedingungen", systemImage: "sc.c_hv", category: .constrain,
                      isEnabled: planeReady, grid: constraintCells),
            // REFERENZ
            toolEntry(.project, category: .reference),
            // PRÜFEN
            toolEntry(.measure, category: .inspect),
            RailEntry(id: "sketch.section", title: "Schnittansicht", subtitle: workspace.sketchSection ? "Ein" : "Aus",
                      systemImage: "sc.section", category: .inspect, isActive: workspace.sketchSection, action: {
                workspace.sketchSection.toggle()
            }, label: "Schnitt"),
        ]
    }

    // MARK: Kontext (Auswahl im 3D-Modus)

    private var hasSelection: Bool {
        model.selection != nil || !model.selectedEdges.isEmpty || !model.selectedBodies.isEmpty
            || !model.selectedRegions.isEmpty
    }

    /// Frühere Kontextleiste nur mit der Einstellung „Kontextvorschläge (Shapr3D)“; sonst stehen die Aktionen im
    /// Kontextmenü bzw. Werkzeugrad (ModelRibbon.contextCommands).
    private var showsContext: Bool {
        contextSuggestions && workspace.tool == .select && hasSelection && !workspace.showsAllTools
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
                    model.deleteBodies(model.deletableBodies)
                }
            }),
        ]
        return entries
    }

    // MARK: Werkzeuggruppen (senkrechtes Ribbon)

    /// „Zurück“ (zur Auswahl) steht über den Gruppen, wenn die Kontextvorschläge an sind
    private var showsBackTile: Bool { contextSuggestions && workspace.showsAllTools && hasSelection }

    private var pins: Set<String> { ModelRibbon.pins(pinsText) }

    private func ribbonCommands(_ group: ToolGroup) -> [RibbonCommand] {
        ModelRibbon.commands(for: group, ws: workspace, importFile: importSTEP)
    }

    private var modelTools: some View {
        let sizes = RibbonSize.sizes
        let smallest = sizes[sizes.count - 1]
        // Größte Form, mit der alles in die Höhe passt; sonst die kleinste und scrollen
        return ViewThatFits(in: .vertical) {
            ribbonColumn(sizes[0])
            ribbonColumn(sizes[1])
            ribbonColumn(smallest)
            ScrollView(showsIndicators: false) { ribbonColumn(smallest) }
                .fixedSize(horizontal: true, vertical: false)
        }
        .coordinateSpace(name: "ribbon")
        // Größe der Leiste samt Beschriftungen messen: das Untermenü beginnt rechts daneben
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        railWidth = proxy.size.width
                        railHeight = proxy.size.height
                    }
                    .onChange(of: proxy.size) { _, size in
                        railWidth = size.width
                        railHeight = size.height
                    }
            }
        }
        // Untermenü rechts neben der Leiste auf Höhe der Gruppe; es verbreitert die Leiste nicht.
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

    /// Obere Gruppen: Untermenü beginnt auf Höhe des Gruppenkopfs; untere: es endet dort und wächst nach oben.
    private func groupFlyout(_ group: ToolGroup) -> some View {
        let frame = groupFrames[group] ?? .zero
        let fromTop = frame.midY * 2 < max(railHeight, 1)
        let top: CGFloat = fromTop ? max(frame.minY, 0) : 0
        let bottom: CGFloat = fromTop ? 0 : max(railHeight - frame.maxY, 0)
        let items = ribbonCommands(group).map { ribbonItem($0) }
        return Flyout(title: group.rawValue, category: group.category, items: items, close: {
            self.openGroup = nil
        }, pins: pins, togglePin: { id in
            pinsText = ModelRibbon.toggled(id, in: pinsText)
        })
        .padding(.top, top)
        .padding(.bottom, bottom)
        .frame(maxHeight: .infinity, alignment: fromTop ? .top : .bottom)
    }

    private func ribbonItem(_ command: RibbonCommand) -> ToolItem {
        ToolItem(id: command.id, title: command.title, subtitle: command.subtitle, systemImage: command.icon,
                 isEnabled: command.isEnabled, isActive: command.isActive, action: command.run,
                 heading: command.heading, shortcut: command.shortcut, pinID: command.id)
    }

    private func ribbonColumn(_ size: RibbonSize) -> some View {
        VStack(alignment: .leading, spacing: size.gap + 4) {
            if showsBackTile {
                Button {
                    workspace.showsAllTools = false
                } label: {
                    RailTile(title: "Zurück", subtitle: "Auswahl", systemImage: "chevron.backward", size: size.tile)
                }
                .buttonStyle(.plain)
            }
            // Kontextmenü zur Auswahl (früher die Kontextleiste): Aktionen nach ModelRibbon.contextCommands
            if hasSelection, !showsBackTile, workspace.command == nil {
                selectionMenu(size)
            }
            ForEach(ToolGroup.allCases) { group in
                ribbonGroup(group, size: size)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { groupFrames[group] = proxy.frame(in: .named("ribbon")) }
                                .onChange(of: proxy.frame(in: .named("ribbon"))) { _, frame in
                                    groupFrames[group] = frame
                                }
                        }
                    }
            }
        }
    }

    /// Kachel „Auswahl“: Menü mit den Befehlen zur jetzigen Auswahl (Extrudieren, Abrunden, Verschieben …).
    private func selectionMenu(_ size: RibbonSize) -> some View {
        let actions = ModelRibbon.contextCommands(workspace)
        return Menu {
            Section(selectionSummary) {
                ForEach(actions) { command in
                    Button {
                        openGroup = nil
                        command.run()
                    } label: {
                        ToolLabel(command.title, icon: command.icon)
                    }
                    .disabled(!command.isEnabled)
                }
            }
            Button(role: .destructive) {
                model.resetSelection()
            } label: {
                Label("Alle abwählen", systemImage: "xmark.circle")
            }
        } label: {
            RailTile(title: "Auswahl", subtitle: selectionSummary, systemImage: "contextualmenu.and.cursorarrow",
                     isActive: true, size: size.tile)
        }
        .accessibilityLabel("Aktionen zur Auswahl")
        .hoverTip("Auswahl", "Befehle zur gewählten Auswahl")
    }

    /// Gruppe: Kopf „NAME ▾“ (öffnet die vollständige Liste) und darunter die hervorgehobenen bzw. angehefteten Befehle
    /// als Kacheln (SolidCraft-Ribbon senkrecht für das iPad).
    private func ribbonGroup(_ group: ToolGroup, size: RibbonSize) -> some View {
        let commands = ribbonCommands(group)
        let tiles = ModelRibbon.tiles(commands, pins: pins, limit: size.tiles)
        return VStack(alignment: .leading, spacing: size.gap) {
            RibbonGroupHeader(group: group, isOpen: openGroup == group,
                              isActive: isActive(group) || commands.contains(where: \.isActive))
                .contentShape(Rectangle())
                .onTapGesture { tapped(group) }
                .accessibilityAddTraits(.isButton)
                .hoverTip(group.rawValue, group.tip)
            ForEach(tiles) { command in
                Button {
                    openGroup = nil
                    command.run()
                } label: {
                    RailTile(title: command.title, subtitle: nil, systemImage: command.icon,
                             category: group.category, isActive: command.isActive, size: size.tile)
                }
                .buttonStyle(.plain)
                .disabled(!command.isEnabled)
                .opacity(command.isEnabled ? 1 : 0.45)
                .accessibilityLabel(command.title)
                .hoverTip(command.shortcut.map { "\(command.title) (\($0))" } ?? command.title,
                          ToolTips.detail(for: command.title) ?? command.subtitle)
            }
        }
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
        case .insert, .revolve, .sweep, .loft, .hole:
            return group == .create
        case .part(let kind):
            return group == kind.group
        case .boolean, .split, .mold, .shell, .offsetEdges, .offsetFace, .replaceFace, .wrap, .imprint:
            return group == .modify
        case .scale:
            return group == .modify
        case .move, .translate, .align, .scaleSketch, .mirror, .pattern:
            return group == .arrange
        case .construct:
            return group == .construct
        case .measure, .printCheck, .section:
            return group == .inspect
        case .canvas, .meshSculpt:
            return group == .insert
        case .color:
            return group == .visualize
        case .select:
            switch group {
            case .sketch: return sketch.isActive
            case .modify: return !model.selectedEdges.isEmpty
            case .create: return !model.selectedRegions.isEmpty || model.faceHandle != nil
            default: return false
            }
        }
    }

    /// Verschieben ohne bzw. mit Kopie aus der Kontextleiste (Kai: „Kopieren kommt beim Verschieben rein“).
    private func startMove(copies: Bool) {
        workspace.startCommand(copies ? .copy : .move)
    }
}

/// Kopf einer Ribbon-Gruppe: Kategoriefarbe, Name in Großbuchstaben und ▾ (öffnet die vollständige Liste).
private struct RibbonGroupHeader: View {
    let group: ToolGroup
    var isOpen = false
    var isActive = false

    var body: some View {
        let color = group.category.color
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(group.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(isActive ? Color.primary : color)
            if group.hasFlyout {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .floatingSurface(.regularMaterial, in: Capsule(), elevation: .flat)
        .overlay {
            if isOpen {
                Capsule().strokeBorder(group.category.fill, lineWidth: 1.5)
            }
        }
        .animation(Theme.snappy, value: isOpen)
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
    /// Schmale Form (Skizzenleiste): kleine Beschriftung unter der Kachel statt der Kapsel daneben
    var labelBelow = false

    private var isCustom: Bool { ToolIcon.isCustom(systemImage) }

    /// Vollfarbe mit weißem Symbol: aktives SF Symbol bzw. „Skizzieren beenden“ (wie in Fusion 360 immer ein grüner Haken)
    private var filled: Bool { category == .finish || (isActive && !isCustom) }

    /// Aktives SolidCraft-Bild: heller Grund in Kategoriefarbe und kräftiger Rahmen
    private var tinted: Bool { isActive && isCustom && category != .finish }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.27, style: .continuous) }

    var body: some View {
        if labelBelow {
            VStack(spacing: 2) {
                tile
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isActive ? category.fill : Color.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .frame(width: size + 4)
            }
            .contentShape(Rectangle())
            .animation(Theme.snappy, value: isActive)
        } else {
            besideBody
        }
    }

    private var besideBody: some View {
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
        // Feste Breite: ein LazyVGrid nimmt sonst die ganze angebotene Breite ein (dunkles Band bis unters rechte
        // Panel, das Berührungen über dem Viewport abfängt)
        .frame(width: 2 * size + Self.spacing)
        .padding(Self.spacing)
        .fixedSize(horizontal: true, vertical: false)
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
    /// Angeheftete Einträge (Stecknadel gefüllt); nil-Schalter = keine Stecknadeln (Skizzenmodus)
    var pins: Set<String> = []
    var togglePin: ((String) -> Void)? = nil

    var body: some View {
        // Lange Listen scrollen, wenn sie nicht auf den Bildschirm passen.
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .frame(width: 264)
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
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let heading = item.heading, index == 0 || items[index - 1].heading != heading {
                    // Zwischenüberschrift (ÄNDERN: KANTEN, FLÄCHEN, KÖRPER, SPEZIAL)
                    Text(heading)
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, index == 0 ? 0 : 6)
                }
                row(item)
            }
        }
        .padding(10)
    }

    private func row(_ item: ToolItem) -> some View {
        let pinned = item.pinID.map { pins.contains($0) } ?? false
        return HStack(spacing: 4) {
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
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: 1)
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
            .opacity(item.isEnabled ? 1 : 0.4)
            .hoverTip(item.shortcut.map { "\(item.title) (\($0))" } ?? item.title,
                      ToolTips.detail(for: item.title) ?? item.subtitle)
            .contextMenu {
                if let togglePin, let id = item.pinID {
                    Button(pinned ? "Von der Leiste lösen" : "An die Leiste heften",
                           systemImage: pinned ? "pin.slash" : "pin") {
                        togglePin(id)
                    }
                }
            }
            if let togglePin, let id = item.pinID {
                // Stecknadel: Befehl als Kachel in die Leiste heften (auch lange drücken)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    togglePin(id)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pinned ? category.fill : Color.secondary.opacity(0.6))
                        .rotationEffect(.degrees(45))
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pinned ? "Von der Leiste lösen" : "An die Leiste heften")
            }
        }
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
