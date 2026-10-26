import SwiftUI
import simd

// MARK: - Werkzeug „Gewinde“ (Erstellen › Gewinde) und Option „Gewinde“ im Bohrungswerkzeug

extension Workspace {
    /// Zylinderfläche angetippt: Bolzen → Außengewinde, Bohrung → Innengewinde; passende Normgröße vorschlagen.
    func threadTapped(_ face: FaceRef) {
        model.cancelPreview()
        guard let target = model.threadTarget(for: face) else {
            model.message = "Für ein Gewinde eine Zylinderfläche antippen: Bolzen (Außengewinde) oder Bohrung (Innengewinde)."
            parts.thread.target = nil
            return
        }
        var spec = parts.thread
        spec.target = target
        spec.offset = 0
        spec.fullLength = true
        spec.length = target.length
        spec.fromOtherEnd = false
        spec.sizeIndex = spec.family.suggestedSize(forDiameter: 2 * target.radius, external: target.external)
        spec.pitch = spec.size.pitch
        parts.thread = spec
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

    /// Gewindebohrung ein/aus bzw. geändert: Kernloch-Ø übernehmen, Vorschau neu.
    func setHoleThread(_ thread: HoleThread?) {
        var spec = holeSpec
        spec.thread = thread
        if let thread {
            spec.kind = .simple
            spec.diameter = (thread.coreDiameter * 100).rounded() / 100
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
        guard let target = parts.thread.target else { return "Zylinderfläche antippen" }
        let diameter = LengthUnit.current.format(2 * target.radius)
        return target.external ? "Außengewinde · Bolzen Ø \(diameter)" : "Innengewinde · Bohrung Ø \(diameter)"
    }

    private var infoText: String {
        let spec = parts.thread
        let form = spec.family.form
        var text = "\(spec.designation) · \(form.angleText) · \(spec.family.standard)"
        if spec.starts > 1 {
            let lead = spec.lead.formatted(.number.precision(.fractionLength(0...3)))
            text += " · \(lead) mm je Umdrehung"
        }
        if spec.family.isTapered { text += " · Kegel 1:16, Spitzen zylindrisch" }
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
            HStack(spacing: 12) {
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
            HStack(spacing: 12) {
                field("Druckspiel", \.clearance, width: 48, minimum: 0, maximum: 0.6)
                    .hoverTip("Druckspiel", "Für den 3D-Druck: Außengewinde werden radial um die Hälfte kleiner, Innengewinde um die Hälfte größer. 0,2 mm ist ein guter Anfang, 0 für exakte Normmaße.")
                Toggle("Anschnitt", isOn: binding(\.chamfer))
                    .fixedSize()
                    .hoverTip("Anschnitt", "Fase am freien Ende des Bolzens bzw. Senkung am Eingang der Bohrung, damit Schraube und Mutter gut ansetzen.")
                if parts.thread.target != nil {
                    Button("Anderes Ende", systemImage: "arrow.up.arrow.down") {
                        parts.thread.fromOtherEnd.toggle()
                        workspace.updatePartPreview()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverTip("Anderes Ende", "Gewindeanfang (Versatz, Anschnitt) am anderen Ende der Fläche.")
                }
                Text(infoText)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .fixedSize()
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
            .hoverTip("Gewindebohrung", "Bohrt das Kernloch nach Norm und modelliert das Innengewinde (druckbar). Die Zugabe gilt als Druckspiel.")
            if let thread = workspace.holeSpec.thread {
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
                if !workspace.holeSpec.through {
                    runoutControls(thread)
                }
                Text("Kernloch Ø \(LengthUnit.current.format(thread.coreDiameter + workspace.holeSpec.clearance))")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}
