import SwiftUI
import simd

// MARK: - Werkzeug „Gewinde“ (Erstellen › Gewinde) und Option „Gewinde“ im Bohrungswerkzeug

extension Workspace {
    /// Fläche angetippt: Bolzen → Außengewinde, Bohrung → Innengewinde (passende Normgröße vorschlagen); jede andere
    /// Fläche (eben oder gewölbt, auch eine Rundung, die nicht ganz herum läuft) → Gewindebohrung am Tippunkt.
    func threadTapped(_ face: FaceRef, point: SIMD3<Float>?) {
        let tap: SIMD3<Double>? = point.map { SIMD3<Double>($0) }
        // Gesetzte Gewindebohrung erneut antippen: entfernen
        if parts.thread.target == nil, let tap, let index = threadHoleIndex(near: tap) {
            parts.threadHole.points.remove(at: index)
            updatePartPreview()
            return
        }
        model.cancelPreview()
        if let target = model.threadTarget(for: face), model.isFullRound(face, target: target) {
            var spec = parts.thread
            spec.target = target
            spec.offset = 0
            spec.fullLength = true
            spec.length = target.length
            spec.fromOtherEnd = false
            spec.sizeIndex = spec.family.suggestedSize(forDiameter: 2 * target.radius, external: target.external)
            spec.pitch = spec.size.pitch
            parts.thread = spec
            parts.threadHole.points = []
            // Stelle merken: „Gewindebohrung hier“ bohrt stattdessen quer hinein (z. B. Madenschraube in einer Nabe)
            let spot: SurfaceSpot? = tap.flatMap { model.holeSpot(on: face, near: $0, tolerance: pickTolerance) }
            parts.threadHole.lastTap = spot.map { HolePoint(face: face, point: $0.point) }
            updatePartPreview()
            return
        }
        guard let tap, let spot = model.holeSpot(on: face, near: tap, tolerance: pickTolerance) else {
            model.message = "Hier ist keine Gewindebohrung möglich – eine andere Stelle antippen."
            updatePartPreview()
            return
        }
        parts.thread.target = nil
        parts.threadHole.lastTap = nil
        parts.threadHole.points.append(HolePoint(face: face, point: spot.point))
        updatePartPreview()
    }

    /// Nummer der gesetzten Gewindebohrung nahe point (Antippen am Eingang der Bohrung).
    private func threadHoleIndex(near point: SIMD3<Double>) -> Int? {
        let reach: Double = max(pickTolerance, parts.thread.size.diameter / 2 + 0.5)
        return parts.threadHole.points.firstIndex { simd_distance($0.point, point) < reach }
    }

    /// Vorschau des Gewinde-Werkzeugs: Gewinde an Bolzen bzw. Bohrung oder Gewindebohrungen an den Tippunkten
    /// (gleiche Logik wie das Bohrungswerkzeug mit Gewinde).
    func previewThreadTool() {
        if parts.thread.target == nil, !parts.threadHole.points.isEmpty {
            let holes = parts.threadHole.points.map { (face: $0.face, point: $0.point) }
            model.previewHoles(holes, spec: parts.thread.holeSpec(parts.threadHole))
        } else {
            model.previewThread(parts.thread)
        }
    }

    /// Statt des Gewindes an Bolzen bzw. Bohrung eine Gewindebohrung an der angetippten Stelle.
    func threadHoleAtLastTap() {
        guard let tap = parts.threadHole.lastTap else { return }
        model.cancelPreview()
        parts.thread.target = nil
        parts.threadHole.lastTap = nil
        parts.threadHole.points = [tap]
        updatePartPreview()
    }

    func removeLastThreadHole() {
        guard !parts.threadHole.points.isEmpty else { return }
        parts.threadHole.points.removeLast()
        updatePartPreview()
    }

    /// Andere Gewindeart: Größe passend zur Fläche neu vorschlagen.
    func setThreadFamily(_ family: ThreadFamily) {
        var spec = parts.thread
        guard spec.family != family else { return }
        spec.family = family
        if let target = spec.target {
            spec.sizeIndex = family.suggestedSize(forDiameter: 2 * target.radius, external: target.external)
        } else {
            spec.sizeIndex = family.defaultSizeIndex
        }
        spec.pitch = spec.size.pitch
        parts.thread = spec
        updatePartPreview()
    }

    /// Andere Größe: Normsteigung übernehmen.
    func setThreadSize(_ index: Int) {
        var spec = parts.thread
        spec.sizeIndex = index
        spec.pitch = spec.size.pitch
        parts.thread = spec
        updatePartPreview()
    }

    /// Gewindebohrung ein/aus bzw. geändert: Kernlochbohrer übernehmen, Vorschau neu. Beim Einschalten gilt die
    /// zuletzt gewählte Toleranz-Vorlage als Zugabe.
    func setHoleThread(_ thread: HoleThread?) {
        var spec = holeSpec
        if spec.thread == nil, thread != nil, let preset = ThreadTolerancePreset.remembered {
            spec.clearance = preset.clearance
        }
        spec.thread = thread
        if let thread {
            spec.kind = .simple
            spec.diameter = (thread.tapDrill * 100).rounded() / 100
        }
        holeSpec = spec
        updateHolePreview()
    }
}

/// Text einer Steigung, bei Zollgewinden mit Gängen je Zoll.
private func pitchText(_ pitch: Double, family: ThreadFamily) -> String {
    let mm = pitch.formatted(.number.precision(.fractionLength(0...3)))
    guard family.usesThreadsPerInch else { return "\(mm) mm" }
    let tpi = (25.4 / pitch).formatted(.number.precision(.fractionLength(0...1)))
    return "\(mm) mm (\(tpi) Gg/Zoll)"
}

// MARK: - Parameterkarte

/// Inhalt der Karte des Gewinde-Werkzeugs (in PartCard).
struct ThreadCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var parts: PartSettings

    /// Bindung, die nach jeder Änderung die Vorschau neu rechnet.
    private func binding<T>(_ keyPath: WritableKeyPath<ThreadSpec, T>) -> Binding<T> {
        Binding(get: { parts.thread[keyPath: keyPath] }, set: { value in
            parts.thread[keyPath: keyPath] = value
            workspace.updatePartPreview()
        })
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<ThreadSpec, Double>, width: CGFloat = 56,
                       minimum: Double, maximum: Double) -> some View {
        NumberField(title: title, value: parts.thread[keyPath: keyPath], width: width) { value in
            guard value >= minimum, value <= maximum else { return }
            parts.thread[keyPath: keyPath] = value
            workspace.updatePartPreview()
        }
    }

    private var targetText: String {
        guard let target = parts.thread.target else {
            let count = parts.threadHole.points.count
            if count == 0 { return "Fläche antippen" }
            return count == 1 ? "Gewindebohrung · 1 Stelle" : "Gewindebohrung · \(count) Stellen"
        }
        let diameter = LengthUnit.current.format(2 * target.radius)
        return target.external ? "Außengewinde · Bolzen Ø \(diameter)" : "Innengewinde · Bohrung Ø \(diameter)"
    }

    private var infoText: String {
        let spec = parts.thread
        let form = spec.family.form
        // Gewindebohrung: immer eingängig (wie im Bohrungswerkzeug)
        let holeName: String? = spec.target == nil ? spec.holeSpec(parts.threadHole).thread?.designation : nil
        var text = "\(holeName ?? spec.designation) · \(form.angleText) · \(spec.family.standard)"
        if spec.starts > 1, spec.target != nil {
            let lead = spec.lead.formatted(.number.precision(.fractionLength(0...3)))
            text += " · \(lead) mm je Umdrehung"
        }
        if spec.family.isTapered { text += " · Kegel 1:16, Spitzen zylindrisch" }
        let inside: Bool = spec.target.map { !$0.external } ?? true
        if inside, !spec.family.isTapered {
            let drill: String = LengthUnit.current.format(spec.tapDrill)
            let source: String = spec.family.tapDrillIsTabulated(spec.size, pitch: spec.pitch) ? "Bohrer" : "gerechnet"
            text += " · Kernloch Ø \(drill) (\(source))"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("Gewinde", systemImage: PartTool.thread.systemImage)
                    .font(.callout.weight(.semibold))
                    .fixedSize()
                Picker("Art", selection: Binding(get: { parts.thread.family }, set: { workspace.setThreadFamily($0) })) {
                    ForEach(ThreadFamily.allCases) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Größe", selection: Binding(get: { parts.thread.sizeIndex }, set: { workspace.setThreadSize($0) })) {
                    ForEach(parts.thread.family.sizes.indices, id: \.self) { index in
                        Text(parts.thread.family.sizes[index].name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                pitchControl
                Text(targetText)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if parts.thread.target == nil {
                ThreadHoleControls(workspace: workspace, parts: parts)
            } else {
                surfaceControls
            }
            HStack(spacing: 12) {
                field("Druckspiel", \.clearance, width: 48, minimum: 0, maximum: 0.6)
                    .hoverTip("Druckspiel", "Für den 3D-Druck: Außengewinde werden radial um die Hälfte kleiner, Innengewinde um die Hälfte größer. 0,2 mm ist ein guter Anfang, 0 für exakte Normmaße.")
                ThreadTolerancePresetMenu(value: parts.thread.clearance) { value in
                    parts.thread.clearance = value
                    workspace.updatePartPreview()
                }
                if parts.thread.target != nil {
                    Toggle("Anschnitt", isOn: binding(\.chamfer))
                        .fixedSize()
                        .hoverTip("Anschnitt", "Fase am freien Ende des Bolzens bzw. Senkung am Eingang der Bohrung, damit Schraube und Mutter gut ansetzen.")
                    Button("Anderes Ende", systemImage: "arrow.up.arrow.down") {
                        parts.thread.fromOtherEnd.toggle()
                        workspace.updatePartPreview()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverTip("Anderes Ende", "Gewindeanfang (Versatz, Anschnitt) am anderen Ende der Fläche.")
                    if parts.threadHole.lastTap != nil {
                        Button("Gewindebohrung hier", systemImage: "smallcircle.filled.circle") {
                            workspace.threadHoleAtLastTap()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .hoverTip("Gewindebohrung hier", "Statt des Gewindes an Bolzen bzw. Bohrung eine Gewindebohrung an der angetippten Stelle quer in die Fläche (z. B. für eine Madenschraube).")
                    }
                }
                Text(infoText)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    /// Länge, Versatz, Gänge usw. für das Gewinde an Bolzen bzw. Bohrung.
    private var surfaceControls: some View {
        HStack(spacing: 12) {
            ThreadModePicker(cosmetic: parts.thread.cosmetic) { value in
                parts.thread.cosmetic = value
                workspace.updatePartPreview()
            }
            Toggle("Volle Länge", isOn: binding(\.fullLength))
                .fixedSize()
            if !parts.thread.fullLength {
                field("Länge", \.length, minimum: 0.1, maximum: 10_000)
            }
            field("Versatz", \.offset, minimum: 0, maximum: 10_000)
                .hoverTip("Versatz", "Abstand vom Gewindeanfang (freies Ende des Bolzens bzw. Eingang der Bohrung).")
            Text("Gänge")
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("Gänge", selection: binding(\.starts)) {
                ForEach(1...4, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .hoverTip("Gangzahl", "Mehrgängige Gewinde (z. B. Tr 8×8 mit P2 und 4 Gängen für Gewindespindeln): Steigung je Umdrehung = Gangzahl × Steigung.")
            Toggle("Linksgewinde", isOn: binding(\.leftHanded))
                .fixedSize()
            if let target = parts.thread.target, workspace.model.threadHasBlindEnd(parts.thread, target: target) {
                Toggle("Auslauf DIN 76", isOn: binding(\.runoutDIN76))
                    .fixedSize()
                    .hoverTip("Gewindeauslauf DIN 76", "Sackloch: das Gewinde endet um den Auslauf e1 vor dem Grund, wie beim Gewindebohren (z. B. M6: 5,1 mm, M8: 6,2 mm). Aus = Gewinde bis zum Grund (gut für den 3D-Druck).")
            }
        }
    }

    private var pitchControl: some View {
        HStack(spacing: 6) {
            NumberField(title: "Steigung", value: parts.thread.pitch, width: 52) { value in
                guard value >= 0.1, value <= 50 else { return }
                parts.thread.pitch = value
                workspace.updatePartPreview()
            }
            Menu {
                ForEach(parts.thread.pitchChoices.indices, id: \.self) { index in
                    let value = parts.thread.pitchChoices[index]
                    let kind = index == 0 ? "Norm" : "fein/alternativ"
                    Button("\(pitchText(value, family: parts.thread.family)) – \(kind)") {
                        parts.thread.pitch = value
                        workspace.updatePartPreview()
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .fixedSize()
            .hoverTip("Steigungen", "Normsteigung und gängige Feingewinde bzw. Alternativen dieser Größe; im Feld ist jede Steigung möglich.")
        }
    }
}

// MARK: - Gewindebohrung

/// Zeile „Gewinde“ in der Karte des Bohrungswerkzeugs.
struct HoleThreadRow: View {
    @ObservedObject var workspace: Workspace

    private func update(_ change: (inout HoleThread) -> Void) {
        guard var thread = workspace.holeSpec.thread else { return }
        change(&thread)
        workspace.setHoleThread(thread)
    }

    /// Sackloch: wo das Gewinde endet (bis Grund, Auslauf nach DIN 76, eigenes Maß) und die sich ergebende Länge.
    private func runoutControls(_ thread: HoleThread) -> some View {
        let usable: Double = thread.threadLength(depth: workspace.holeSpec.depth, through: false)
        let e1: Double = ThreadRunout.din76Length(pitch: thread.pitch)
        return HStack(spacing: 8) {
            Text("Ende")
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("Gewindeende", selection: Binding(get: { thread.runout }, set: { value in
                update { $0.runout = value }
            })) {
                ForEach(ThreadRunout.allCases) { runout in
                    Text(runout.rawValue).tag(runout)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .hoverTip("Gewindeende im Sackloch", "Bis Grund: Gewinde über die ganze Bohrtiefe (gut für den 3D-Druck). DIN 76: das Gewinde endet um den Auslauf e1 vor dem Grund, wie beim Gewindebohren (z. B. M6: 5,1 mm, M8: 6,2 mm). Maß: eigene Gewindelänge ab der Fläche. Das Kernloch geht immer bis zur vollen Tiefe.")
            if thread.runout == .custom {
                NumberField(title: "Länge", value: thread.runoutLength, width: 52) { length in
                    guard length >= 0.5 else { return }
                    update { $0.runoutLength = length }
                }
            }
            if thread.runout == .din76 {
                Text("e1 \(LengthUnit.current.format(e1))")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text("Gewinde \(LengthUnit.current.format(usable))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Gewinde", isOn: Binding(get: { workspace.holeSpec.thread != nil }, set: { on in
                workspace.setHoleThread(on ? (workspace.holeSpec.thread ?? HoleThread()) : nil)
            }))
            .fixedSize()
            .hoverTip("Gewindebohrung", "Bohrt das Kernloch nach Bohrertabelle (ISO 2306) und modelliert das Innengewinde (druckbar) – oder nur kosmetisch. Die Zugabe gilt als Druckspiel.")
            if let thread = workspace.holeSpec.thread {
                ThreadModePicker(cosmetic: thread.cosmetic) { value in
                    update { $0.cosmetic = value }
                }
                Picker("Art", selection: Binding(get: { thread.family }, set: { family in
                    update { value in
                        value.family = family
                        value.sizeIndex = family.defaultSizeIndex
                        value.pitch = value.size.pitch
                    }
                })) {
                    ForEach(ThreadFamily.allCases) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Größe", selection: Binding(get: { thread.sizeIndex }, set: { index in
                    update { value in
                        value.sizeIndex = index
                        value.pitch = value.size.pitch
                    }
                })) {
                    ForEach(thread.family.sizes.indices, id: \.self) { index in
                        Text(thread.family.sizes[index].name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                NumberField(title: "Steigung", value: thread.pitch, width: 52) { pitch in
                    guard pitch >= 0.1, pitch <= 50 else { return }
                    update { $0.pitch = pitch }
                }
                if thread.pitchChoices.count > 1 {
                    Menu {
                        ForEach(thread.pitchChoices.indices, id: \.self) { index in
                            let pitch = thread.pitchChoices[index]
                            Button(pitchText(pitch, family: thread.family)) {
                                update { $0.pitch = pitch }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .fixedSize()
                }
                Toggle("Links", isOn: Binding(get: { thread.leftHanded }, set: { left in
                    update { $0.leftHanded = left }
                }))
                .fixedSize()
                ThreadTolerancePresetMenu(value: workspace.holeSpec.clearance) { value in
                    var spec = workspace.holeSpec
                    spec.clearance = value
                    workspace.holeSpec = spec
                    workspace.updateHolePreview()
                }
                if !workspace.holeSpec.through {
                    runoutControls(thread)
                }
                Text(thread.tapDrillText(clearance: workspace.holeSpec.clearance))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Gewindebohrung am Tippunkt (Gewinde-Werkzeug)

/// Zeile der Gewinde-Karte, wenn keine Zylinderfläche gewählt ist: Gewindebohrungen an den angetippten Stellen
/// (eben oder gewölbt) mit Tiefe bzw. durchgehend und Gewindeende im Sackloch.
struct ThreadHoleControls: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var parts: PartSettings

    private func update(_ change: (inout ThreadHoleSettings) -> Void) {
        var settings = parts.threadHole
        change(&settings)
        parts.threadHole = settings
        workspace.updatePartPreview()
    }

    private var countText: String {
        let count = parts.threadHole.points.count
        return count == 1 ? "1 Bohrung" : "\(count) Bohrungen"
    }

    var body: some View {
        HStack(spacing: 12) {
            ThreadModePicker(cosmetic: parts.thread.cosmetic) { value in
                parts.thread.cosmetic = value
                workspace.updatePartPreview()
            }
            Toggle("Durchgehend", isOn: Binding(get: { parts.threadHole.through }, set: { value in
                update { $0.through = value }
            }))
            .fixedSize()
            if !parts.threadHole.through {
                NumberField(title: "Tiefe", value: parts.threadHole.depth, width: 56) { value in
                    guard value >= 0.5, value <= 10_000 else { return }
                    update { $0.depth = value }
                }
                blindControls
            }
            Toggle("Linksgewinde", isOn: Binding(get: { parts.thread.leftHanded }, set: { value in
                parts.thread.leftHanded = value
                workspace.updatePartPreview()
            }))
            .fixedSize()
            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Button("Letzte entfernen", systemImage: "arrow.uturn.backward", action: workspace.removeLastThreadHole)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(parts.threadHole.points.isEmpty)
        }
    }

    /// Sackloch: Gewindeende (bis Grund, DIN 76, Maß) und Bohrspitze.
    private var blindControls: some View {
        HStack(spacing: 8) {
            Picker("Gewindeende", selection: Binding(get: { parts.threadHole.runout }, set: { value in
                update { $0.runout = value }
            })) {
                ForEach(ThreadRunout.allCases) { runout in
                    Text(runout.rawValue).tag(runout)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .hoverTip("Gewindeende im Sackloch", "Bis Grund: Gewinde über die ganze Bohrtiefe (gut für den 3D-Druck). DIN 76: das Gewinde endet um den Auslauf e1 vor dem Grund, wie beim Gewindebohren. Maß: eigene Gewindelänge ab der Fläche. Das Kernloch geht immer bis zur vollen Tiefe.")
            if parts.threadHole.runout == .custom {
                NumberField(title: "Länge", value: parts.threadHole.runoutLength, width: 52) { value in
                    guard value >= 0.5 else { return }
                    update { $0.runoutLength = value }
                }
            }
            Toggle("Bohrspitze", isOn: Binding(get: { parts.threadHole.drillPoint }, set: { value in
                update { $0.drillPoint = value }
            }))
            .fixedSize()
            .hoverTip("Bohrspitze", "Kegel mit 118° am Grund der Sackbohrung wie bei einem echten Bohrer.")
        }
    }
}
