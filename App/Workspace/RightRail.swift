import SwiftUI
import simd

/// Seitenleisten-Fenster rechts.
enum SidePanel: String, Identifiable {
    case history = "Verlauf"
    case properties = "Eigenschaften"

    var id: Self { self }
}

/// Fang-Symbol: Hufeisenmagnet (gibt es nicht als SF Symbol).
struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let radius = w * 0.3
        let bottom = CGPoint(x: rect.midX, y: rect.minY + h * 0.58)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - radius, y: rect.minY + h * 0.1))
        path.addLine(to: CGPoint(x: rect.midX - radius, y: bottom.y))
        path.addArc(center: bottom, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.midX + radius, y: rect.minY + h * 0.1))
        return path
    }
}

/// Polenden des Magneten (abgesetzt dargestellt).
struct MagnetPoles: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let radius = w * 0.3
        var path = Path()
        for x in [rect.midX - radius, rect.midX + radius] {
            path.move(to: CGPoint(x: x, y: rect.minY + h * 0.1))
            path.addLine(to: CGPoint(x: x, y: rect.minY + h * 0.3))
        }
        return path
    }
}

struct MagnetRailIcon: View {
    var isActive: Bool
    /// false in einer gemeinsamen Säule (RailGroup), die selbst den Schatten trägt
    var shadowed = true

    var body: some View {
        let ink = isActive ? Color.white : Color.primary
        ZStack {
            MagnetShape()
                .stroke(ink, style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
            MagnetPoles()
                .stroke(isActive ? Color.white.opacity(0.55) : Color.red.opacity(0.8),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
        }
        .frame(width: 20, height: 22)
        .frame(width: 44, height: 44)
        .floatingSurface(isActive ? Color.accentColor : Theme.surface, in: Circle(), elevation: shadowed ? .raised : .inset)
        .animation(Theme.snappy, value: isActive)
    }
}

/// Fangeinstellungen wie bei Shapr3D: Hauptschalter, Einrasten (Raster, Skizzenleitlinien, Skizzenleitpunkte,
/// 3D-Leitpunkte, entfernte Kanten), Zeigen (Leitpunkte, Einrasthinweise); die einzelnen Fangarten aufklappbar.
struct SnapMenu: View {
    @ObservedObject var sketch: SketchController
    let gridSteps: [Double]
    @State private var showsDetails = false

    /// Gruppen wie in Shapr3D; jede schaltet mehrere Fangarten
    private static let groups: [(title: String, detail: String, systemImage: String, kinds: Set<SnapKind>)] = [
        ("Raster", "Punkte rasten im Rastermaß ein", "grid", [.grid]),
        ("Skizzenleitlinien", "Waagerecht, senkrecht und 15°-Winkel zu vorhandenen Punkten", "line.diagonal",
         [.alignment, .angle]),
        ("Skizzenleitpunkte", "Enden, Mitten, Zentren, Schnittpunkte und Kurven", "smallcircle.filled.circle",
         [.endpoint, .midpoint, .center, .intersection, .onCurve]),
        ("3D-Leitpunkte", "Ecken und Kantenmitten der Körper", "cube", [.modelPoint]),
        ("Entfernte Kanten", "Körperkanten außerhalb der Skizzenebene", "cube.transparent", [.distantEdge]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $sketch.snapEnabled) {
                    Text("Fang")
                        .font(.headline)
                }
                Divider()
                Text("EINRASTEN")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Self.groups.indices, id: \.self) { index in
                    let group = Self.groups[index]
                    Toggle(isOn: Binding(get: { !sketch.snapKinds.isDisjoint(with: group.kinds) }, set: { on in
                        if on { sketch.snapKinds.formUnion(group.kinds) } else { sketch.snapKinds.subtract(group.kinds) }
                    })) {
                        row(group.title, group.detail, group.systemImage)
                    }
                }
                .disabled(!sketch.snapEnabled)
                Picker("Raster", selection: $sketch.gridStep) {
                    ForEach(gridSteps, id: \.self) { step in
                        Text(LengthUnit.current.gridNumber(step)).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                DisclosureGroup("Einzelne Fangarten", isExpanded: $showsDetails) {
                    ForEach(SnapKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { sketch.snapKinds.contains(kind) }, set: { on in
                            if on { sketch.snapKinds.insert(kind) } else { sketch.snapKinds.remove(kind) }
                        })) {
                            row(kind.rawValue, kind.detail, kind.systemImage)
                        }
                    }
                    .disabled(!sketch.snapEnabled)
                }
                Divider()
                Text("ZEIGEN")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle(isOn: $sketch.showsGuidePoints) {
                    row("Leitpunkte", "Knoten in Stiftnähe beim Schweben", "circle.dotted")
                }
                Toggle(isOn: $sketch.showsSnapHints) {
                    row("Einrasthinweise", "Art des Fangs als Schild am Stift", "text.bubble")
                }
                Toggle(isOn: $sketch.autoConstrain) {
                    row("Automatisch einschränken", "Waagerecht, senkrecht, parallel und rechtwinklig beim Zeichnen festhalten", "link")
                }
            }
            .font(.callout)
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 620)
    }

    private func row(_ title: String, _ detail: String, _ systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Rechte Leiste: Fang, Rastergröße, ViewCube, Einpassen, Anzeigemodus, Screenshot, Verlauf, Elemente;
/// im 3D-Modus unten Schnittansicht, Isolieren und Löschen.
struct RightRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    @Binding var panel: SidePanel?
    let screenshot: () -> Void

    /// Rastermaß bis zum Tausendstel Millimeter (bzw. passend zur Projekteinheit, z. B. 1/16 Zoll)
    private static var gridSteps: [Double] { LengthUnit.current.gridSteps }
    @State private var isSnapMenuShown = false
    /// Rahmenauswahl als Lasso (lange drücken auf „Rahmenauswahl“)
    @AppStorage(LassoSelection.key) private var lassoSelects = false

    /// Eigenschaften öffnen bzw. schließen; beim Öffnen gilt das Auswahlwerkzeug.
    private func toggleProperties() {
        if panel == .properties {
            panel = nil
            return
        }
        panel = .properties
        if workspace.tool != .select { workspace.activate(.select) }
    }

    var body: some View {
        if sketch.isActive {
            ViewThatFits(in: .vertical) {
                sketchColumn
                ScrollView(showsIndicators: false) { sketchColumn }
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            // Passt die Säule nicht in die Höhe (iPad 11" quer): enger, sonst scrollen (dann ohne Schilder,
            // die die Scrollfläche abschneiden würde)
            ViewThatFits(in: .vertical) {
                mainColumn(spacing: 10, showsLabels: true)
                mainColumn(spacing: 6, showsLabels: true)
                ScrollView(showsIndicators: false) { mainColumn(spacing: 6, showsLabels: false) }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Skizzenmodus (schlank, SolidCraft): Fang, Raster, Ausrichten und Finger in einer Säule, daneben der Würfel;
    /// darunter Anzeigemodi, Screenshot, Verlauf, Eigenschaften und Sichtbarkeit als Symbole. Die Schalter der
    /// früheren „Skizzenpalette“ stehen in SketchPalette, die Bedingungen links in der ToolRail.
    private var sketchColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ViewCube(camera: workspace.camera, motion: workspace.cameraMotion) { normal in
                    workspace.send(.look(normal))
                }
                // Nach der Ebenenwahl bleibt die Ansicht senkrecht auf der Skizzenebene
                .disabled(!sketch.isChoosingPlane)
                .opacity(sketch.isChoosingPlane ? 1 : 0.4)
                RailGroup {
                    Button {
                        isSnapMenuShown = true
                    } label: {
                        MagnetRailIcon(isActive: sketch.snapEnabled, shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fang")
                    .hoverTip("Fang")
                    .popover(isPresented: $isSnapMenuShown, arrowEdge: .trailing) {
                        SnapMenu(sketch: sketch, gridSteps: Self.gridSteps)
                    }
                    gridMenu(stacked: true)
                        .hoverTip("Raster")
                    Button {
                        workspace.send(.alignToSketchPlane)
                    } label: {
                        RailIcon(systemImage: "cube.transparent", shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Normal zu Skizze")
                    .hoverTip("Normal zu Skizze")
                    .disabled(sketch.isChoosingPlane)
                    .opacity(sketch.isChoosingPlane ? 0.4 : 1)
                    Button {
                        sketch.fingerDraws.toggle()
                    } label: {
                        RailIcon(systemImage: sketch.fingerDraws ? "hand.draw.fill" : "hand.draw",
                                 isActive: sketch.fingerDraws, shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Finger zeichnet")
                    .hoverTip("Finger zeichnet")
                }
            }

            // Ansicht und Fenster als schmale Säule ohne Schilder: links daneben steht die Skizzenpalette
            // (Werkzeug-Eigenschaften, Schalter der früheren „Skizzenpalette“); Bedingungen liegen links (ToolRail)
            RailGroup {
                Menu {
                    displayModePicker
                } label: {
                    RailIcon(systemImage: workspace.displayMode.systemImage, shadowed: false)
                }
                .accessibilityLabel("Anzeigemodus")
                .hoverTip("Anzeigemodi")
                compactButton("Screenshot", systemImage: "camera", action: screenshot)
                compactButton("Verlauf", systemImage: "clock.arrow.circlepath", isActive: panel == .history) {
                    panel = panel == .history ? nil : .history
                }
                compactButton("Eigenschaften", systemImage: "info.circle", isActive: panel == .properties) {
                    toggleProperties()
                }
                Menu {
                    visibilityItems
                } label: {
                    RailIcon(systemImage: "eye", shadowed: false)
                }
                .accessibilityLabel("Sichtbarkeit")
                .hoverTip("Sichtbarkeit")
            }
        }
    }

    private func compactButton(_ title: String, systemImage: String, isActive: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RailIcon(systemImage: systemImage, isActive: isActive, shadowed: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .hoverTip(title)
    }

    /// Rastermaß; im Skizzenmodus wie bei Shapr3D zweizeilig („50“ über „mm“).
    private func gridMenu(stacked: Bool) -> some View {
        Menu {
            if stacked {
                // SolidCraft: Rasterweite 1-2-5 nach Zoom (Skizzenmodus); feste Weite darunter
                Toggle("Automatisch (1-2-5)", systemImage: "square.grid.3x3",
                       isOn: Binding(get: { sketch.options.gridAuto }, set: { sketch.options.gridAuto = $0 }))
                Divider()
            }
            Picker("Raster", selection: $sketch.gridStep) {
                ForEach(Self.gridSteps, id: \.self) { step in
                    Text(LengthUnit.current.gridLabel(step)).tag(step)
                }
            }
        } label: {
            Group {
                if stacked {
                    VStack(spacing: -1) {
                        Text(LengthUnit.current.gridNumber(sketch.gridStep))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text(LengthUnit.current.symbol)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(width: 44, height: 44)
                } else {
                    Text(LengthUnit.current.gridNumber(sketch.gridStep))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(width: 44, height: 44)
                        .floatingSurface(in: Circle())
                }
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Rastergröße")
        }
    }

    /// Skizzen, Bilder und Konstruktionsgeometrie gesammelt ein- und ausblenden; einzeln unter „Elemente“.
    @ViewBuilder
    private var visibilityItems: some View {
        let model = workspace.model
        Toggle("Skizzen", systemImage: "pencil.and.outline",
               isOn: Binding(get: { model.showsSketches }, set: { model.setSketchesHidden(!$0) }))
            .disabled(model.sketches.isEmpty)
        Toggle("Bilder", systemImage: "photo",
               isOn: Binding(get: { model.showsCanvases }, set: { model.setCanvasesHidden(!$0) }))
            .disabled(model.canvases.isEmpty)
        Toggle("Konstruktion", systemImage: "square.dashed",
               isOn: Binding(get: { model.showsConstructions }, set: { model.setConstructionsHidden(!$0) }))
            .disabled(model.constructions.isEmpty)
        Divider()
        Button("Einzeln in „Ebenen“ …", systemImage: "square.3.layers.3d") {
            workspace.showsLayers = true
        }
    }

    @ViewBuilder
    private var displayModePicker: some View {
        Picker("Anzeigemodus", selection: $workspace.displayMode) {
            ForEach(DisplayMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
            }
        }
        Divider()
        Toggle("Orthografisch", systemImage: "cube.transparent", isOn: $workspace.isOrthographic)
        AppearanceToggle()
    }

    private func mainColumn(spacing: CGFloat, showsLabels: Bool) -> some View {
        VStack(spacing: spacing) {
            Button {
                isSnapMenuShown = true
            } label: {
                MagnetRailIcon(isActive: sketch.snapEnabled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fang")
            .hoverTip("Fang")
            .popover(isPresented: $isSnapMenuShown, arrowEdge: .trailing) {
                SnapMenu(sketch: sketch, gridSteps: Self.gridSteps)
            }
            gridMenu(stacked: false)
                .hoverTip("Raster")

            ViewCube(camera: workspace.camera, motion: workspace.cameraMotion) { normal in
                workspace.send(.look(normal))
            }
            .padding(.vertical, 4)
            .hoverTip("Ansichtswürfel", "Seite, Kante oder Ecke antippen: Ansicht dorthin drehen. Ziehen dreht frei.")

            RailButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Einpassen") {
                workspace.send(.fitAll)
            }
            // Offener Modellbefehl (FeaturePanel): darunter stehen OK/Abbrechen, die übrigen Knöpfe ruhen
            if workspace.command == nil {
                Menu {
                    Button("Aktuelle Ansicht speichern", systemImage: "plus", action: workspace.saveCurrentView)
                    if !workspace.savedViews.isEmpty {
                        Divider()
                        ForEach(workspace.savedViews) { view in
                            Button(view.name, systemImage: "camera.viewfinder") { workspace.restoreView(view) }
                        }
                        Menu("Löschen", systemImage: "trash") {
                            ForEach(workspace.savedViews) { view in
                                Button(view.name, role: .destructive) { workspace.deleteView(view.id) }
                            }
                        }
                    }
                } label: {
                    RailIcon(systemImage: "camera.viewfinder")
                        .accessibilityLabel("Ansichten")
                }
                .hoverTip("Ansichten", "Blickwinkel und Zoom speichern und später mit einem Tipp wiederherstellen.")
                Menu {
                    displayModePicker
                } label: {
                    RailIcon(systemImage: workspace.displayMode.systemImage)
                        .accessibilityLabel("Anzeigemodus")
                }
                .hoverTip("Anzeigemodi")
                RailButton(systemImage: "camera", label: "Screenshot", action: screenshot)
                RailButton(systemImage: "clock.arrow.circlepath", label: "Verlauf", isActive: panel == .history) {
                    panel = panel == .history ? nil : .history
                }
                RailButton(systemImage: "info.circle", label: "Eigenschaften", isActive: panel == .properties) {
                    toggleProperties()
                }
                Menu {
                    visibilityItems
                } label: {
                    RailIcon(systemImage: "eye")
                        .accessibilityLabel("Sichtbarkeit")
                }
                .hoverTip("Sichtbarkeit")
                RailButton(systemImage: "square.3.layers.3d", label: "Ebenen", isActive: workspace.showsLayers) {
                    workspace.showsLayers.toggle()
                }
                RailButton(systemImage: "cube", label: "Körper wählen", isActive: workspace.selectsBodies) {
                    workspace.selectsBodies.toggle()
                    if workspace.selectsBodies, workspace.tool != .select { workspace.activate(.select) }
                }
                RailButton(systemImage: lassoSelects ? "lasso" : "rectangle.dashed",
                           label: lassoSelects ? "Lassoauswahl" : "Rahmenauswahl", isActive: workspace.boxSelects) {
                    workspace.boxSelects.toggle()
                    if workspace.boxSelects, !workspace.acceptsBoxSelection { workspace.activate(.select) }
                }
                // Lange drücken: Rahmen oder Lasso (gilt auch für den Stift und in der Skizze)
                .contextMenu {
                    Picker("Auswahlform", selection: $lassoSelects) {
                        Label("Rahmen", systemImage: "rectangle.dashed").tag(false)
                        Label("Lasso", systemImage: "lasso").tag(true)
                    }
                }
                // Direkte Knöpfe (vorher unter Prüfen bzw. Ändern links)
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 30, height: 3)
                ModelRailButtons(workspace: workspace, model: workspace.model, showsLabels: showsLabels && panel == nil)
            }
        }
    }
}

/// Schnittansicht, Isolieren und Löschen als direkte Knöpfe der rechten Leiste im 3D-Modus, mit Schild links
/// daneben (das Schild liegt über dem Viewport und verbreitert die Leiste nicht).
private struct ModelRailButtons: View {
    @ObservedObject var workspace: Workspace
    /// Eigenes Beobachten: Auswahl und Isolieren ändern sich im Modell
    @ObservedObject var model: ModelStore
    var showsLabels: Bool

    var body: some View {
        let sectionOn = workspace.section != nil
        let isolated = model.isIsolated
        let canDelete = !model.selectedBodies.isEmpty || model.selectedBody != nil
        button("Schnittansicht", subtitle: sectionOn ? "Ein" : "Aus", systemImage: "square.split.diagonal.2x2",
               isActive: sectionOn) {
            toggleSection()
        }
        button("Isolieren", subtitle: isolated ? "Ein" : "Aus", systemImage: "scope", isActive: isolated) {
            workspace.toggleIsolate()
        }
        button("Löschen", subtitle: canDelete ? "Gewählte Körper" : "Nichts gewählt", systemImage: "trash",
               isActive: false) {
            model.deleteSelected()
            // Andere Werkzeuge halten Körpernummern (Ziel, Werkzeuge, Vorschau): danach zurück zur Auswahl
            if workspace.tool != .select { workspace.activate(.select) }
        }
        .disabled(!canDelete)
        .opacity(canDelete ? 1 : 0.4)
    }

    /// Ein: Werkzeug Schnittansicht (Karte unten); Aus: Schnitt entfernen.
    private func toggleSection() {
        if workspace.section != nil {
            workspace.section = nil
            if workspace.tool == .section { workspace.activate(.select) }
        } else {
            workspace.activate(.section)
        }
    }

    private func button(_ title: String, subtitle: String, systemImage: String, isActive: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RailIcon(systemImage: systemImage, isActive: isActive)
                .overlay(alignment: .trailing) {
                    if showsLabels {
                        RailLabel(title: title, subtitle: subtitle)
                            .fixedSize()
                            .offset(x: -52)
                    }
                }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
        .hoverTip(title)
    }
}

/// „Einschränkungen“ im Skizzenmodus. Bedienung wie in Fusion 360: Symbol antippen, dann die Elemente –
/// die Einschränkung wird gesetzt, sobald die Auswahl passt, und bleibt für die nächsten Elemente aktiv
/// (blau hinterlegt), bis das Symbol nochmal getippt wird. Sind schon passende Elemente gewählt, wirkt sie
/// sofort. Passende Einschränkungen zur aktuellen Auswahl sind blau, andere grau; Schweben zeigt die Erklärung.
struct ConstraintColumn: View {
    @ObservedObject var sketch: SketchController
    var isEnabled = true

    private struct Row: Identifiable {
        let id: String
        let systemImage: String
        let action: SketchPendingAction
        let applicable: Bool
    }

    private var groups: [[Row]] {
        let hasSelection = !sketch.selection.isEmpty
        let kinds = ConstraintKind.allCases.filter { $0 != .lock && $0 != .dimension }.map { kind in
            Row(id: kind.rawValue, systemImage: kind.systemImage, action: .constraint(kind), applicable: sketch.canApply(kind))
        }
        // Verankern ganz oben: Kai braucht es oft (Maß ändern, ohne dass der Rest wandert)
        return [
            [Row(id: ConstraintKind.lock.rawValue, systemImage: ConstraintKind.lock.systemImage, action: .constraint(.lock),
                 applicable: sketch.canApply(.lock))],
            kinds,
            [Row(id: "Trennen", systemImage: "link.badge.plus", action: .detach,
                 applicable: hasSelection && sketch.selectionHasConstraints)],
            [Row(id: "Konstruktion erstellen", systemImage: "sc.construction", action: .construction, applicable: hasSelection)],
        ]
    }

    var body: some View {
        let groups = self.groups
        VStack(alignment: .trailing, spacing: 8) {
            if let pending = sketch.pendingAction {
                Button {
                    sketch.cancelPending()
                } label: {
                    HStack(spacing: 6) {
                        Text("„\(pending.title)“ aktiv")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .hoverTip("Einschränkung beenden", "Tippen beendet das Setzen. Solange sie aktiv ist, wählen Stift und Finger nur aus.")
            }
            ForEach(groups.indices, id: \.self) { index in
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(groups[index]) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 2)
                .background(alignment: .trailing) {
                    FloatingShape(shape: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous),
                                  fill: Theme.surface)
                        .frame(width: 44)
                }
            }
        }
        .disabled(!isEnabled)
    }

    /// SF Symbol: aktiv weiß auf Akzentfarbe, passend blau, sonst grau. SolidCraft-Bild: aktiv heller Grund mit
    /// Rahmen, nicht passend grau und blass.
    @ViewBuilder private func rowIcon(_ row: Row, pending: Bool, active: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous)
        if ToolIcon.isCustom(row.systemImage) {
            ToolIcon(row.systemImage, size: 24)
                .saturation(active ? 1 : 0)
                .opacity(active ? 1 : (isEnabled ? 0.55 : 0.3))
                .frame(width: 38, height: 34)
                .background(pending ? Color.accentColor.opacity(0.22) : Color.clear, in: shape)
                .overlay {
                    if pending {
                        shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        } else {
            Image(systemName: row.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(pending ? Color.white
                                 : active ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.75 : 0.35))
                .frame(width: 38, height: 34)
                .background(pending ? Color.accentColor : Color.clear, in: shape)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let pending = sketch.pendingAction == row.action
        let active = isEnabled && (row.applicable || pending)
        return Button {
            sketch.start(row.action)
        } label: {
            HStack(spacing: 8) {
                RailLabel(title: row.id, dimmed: !active && !isEnabled)
                rowIcon(row, pending: pending, active: active)
                    .frame(width: 44, height: 38)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.id)
        .hoverTip(row.id)
    }
}

/// Säule mit mehreren Knöpfen auf gemeinsamem weißem Grund (rechte Leiste im Skizzenmodus).
struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .floatingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
    }
}

/// Name neben einem Knopf der rechten Leiste, wie bei Shapr3D als helles Schild.
struct RailLabel: View {
    let title: String
    var subtitle: String?
    var dimmed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title)
                .font(Theme.labelFont)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
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
}

/// Runder Knopf der rechten Leiste.
struct RailButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailIcon(systemImage: systemImage, isActive: isActive)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .hoverTip(label)
    }
}

struct RailIcon: View {
    let systemImage: String
    var isActive = false
    var shadowed = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .floatingSurface(isActive ? Color.accentColor : Theme.surface, in: Circle(), elevation: shadowed ? .raised : .inset)
            .animation(Theme.snappy, value: isActive)
    }
}

/// Würfel, der die Blickrichtung zeigt. Antippen einer Seite dreht die Ansicht senkrecht auf diese Seite,
/// Antippen nahe einer Kante bzw. Ecke schräg auf diese (wie Fusion). Ziehen mit Stift oder Finger dreht die
/// Ansicht frei um den Drehpunkt und läuft beim Loslassen kurz nach (CameraMotion.swift).
struct ViewCube: View {
    @ObservedObject var camera: CameraState
    let motion: CameraMotion
    let look: (SIMD3<Float>) -> Void

    private let size: CGFloat = 92
    /// Bis zu dieser Strecke (Punkte) gilt eine Berührung als Antippen, darüber wird gedreht.
    private static let tapSlop: CGFloat = 5
    /// Anteil der halben Seitenlänge, ab dem ein Tipp als Kante bzw. Ecke zählt
    private static let edgeZone: CGFloat = 0.6
    /// Zeitfenster für die Loslass-Geschwindigkeit (Sekunden)
    private static let velocityWindow: TimeInterval = 0.08

    /// Ziehzustand als Referenz: Ändern baut die Ansicht nicht neu auf.
    private final class DragTracker {
        var last = CGSize.zero
        var isTurning = false
        var samples: [(time: Date, translation: CGSize)] = []

        func record(_ value: DragGesture.Value) {
            samples.append((time: value.time, translation: value.translation))
            let oldest = value.time.addingTimeInterval(-ViewCube.velocityWindow)
            samples.removeAll { $0.time < oldest }
        }

        /// Geschwindigkeit der letzten Bewegung in Punkten/s (Stift vor dem Abheben angehalten → fast null).
        var velocity: CGSize {
            guard samples.count >= 2, let first = samples.first, let latest = samples.last else { return .zero }
            let dt = latest.time.timeIntervalSince(first.time)
            guard dt > 0.005 else { return .zero }
            let vx: CGFloat = (latest.translation.width - first.translation.width) / dt
            let vy: CGFloat = (latest.translation.height - first.translation.height) / dt
            return CGSize(width: vx, height: vy)
        }

        func reset() {
            last = .zero
            isTurning = false
            samples = []
        }
    }

    @State private var tracker = DragTracker()

    private struct Side {
        let name: String
        let normal: SIMD3<Float>
        let a: SIMD3<Float>
        let b: SIMD3<Float>

        var corners: [SIMD3<Float>] { [normal - a - b, normal + a - b, normal + a + b, normal - a + b] }
    }

    /// Z oben, „Vorne“ blickt in +Y-Richtung (CAD-Konvention).
    private static let sides = [
        Side(name: "Oben", normal: [0, 0, 1], a: [1, 0, 0], b: [0, 1, 0]),
        Side(name: "Unten", normal: [0, 0, -1], a: [1, 0, 0], b: [0, 1, 0]),
        Side(name: "Vorne", normal: [0, -1, 0], a: [1, 0, 0], b: [0, 0, 1]),
        Side(name: "Hinten", normal: [0, 1, 0], a: [1, 0, 0], b: [0, 0, 1]),
        Side(name: "Rechts", normal: [1, 0, 0], a: [0, 1, 0], b: [0, 0, 1]),
        Side(name: "Links", normal: [-1, 0, 0], a: [0, 1, 0], b: [0, 0, 1]),
    ]

    /// Sichtbare Seiten, die hinterste zuerst.
    private static func visibleSides(_ projection: Projection) -> [(side: Side, facing: Float)] {
        sides
            .map { (side: $0, facing: simd_dot($0.normal, projection.toCamera)) }
            .filter { $0.facing > 0.01 }
            .sorted { $0.facing < $1.facing }
    }

    var body: some View {
        let projection = Projection(yaw: camera.yaw, pitch: camera.pitch, size: size)
        let visible = Self.visibleSides(projection)

        Canvas { context, _ in
            for entry in visible {
                var path = Path()
                path.addLines(entry.side.corners.map(projection.point))
                path.closeSubpath()
                let shade = 0.82 + 0.18 * Double(entry.facing)
                context.fill(path, with: .color(Color(white: shade)))
                context.stroke(path, with: .color(Color(white: 0.55)), lineWidth: 1)
                if entry.facing > 0.3 {
                    let text = Text(entry.side.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.2))
                    context.draw(text, at: projection.point(entry.side.normal))
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        // Ein Griff für Antippen und Ziehen: erst ab tapSlop Punkten wird gedreht, sonst gilt es als Antippen.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in dragChanged(value) }
                .onEnded { value in dragEnded(value) }
        )
        .accessibilityLabel("Ansichtswürfel")
    }

    private func dragChanged(_ value: DragGesture.Value) {
        // Aufsetzen fängt eine noch nachlaufende Drehung ab
        if tracker.samples.isEmpty, !tracker.isTurning { motion.stop() }
        tracker.record(value)
        let t = value.translation
        if !tracker.isTurning {
            guard hypot(t.width, t.height) > Self.tapSlop else { return }
            tracker.isTurning = true
        }
        turn(to: t)
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if tracker.isTurning {
            tracker.record(value)
            turn(to: value.translation)
            motion.fling(velocity: tracker.velocity)
        } else if let direction = direction(at: value.startLocation) {
            look(direction)
        }
        tracker.reset()
    }

    /// Dreht die Kamera um die Strecke seit dem letzten Aufruf (folgt dem Stift direkt).
    private func turn(to translation: CGSize) {
        let dx: CGFloat = translation.width - tracker.last.width
        let dy: CGFloat = translation.height - tracker.last.height
        tracker.last = translation
        if dx != 0 || dy != 0 {
            motion.drag(dx: dx, dy: dy)
        }
    }

    /// Blickrichtung unter dem Punkt: Mitte einer Seite = senkrecht auf die Seite, Rand = Kante, Ecke = Ecke.
    private func direction(at location: CGPoint) -> SIMD3<Float>? {
        let projection = Projection(yaw: camera.yaw, pitch: camera.pitch, size: size)
        let origin = projection.point(SIMD3<Float>(0, 0, 0))
        // Vorderste Seite unter dem Finger
        for entry in Self.visibleSides(projection).reversed() {
            let side = entry.side
            let center = projection.point(side.normal)
            let pa = projection.point(side.a)
            let pb = projection.point(side.b)
            // Parallelprojektion: Punkt = Mitte + s·A + t·B mit s, t in −1…1 auf der Seite
            let ax: CGFloat = pa.x - origin.x, ay: CGFloat = pa.y - origin.y
            let bx: CGFloat = pb.x - origin.x, by: CGFloat = pb.y - origin.y
            let det: CGFloat = ax * by - ay * bx
            guard abs(det) > 1e-3 else { continue }
            let dx: CGFloat = location.x - center.x, dy: CGFloat = location.y - center.y
            let s: CGFloat = (dx * by - dy * bx) / det
            let t: CGFloat = (ax * dy - ay * dx) / det
            guard abs(s) <= 1, abs(t) <= 1 else { continue }
            var direction = side.normal
            if abs(s) > Self.edgeZone {
                let sign: Float = s > 0 ? 1 : -1
                direction += sign * side.a
            }
            if abs(t) > Self.edgeZone {
                let sign: Float = t > 0 ? 1 : -1
                direction += sign * side.b
            }
            return direction
        }
        return nil
    }

    /// Parallelprojektion des Würfels passend zur Kamera.
    private struct Projection {
        let toCamera: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let scale: CGFloat
        let center: CGPoint

        init(yaw: Float, pitch: Float, size: CGFloat) {
            let cp = cos(pitch)
            toCamera = SIMD3(cp * cos(yaw), cp * sin(yaw), sin(pitch))
            let forward = -toCamera
            right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
            up = simd_cross(right, forward)
            scale = size * 0.26
            center = CGPoint(x: size / 2, y: size / 2)
        }

        func point(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: center.x + CGFloat(simd_dot(p, right)) * scale,
                    y: center.y - CGFloat(simd_dot(p, up)) * scale)
        }
    }
}
