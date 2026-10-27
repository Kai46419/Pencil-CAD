import SwiftUI

// Abschnitte „Verformen“ und „Am Pfad ausrichten“ im rechten Fenster, wenn ein Text gewählt ist
// (Logik in SketchTextDeform.swift und SketchTextDeformHandles.swift).

/// Verformen des gewählten Texts: Modus der Griffe, Hüllen-Vorlagen mit Stärke, Werte, Zurücksetzen.
struct SketchTextDeformSection: View {
    @ObservedObject var sketch: SketchController
    let index: Int

    /// Schieberegler „Stärke“: läuft gerade (ein Schritt zum Rückgängigmachen je Zug)
    @State private var bendDragging = false

    var body: some View {
        if let text = sketch.sketchText(at: index) {
            let deform = text.deform ?? SketchTextDeform()
            let mode = sketch.textDeformMode
            PaletteSection("Verformen", detail: activeMode.map(\.rawValue)) {
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    IconSegment(choices: modeChoices(onPath: deform.path != nil),
                                selected: activeMode.map { Set([$0.rawValue]) } ?? Set<String>()) { id in
                        let picked = SketchTextDeformMode(rawValue: id)
                        sketch.textDeformMode = picked == mode ? nil : picked
                    }
                    if let activeMode {
                        Text(activeMode.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if deform.path != nil, SketchTextDeformMode.handleModes.contains(where: { $0 == mode }) {
                        Text("Am Pfad gelten nur Breite, Höhe und Verzerren aus den Feldern.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if mode == .envelope, deform.path == nil {
                        envelopeControls(deform)
                    }
                    PaletteNumberRow(title: "Breite", value: deform.stretch.x * 100, unit: "%") { value in
                        guard value > 1 else { return }
                        sketch.updateTextDeform(at: index) { $0.stretch.x = value / 100 }
                    }
                    PaletteNumberRow(title: "Höhe", value: deform.stretch.y * 100, unit: "%") { value in
                        guard value > 1 else { return }
                        sketch.updateTextDeform(at: index) { $0.stretch.y = value / 100 }
                    }
                    PaletteNumberRow(title: "Neigung", value: atan(deform.shear.x) * 180 / .pi, unit: "°") { value in
                        guard abs(value) < 80 else { return }
                        sketch.updateTextDeform(at: index) { $0.shear.x = tan(value * .pi / 180) }
                    }
                    if text.deform != nil {
                        PrimaryWideButton(title: "Zurücksetzen", systemImage: "arrow.counterclockwise", isPrimary: false) {
                            sketch.updateText(at: index) { $0.with(deform: .some(nil)) }
                            if sketch.textDeformMode == .path { sketch.textDeformMode = nil }
                        }
                        .hoverTip("Zurücksetzen", "Entfernt Breite, Höhe, Verzerren, Perspektive, Hülle und Pfad.")
                    }
                }
            }
        }
    }

    /// Modus, dessen Griffe gerade sichtbar sind (Pfad wählen zählt nicht).
    private var activeMode: SketchTextDeformMode? {
        guard let mode = sketch.textDeformMode, SketchTextDeformMode.handleModes.contains(mode) else { return nil }
        return mode
    }

    private func modeChoices(onPath: Bool) -> [IconChoice] {
        SketchTextDeformMode.handleModes.map { mode in
            // Am Pfad gibt es keine Hülle und keine Perspektive
            let enabled = !onPath || mode == .free || mode == .shear
            return IconChoice(id: mode.rawValue, title: mode.rawValue, icon: mode.systemImage, isEnabled: enabled)
        }
    }

    @ViewBuilder private func envelopeControls(_ deform: SketchTextDeform) -> some View {
        let warp = deform.warp
        IconSegment(choices: SketchTextWarpStyle.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue,
                                                                             icon: $0.systemImage) },
                    selected: warp.map { Set([$0.style.rawValue]) } ?? Set<String>()) { id in
            guard let style = SketchTextWarpStyle(rawValue: id) else { return }
            sketch.updateTextDeform(at: index) { value in
                let bend = value.warp?.bend ?? 0
                value.warp = SketchTextWarp(style: style, bend: abs(bend) < 1e-9 ? 0.5 : bend)
            }
        }
        if let warp {
            PaletteLabeled(title: "Stärke \(Int((warp.bend * 100).rounded())) %") {
                Slider(value: bendBinding(warp), in: -1...1) { editing in
                    if !editing { finishBend() }
                }
            }
        }
    }

    /// Stärke live ziehen: der erste Wert legt den Rückgängig-Schritt an, das Loslassen baut Bereiche neu.
    private func bendBinding(_ warp: SketchTextWarp) -> Binding<Double> {
        Binding(get: { sketch.sketchText(at: index)?.deform?.warp?.bend ?? warp.bend },
                set: { value in
                    guard let text = sketch.sketchText(at: index) else { return }
                    var deform = text.deform ?? SketchTextDeform()
                    let snapped: Double = abs(value) < 0.03 ? 0 : value
                    deform.warp = SketchTextWarp(style: deform.warp?.style ?? warp.style, bend: snapped)
                    let changed = text.with(deform: .some(deform))
                    guard !changed.loops.isEmpty else { return }
                    sketch.setDraggedElement(.text(changed), at: index, begin: !bendDragging, final: false)
                    bendDragging = true
                })
    }

    private func finishBend() {
        guard bendDragging, let text = sketch.sketchText(at: index) else { return }
        bendDragging = false
        sketch.setDraggedElement(.text(text), at: index, begin: false, final: true)
    }
}

/// Text am Pfad: Kurve wählen bzw. Hilfsbogen anlegen, Optionen (Kontur folgen, Seite, Abstand, Versatz,
/// Ausrichtung, Umkehren), lösen.
struct SketchTextPathSection: View {
    @ObservedObject var sketch: SketchController
    let index: Int

    var body: some View {
        if let text = sketch.sketchText(at: index) {
            let path = text.deform?.path
            PaletteSection("Am Pfad ausrichten", detail: path == nil ? nil : (path?.source == nil ? "Kante" : "Kurve")) {
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    if sketch.textDeformMode == .pickPath {
                        Text(SketchTextDeformMode.pickPath.hint)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: PaletteStyle.spacing) {
                        PrimaryWideButton(title: "Pfad wählen", systemImage: "hand.tap", isPrimary: false,
                                          isActive: sketch.textDeformMode == .pickPath, showsTitle: false) {
                            sketch.textDeformMode = sketch.textDeformMode == .pickPath ? nil : .pickPath
                        }
                        .hoverTip("Pfad wählen", "Danach eine Linie, einen Bogen, Kreis, Spline, Linienzug oder eine projizierte Körperkante antippen.")
                        PrimaryWideButton(title: "Bogen-Vorlage", systemImage: "rainbow", isPrimary: false,
                                          showsTitle: false) {
                            sketch.addTextArcTemplate(at: index)
                        }
                        .hoverTip("Bogen-Vorlage", "Legt einen Hilfsbogen über den Text und richtet ihn daran aus. Der Griff im Scheitel zieht die Krümmung.")
                        if path != nil {
                            PrimaryWideButton(title: "Vom Pfad lösen", systemImage: "link.badge.plus", isPrimary: false,
                                              showsTitle: false) {
                                sketch.updateTextDeform(at: index) { $0.path = nil }
                                if sketch.textDeformMode == .path { sketch.textDeformMode = nil }
                            }
                            .hoverTip("Vom Pfad lösen", "Der Text steht wieder gerade.")
                        }
                    }
                    if let path {
                        options(path)
                    }
                }
            }
        }
    }

    @ViewBuilder private func options(_ path: SketchTextPath) -> some View {
        PrimaryWideButton(title: "Startgriff", systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                          isPrimary: false, isActive: sketch.textDeformMode == .path) {
            sketch.textDeformMode = sketch.textDeformMode == .path ? nil : .path
        }
        .hoverTip("Startgriff", "Zeigt den Griff am Textanfang: ziehen verschiebt den Text entlang der Kurve.")
        CheckRow(title: "Kontur folgen", icon: "scribble.variable", isOn: binding(\.bends))
        CheckRow(title: "Unterhalb", icon: "arrow.down.to.line", isOn: binding(\.below))
        CheckRow(title: "Umkehren", icon: "arrow.left.arrow.right", isOn: binding(\.reversed))
        Picker("Ausrichtung", selection: binding(\.alignment)) {
            ForEach(TextAlignmentOption.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        PaletteNumberRow(title: "Startversatz", value: path.offset) { value in
            sketch.updateTextPath(at: index) { $0.offset = value }
        }
        PaletteNumberRow(title: "Abstand", value: path.distance) { value in
            sketch.updateTextPath(at: index) { $0.distance = value }
        }
    }

    private func binding<Value: Equatable>(_ key: WritableKeyPath<SketchTextPath, Value>) -> Binding<Value> {
        Binding(get: {
                    guard let path = sketch.sketchText(at: index)?.deform?.path else {
                        return SketchTextPath(points: [], closed: false)[keyPath: key]
                    }
                    return path[keyPath: key]
                },
                set: { value in
                    guard sketch.sketchText(at: index)?.deform?.path?[keyPath: key] != value else { return }
                    sketch.updateTextPath(at: index) { $0[keyPath: key] = value }
                })
    }
}
