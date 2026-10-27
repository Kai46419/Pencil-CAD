import SwiftUI
import simd

// Bohrung nach SolidCraft (MIT, dialogs.rs Hole, dialogs_dense.rs): Positionen (Flächen antippen, rastet an Ecken,
// Kantenmitten, Kreismitten) · Einzeln/Mehrfach · Bezug 1/2 (gerade Kanten mit Abstand, nur Einzeln auf ebener
// Fläche) · Ausmaß Abstand/Alle · Bohrungsart · Schnittbild · Maße · Gewinde · Bohrspitze · Zugabe · Vorlagen.
// Die Maße stehen in Workspace.holeSpec (wie im alten Bohrungswerkzeug), die Stellen in Workspace.holePoints;
// tool = .hole zeigt die Bohrstellen und den Fangpunkt im Viewport.

enum HoleCommand: ModelCommandDriver {
    static let id: ModelCommandID = .hole
    static let title = "Bohrung"
    static let icon = "sc.hole"
    static var explanation: String? {
        "Fläche antippen (eben oder gewölbt) – die Stelle rastet an Ecken, Kantenmitten und Kreismitten. Eine "
            + "Bohrung erneut antippen entfernt sie. Mit Bezügen (gerade Kanten) liegt eine Einzelbohrung im "
            + "eingegebenen Abstand."
    }

    enum Key {
        static let distance1 = "ref1Distance"
        static let distance2 = "ref2Distance"
    }

    static func positionsInput() -> PickInput {
        PickInput(id: "positions", title: "Position", accepts: [.faces], multiple: true,
                  hint: "Stelle auf einer Fläche antippen (eben oder gewölbt)")
    }

    static func referenceInput(_ number: Int) -> PickInput {
        PickInput(id: "ref\(number)", title: "Bezug \(number)", accepts: [.edges], multiple: false,
                  hint: "Gerade Kante antippen, von der aus gemessen wird", isOptional: true)
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let cmd = ModelCommand(.hole, inputs: [positionsInput()])
        cmd.choices["placement"] = "multiple"
        cmd.setNumber(Key.distance1, 10)
        cmd.setNumber(Key.distance2, 10)
        ws.setHolePoints([])
        ws.tool = .hole
        return cmd
    }

    static func isSingle(_ cmd: ModelCommand) -> Bool {
        cmd.choice("placement", default: "multiple") == "single"
    }

    /// Bezugsfelder nur bei Einzelbohrung
    static func syncInputs(_ cmd: ModelCommand) {
        if isSingle(cmd) {
            cmd.ensureInput(referenceInput(1), after: "positions")
            cmd.ensureInput(referenceInput(2), after: "ref1")
        } else {
            cmd.removeInput("ref1")
            cmd.removeInput("ref2")
        }
    }

    // MARK: Bezüge

    /// Gerade Kante als Bezug in der Flächenebene: Richtung quer zur Kante (zur Bohrung hin) und ein Punkt der Kante.
    static func reference(_ pick: Pick?, toward p: SIMD3<Double>, normal n: SIMD3<Double>, model: ModelStore)
        -> (w: SIMD3<Double>, a: SIMD3<Double>)? {
        guard let pick, case .edge(let edge) = pick,
              let line = model.edgePolylines(edge).first, ModelStore.circleCenter(line) == nil,
              let axis = CommandGeometry.edgeAxis(edge, model: model) else { return nil }
        var e: SIMD3<Double> = axis.direction
        e -= n * simd_dot(e, n)
        guard simd_length(e) > 1e-6 else { return nil }
        e = simd_normalize(e)
        var w: SIMD3<Double> = simd_cross(n, e)
        if simd_dot(p - axis.origin, w) < 0 { w = -w }
        return (w, axis.origin)
    }

    /// Bohrstelle nach den Bezügen verschieben (eine Kante: quer dazu, zwei Kanten: Schnitt der beiden Abstände).
    static func adjusted(_ hole: HolePoint, _ cmd: ModelCommand, _ model: ModelStore) -> (point: SIMD3<Double>, note: String?) {
        guard isSingle(cmd), let plane = model.plane(of: hole.face) else {
            return (hole.point, cmd.items("ref1").isEmpty ? nil : "Bezüge gelten nur auf ebenen Flächen.")
        }
        let n: SIMD3<Double> = simd_normalize(plane.normal)
        let p = hole.point
        let first = reference(cmd.items("ref1").first, toward: p, normal: n, model: model)
        let second = reference(cmd.items("ref2").first, toward: p, normal: n, model: model)
        let d1 = max(0, cmd.number(Key.distance1, default: 10))
        let d2 = max(0, cmd.number(Key.distance2, default: 10))
        if let first, let second {
            let m = simd_double3x3(rows: [first.w, second.w, n])
            if abs(m.determinant) > 1e-6 {
                let b = SIMD3<Double>(simd_dot(first.a, first.w) + d1, simd_dot(second.a, second.w) + d2, simd_dot(p, n))
                return (m.inverse * b, nil)
            }
            let moved: SIMD3<Double> = p + first.w * (d1 - simd_dot(p - first.a, first.w))
            return (moved, "Bezug 2 liegt parallel zu Bezug 1 – nur Bezug 1 gilt.")
        }
        if let only = first ?? second {
            let d = first != nil ? d1 : d2
            return (p + only.w * (d - simd_dot(p - only.a, only.w)), nil)
        }
        let picked = !cmd.items("ref1").isEmpty || !cmd.items("ref2").isEmpty
        return (p, picked ? "Als Bezug nur gerade Kanten, die nicht senkrecht zur Fläche stehen." : nil)
    }

    // MARK: Vorschau

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let synced = Int(cmd.choice("holeCount", default: "0")) ?? 0
        if cmd.items("positions").isEmpty, synced > 0, !ws.holePoints.isEmpty {
            // „×“ im Feld: alle Stellen entfernen
            ws.setHolePoints([])
        }
        var points = ws.holePoints
        var note: String?
        if points.count == 1 {
            let result = adjusted(points[0], cmd, model)
            note = result.note
            if simd_distance(result.point, points[0].point) > 1e-6 {
                points[0].point = result.point
                ws.setHolePoints(points)
            }
        }
        cmd.setItems("positions", points.map { Pick.point($0.point) })
        cmd.choices["holeCount"] = String(points.count)
        guard !points.isEmpty else {
            model.dropPreview()
            return nil
        }
        model.message = nil
        model.previewHoles(points.map { (face: $0.face, point: $0.point) }, spec: ws.holeSpec)
        guard model.hasPreview else { return model.message ?? "An dieser Stelle ist keine Bohrung möglich." }
        if let note { model.message = note }
        return nil
    }

    // MARK: Antippen

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        let model = ws.model
        let activeID: String = cmd.inputs.indices.contains(cmd.activeInput) ? cmd.inputs[cmd.activeInput].id : "positions"
        if activeID == "ref1" || activeID == "ref2" {
            guard let edge = tap.edge else {
                model.message = "Für den Bezug eine gerade Kante antippen."
                return true
            }
            if model.hasPreview {
                // Die Vorschau zeigt andere Kantennummern: ohne Vorschau neu antippen lassen
                model.dropPreview()
                model.message = "Kante bitte noch einmal antippen."
                return true
            }
            cmd.setItems(activeID, [.edge(edge)])
            // Abstand vorschlagen: wie weit die Bohrung jetzt von der Kante entfernt ist
            if let hole = ws.holePoints.first, let plane = model.plane(of: hole.face),
               let ref = reference(.edge(edge), toward: hole.point, normal: simd_normalize(plane.normal), model: model) {
                let distance: Double = (simd_dot(hole.point - ref.a, ref.w) * 100).rounded() / 100
                cmd.setNumber(activeID == "ref1" ? Key.distance1 : Key.distance2, distance)
            }
            cmd.advance()
            if cmd.inputs.indices.contains(cmd.activeInput), cmd.inputs[cmd.activeInput].id == activeID {
                cmd.activeInput = 0
            }
            ws.refreshCommandPreview()
            return true
        }
        guard let face = tap.face else { return tap.edge != nil }
        if isSingle(cmd) { ws.setHolePoints([]) }
        ws.holeTapped(face: face, point: tap.point.map { SIMD3<Float>($0) })
        cmd.error = nil
        // holeTapped rechnet die Vorschau (updateHolePreview → refreshCommandPreview)
        return true
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        !ws.holePoints.isEmpty && cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
        ws.setHolePoints([])
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.setHolePoints([])
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(HoleRows(cmd: cmd, ws: ws, model: ws.model))
    }
}

private struct HoleRows: View {
    @ObservedObject var cmd: ModelCommand
    @ObservedObject var ws: Workspace
    @ObservedObject var model: ModelStore

    private typealias Key = HoleCommand.Key

    private static let placementOptions: [SegmentOption] = [
        SegmentOption(id: "single", label: "Einzeln"),
        SegmentOption(id: "multiple", label: "Mehrfach"),
    ]

    private static let extentOptions: [SegmentOption] = [
        SegmentOption(id: "distance", label: "Abstand"),
        SegmentOption(id: "all", label: "Alle"),
    ]

    private static let kindOptions: [SegmentOption] = HoleKind.allCases.map { SegmentOption(id: $0.rawValue, label: $0.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSegmentRow(title: "Platzierung", options: Self.placementOptions,
                            selected: cmd.choice("placement", default: "multiple")) { id in
                cmd.choices["placement"] = id
                if id == "single", ws.holePoints.count > 1, let last = ws.holePoints.last {
                    ws.setHolePoints([last])
                }
                HoleCommand.syncInputs(cmd)
                ws.refreshCommandPreview()
            }
            if HoleCommand.isSingle(cmd) {
                if !cmd.items("ref1").isEmpty {
                    value("Abstand 1", Key.distance1, current: cmd.number(Key.distance1, default: 10)) { v in
                        cmd.setNumber(Key.distance1, max(0, v))
                    }
                }
                if !cmd.items("ref2").isEmpty {
                    value("Abstand 2", Key.distance2, current: cmd.number(Key.distance2, default: 10)) { v in
                        cmd.setNumber(Key.distance2, max(0, v))
                    }
                }
            } else if !ws.holePoints.isEmpty {
                Button {
                    ws.removeLastHole()
                } label: {
                    Label("Letzte entfernen", systemImage: "arrow.uturn.backward")
                        .font(.callout)
                        .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SketchTheme.accent)
            }
            presetMenu
            PanelSegmentRow(title: "Bohrungsart", options: Self.kindOptions, selected: ws.holeSpec.kind.rawValue) { id in
                guard let kind = HoleKind(rawValue: id) else { return }
                ws.holeSpec.kind = kind
                ws.refreshCommandPreview()
            }
            HoleSectionView(spec: ws.holeSpec)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
            PanelSegmentRow(title: "Ausmaß", options: Self.extentOptions,
                            selected: ws.holeSpec.through ? "all" : "distance") { id in
                ws.holeSpec.through = id == "all"
                ws.refreshCommandPreview()
            }
            sizeRows
            CommandSection("Gewinde", command: .hole, section: "thread", expanded: false,
                           forceOpen: ws.holeSpec.thread != nil) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HoleThreadRow(workspace: ws)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var sizeRows: some View {
        let spec = ws.holeSpec
        if spec.thread == nil {
            specValue("Durchmesser", "diameter", \.diameter)
        }
        if !spec.through {
            specValue("Tiefe", "depth", \.depth)
            CheckRow(title: "Bohrspitze (118°)", isOn: Binding(get: { ws.holeSpec.drillPoint }, set: { on in
                ws.holeSpec.drillPoint = on
                ws.refreshCommandPreview()
            }))
        }
        switch spec.kind {
        case .simple:
            EmptyView()
        case .counterbore:
            specValue("Senkung Ø", "counterDiameter", \.counterDiameter)
            specValue("Senktiefe", "counterDepth", \.counterDepth)
        case .countersink:
            specValue("Senkung Ø", "counterDiameter", \.counterDiameter)
            specValue("Winkel", "sinkAngle", \.sinkAngle, unit: "°", minimum: 1)
        }
        specValue("Zugabe", "clearance", \.clearance, minimum: 0)
    }

    private var presetMenu: some View {
        PanelMenuRow(title: "Vorlage", value: "Wählen") {
            ForEach(HoleSpec.presets.indices, id: \.self) { group in
                Section(HoleSpec.presets[group].group) {
                    ForEach(HoleSpec.presets[group].items.indices, id: \.self) { item in
                        let preset = HoleSpec.presets[group].items[item]
                        Button(preset.name) {
                            ws.holeSpec = preset.spec
                            ws.refreshCommandPreview()
                        }
                    }
                }
            }
        }
    }

    private func specValue(_ title: String, _ key: String, _ keyPath: WritableKeyPath<HoleSpec, Double>,
                           unit: String = "mm", minimum: Double = 0.01) -> some View {
        value(title, key, unit: unit, current: ws.holeSpec[keyPath: keyPath]) { newValue in
            guard newValue >= minimum else { return }
            ws.holeSpec[keyPath: keyPath] = newValue
        }
    }

    private func value(_ title: String, _ key: String, unit: String = "mm", current: Double,
                       set: @escaping (Double) -> Void) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, unit: unit, value: current) { newValue in
            set(newValue)
            ws.refreshCommandPreview()
        }
    }
}

/// Schnittbild der Bohrung (Halbschnitt durch die Achse), maßstäblich.
private struct HoleSectionView: View {
    let spec: HoleSpec

    var body: some View {
        Canvas { context, size in
            let r = max(0.1, (spec.diameter + spec.clearance) / 2)
            let wide = spec.kind == .simple ? r : max(r, (spec.counterDiameter + spec.clearance) / 2)
            let depth = spec.through ? max(spec.depth, wide * 2.5) : max(0.1, spec.depth)
            let tip: Double = spec.drillPoint && !spec.through ? r / tan(59 * .pi / 180) : 0
            let materialHeight = spec.through ? depth : depth + tip + max(r, depth * 0.25)
            let halfWidth = wide * 2.2
            let scale = min(Double(size.width) / (halfWidth * 2), Double(size.height - 18) / materialHeight)
            let centerX = Double(size.width) / 2
            let top = 14.0
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: centerX + x * scale, y: top + y * scale)
            }
            // Halbprofil rechts (x = Radius, y = Tiefe ab der Fläche)
            var right: [(Double, Double)] = []
            switch spec.kind {
            case .simple:
                right = [(r, 0)]
            case .counterbore:
                let R = (spec.counterDiameter + spec.clearance) / 2
                let cd = min(spec.counterDepth, depth)
                right = R > r ? [(R, 0), (R, cd), (r, cd)] : [(r, 0)]
            case .countersink:
                let R = (spec.counterDiameter + spec.clearance) / 2
                let half = max(1, min(89, spec.sinkAngle / 2)) * .pi / 180
                right = R > r ? [(R, 0), (r, min(depth, (R - r) / tan(half)))] : [(r, 0)]
            }
            right.append((r, depth))
            var hole = Path()
            hole.move(to: point(right[0].0, right[0].1))
            for p in right.dropFirst() { hole.addLine(to: point(p.0, p.1)) }
            if tip > 0 { hole.addLine(to: point(0, depth + tip)) }
            for p in right.reversed() { hole.addLine(to: point(-p.0, p.1)) }
            hole.closeSubpath()
            let material = Path(CGRect(x: centerX - halfWidth * scale, y: top, width: halfWidth * 2 * scale,
                                       height: materialHeight * scale))
            context.fill(material, with: .color(Color.gray.opacity(0.35)))
            context.fill(hole, with: .color(PaletteStyle.field))
            context.stroke(hole, with: .color(SketchTheme.accent), lineWidth: 1.5)
            var axis = Path()
            axis.move(to: point(0, -0.5))
            axis.addLine(to: point(0, materialHeight))
            context.stroke(axis, with: .color(Color.secondary), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            let diameterText: String = (2 * r).formatted(.number.precision(.fractionLength(0...2)))
            let depthText: String = spec.depth.formatted(.number.precision(.fractionLength(0...2)))
            let label: String = spec.through ? "Ø \(diameterText) · durch" : "Ø \(diameterText) × \(depthText)"
            context.draw(Text(label).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: centerX, y: 6))
        }
        .accessibilityLabel("Schnittbild der Bohrung")
        .accessibilityValue(spec.summary)
    }
}

// MARK: - Gewinde

/// Gewinde (Bolzen, Bohrung oder Gewindebohrung am Tippunkt) mit dem vorhandenen Gewindewerkzeug
/// (ThreadPanel.swift); das Panel zeigt dessen Einstellungen.
enum ThreadCommand: ModelCommandDriver {
    static let id: ModelCommandID = .thread
    static let title = "Gewinde"
    static let icon = "sc.thread"
    static var explanation: String? {
        "Fläche antippen: Bolzen = Außengewinde, Bohrung = Innengewinde, jede andere Fläche = Gewindebohrung am "
            + "Tippunkt. Eine Gewindebohrung erneut antippen entfernt sie."
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let input = PickInput(id: "faces", title: "Fläche", accepts: [.faces], multiple: true,
                              hint: "Bolzen, Bohrung oder eine Stelle für eine Gewindebohrung antippen")
        let cmd = ModelCommand(.thread, inputs: [input])
        ws.tool = .part(.thread)
        ws.startPart(.thread)
        return cmd
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let parts = ws.parts
        if cmd.items("faces").isEmpty, parts.thread.target != nil || !parts.threadHole.points.isEmpty,
           cmd.choices["synced"] == "1" {
            // „×“ im Feld: von vorn
            ws.startPart(.thread)
        }
        sync(cmd, ws)
        ws.updatePartPreview()
        return nil
    }

    private static func sync(_ cmd: ModelCommand, _ ws: Workspace) {
        let parts = ws.parts
        var items: [Pick] = parts.threadHole.points.map { Pick.point($0.point) }
        if parts.thread.target != nil, let first = cmd.items("faces").first { items = [first] }
        cmd.setItems("faces", items)
        cmd.choices["synced"] = items.isEmpty ? "0" : "1"
    }

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard let face = tap.face else { return tap.edge != nil }
        ws.threadTapped(face, point: tap.point.map { SIMD3<Float>($0) })
        if ws.parts.thread.target != nil {
            cmd.setItems("faces", [.face(face)])
            cmd.choices["synced"] = "1"
        } else {
            sync(cmd, ws)
        }
        cmd.error = nil
        return true
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ThreadRows(ws: ws, parts: ws.parts))
    }
}

private struct ThreadRows: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var parts: PartSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ws.partHint(.thread))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                ThreadCard(workspace: ws, parts: parts)
                    .font(.callout)
            }
            if parts.threadHole.lastTap != nil {
                Button {
                    ws.threadHoleAtLastTap()
                } label: {
                    Label("Gewindebohrung hier", systemImage: "scope")
                        .font(.callout)
                        .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SketchTheme.accent)
            }
        }
    }
}
