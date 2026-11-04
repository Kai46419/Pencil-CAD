import SwiftUI

// Build 42: Rundungsoptionen nach der öffentlichen Shapr3D-Hilfe „Chamfer/Fillet“ (Settings badge → Corners,
// Continuity, Profile, Overflow; kein Reverse Engineering). Jede Wahl ist nur frei, wenn der Kernel sie kann
// (`PCKShape.supports(blendOptions:)`); sonst grau. Nicht-Standard gibt es nur bei konstanter Rundung.
//
// Zustand im offenen Befehl (ModelCommand): choices „corner“/„continuity“/„profile“/„overflow“ (Rohwerte von
// BlendOptions), values „setback“ (mm) und „rho“ (0,1 … 0,9), flags „setbackManual“ (Setback von Hand eingegeben –
// bis dahin folgt er 1,5 × Radius). Beim Bearbeiten aus dem Verlauf (FeatureEdit) stehen Setback und Rho als
// Formeltexte unter „setback“ bzw. „rhoPercent“ (Parameter des Features, Vertrag 1d).

/// Schlüssel und Grenzen der Rundungsoptionen im Befehl.
enum BlendOptionKeys {
    static let corner = "corner"
    static let continuity = "continuity"
    static let profile = "profile"
    static let overflow = "overflow"
    static let setback = "setback"
    static let rho = "rho"
    /// Parameter-Schlüssel des Features (Vertrag 1d) für Rho in Prozent
    static let rhoPercent = "rhoPercent"
    static let setbackManual = "setbackManual"
    static let defaultRho = 0.5
    static let rhoRange: ClosedRange<Double> = 0.1...0.9
    static let rhoStep = 0.05
}

/// Abbildung Befehl ↔ BlendOptions, Freigabe über den Kernel, Zusammenfassung (ohne Workspace, testbar).
enum BlendOptionsForm {
    // MARK: Lesen

    static func corner(_ cmd: ModelCommand) -> BlendOptions.Corner {
        BlendOptions.Corner(rawValue: cmd.choice(BlendOptionKeys.corner, default: BlendOptions.Corner.rollingBall.rawValue))
            ?? .rollingBall
    }

    static func continuity(_ cmd: ModelCommand) -> BlendOptions.Continuity {
        BlendOptions.Continuity(rawValue: cmd.choice(BlendOptionKeys.continuity,
                                                     default: BlendOptions.Continuity.g1.rawValue)) ?? .g1
    }

    static func profile(_ cmd: ModelCommand) -> BlendOptions.Profile {
        BlendOptions.Profile(rawValue: cmd.choice(BlendOptionKeys.profile, default: BlendOptions.Profile.circle.rawValue))
            ?? .circle
    }

    static func overflow(_ cmd: ModelCommand) -> BlendOptions.Overflow {
        BlendOptions.Overflow(rawValue: cmd.choice(BlendOptionKeys.overflow,
                                                   default: BlendOptions.Overflow.automatic.rawValue)) ?? .automatic
    }

    /// Radius, dem der Setback folgt (Rundung: „radius“; im Sehnenmodus rechnet refresh den Radius dorthin)
    static func radius(_ cmd: ModelCommand) -> Double {
        let value = cmd.number("radius", default: 2)
        return value.isFinite && value > 0 ? value : 2
    }

    static func isSetbackManual(_ cmd: ModelCommand) -> Bool {
        cmd.isOn(BlendOptionKeys.setbackManual, default: false)
    }

    /// Setback-Abstand: Vorgabe 1,5 × Radius, bis er von Hand eingegeben wurde
    static func setbackValue(_ cmd: ModelCommand) -> Double {
        let preset = BlendOptions.defaultSetback(radius: radius(cmd))
        guard isSetbackManual(cmd) else { return preset }
        let value = cmd.number(BlendOptionKeys.setback, default: preset)
        return value.isFinite ? value : preset
    }

    static func rhoValue(_ cmd: ModelCommand) -> Double {
        let value = cmd.number(BlendOptionKeys.rho, default: BlendOptionKeys.defaultRho)
        guard value.isFinite else { return BlendOptionKeys.defaultRho }
        return min(max(value, BlendOptionKeys.rhoRange.lowerBound), BlendOptionKeys.rhoRange.upperBound)
    }

    /// Optionen nur bei konstanter Rundung (nicht Variabel/Teilweise, Vertrag 1a Regel 7)
    static func allowsOptions(_ cmd: ModelCommand) -> Bool {
        !cmd.isOn("variable", default: false) && !cmd.isOn("partial", default: false)
    }

    /// Gewählte Optionen, wie sie im Befehl stehen (bereinigt)
    static func options(_ cmd: ModelCommand) -> BlendOptions {
        var options = BlendOptions.standard
        options.corner = corner(cmd)
        options.setback = setbackValue(cmd)
        options.continuity = continuity(cmd)
        options.profile = profile(cmd)
        options.rho = rhoValue(cmd)
        options.overflow = overflow(cmd)
        return cleaned(options)
    }

    /// Optionen, mit denen gerechnet wird: Variabel/Teilweise erzwingen Standard
    static func effectiveOptions(_ cmd: ModelCommand) -> BlendOptions {
        allowsOptions(cmd) ? options(cmd) : .standard
    }

    /// Nicht zutreffende Werte leeren: Setback nur bei Ecke „Setback“, Kegelschnitt nur bei G2, Rho nur bei Kegelschnitt
    static func cleaned(_ input: BlendOptions) -> BlendOptions {
        var options = input
        if options.corner != .setback { options.setback = nil }
        if options.continuity != .g2 { options.profile = .circle }
        if options.profile != .conic { options.rho = nil }
        return options
    }

    // MARK: Schreiben

    /// Startwerte (build): Standard, Setback 1,5 × Radius, Rho 0,5, Setback folgt dem Radius
    static func setDefaults(_ cmd: ModelCommand, radius: Double) {
        store(.standard, in: cmd)
        cmd.putNumber(BlendOptionKeys.setback, BlendOptions.defaultSetback(radius: radius))
        cmd.putNumber(BlendOptionKeys.rho, BlendOptionKeys.defaultRho)
        cmd.flags[BlendOptionKeys.setbackManual] = false
    }

    /// Nur die Wahlen (Ecken, Stetigkeit, Profil, Überlauf) – beim Bearbeiten aus dem Verlauf stehen Setback und Rho
    /// als Formeltexte im Befehl und dürfen nicht durch mm-Zahlen ersetzt werden
    static func storeChoices(_ options: BlendOptions, in cmd: ModelCommand) {
        cmd.choices[BlendOptionKeys.corner] = options.corner.rawValue
        cmd.choices[BlendOptionKeys.continuity] = options.continuity.rawValue
        cmd.choices[BlendOptionKeys.profile] = options.profile.rawValue
        cmd.choices[BlendOptionKeys.overflow] = options.overflow.rawValue
    }

    /// Nur die Wahlen aus dem Befehl (ohne Setback/Rho-Werte)
    static func chosen(_ cmd: ModelCommand) -> BlendOptions {
        var options = BlendOptions.standard
        options.corner = corner(cmd)
        options.continuity = continuity(cmd)
        options.profile = profile(cmd)
        options.overflow = overflow(cmd)
        return cleaned(options)
    }

    /// Optionen in den Befehl schreiben (Werte für Setback/Rho bleiben stehen, wenn die Option aus ist)
    static func store(_ options: BlendOptions, in cmd: ModelCommand) {
        storeChoices(options, in: cmd)
        if let setback = options.setback { cmd.putNumber(BlendOptionKeys.setback, setback) }
        if let rho = options.rho { cmd.putNumber(BlendOptionKeys.rho, rho) }
    }

    /// Vorhandene Optionen übernehmen (z. B. die zuletzt im Modell verwendeten). Setback gilt als „von Hand“,
    /// wenn er nicht der Vorgabe zum Radius entspricht.
    static func adopt(_ options: BlendOptions, into cmd: ModelCommand, radius: Double) {
        store(options, in: cmd)
        if let setback = options.setback {
            cmd.flags[BlendOptionKeys.setbackManual] = abs(setback - BlendOptions.defaultSetback(radius: radius)) > 1e-6
        }
    }

    /// Setback von Hand: folgt dem Radius nicht mehr
    static func setManualSetback(_ value: Double, in cmd: ModelCommand) {
        cmd.flags[BlendOptionKeys.setbackManual] = true
        cmd.putNumber(BlendOptionKeys.setback, value)
    }

    /// Setback wieder an den Radius koppeln (Vorgabe 1,5 × Radius)
    static func resetSetback(in cmd: ModelCommand) {
        cmd.flags[BlendOptionKeys.setbackManual] = false
        followRadius(cmd, radius: radius(cmd))
    }

    /// Setback folgt dem Radius, solange er nicht von Hand eingegeben wurde
    static func followRadius(_ cmd: ModelCommand, radius: Double) {
        guard !isSetbackManual(cmd), radius.isFinite, radius > 0 else { return }
        let text = CommandFormat.plain(BlendOptions.defaultSetback(radius: radius))
        if cmd.values[BlendOptionKeys.setback] != text { cmd.values[BlendOptionKeys.setback] = text }
    }

    /// Bewegliche Teile des Befehls, die beim Wechsel Rundung ↔ Fase (Pfeil nach innen) mitgehen
    static func carry(from source: ModelCommand, to target: ModelCommand) {
        for key in [BlendOptionKeys.corner, BlendOptionKeys.continuity, BlendOptionKeys.profile, BlendOptionKeys.overflow] {
            if let value = source.choices[key] { target.choices[key] = value }
        }
        for key in [BlendOptionKeys.setback, BlendOptionKeys.rho] {
            if let value = source.values[key] { target.values[key] = value }
        }
        if let manual = source.flags[BlendOptionKeys.setbackManual] { target.flags[BlendOptionKeys.setbackManual] = manual }
    }

    // MARK: Freigabe über den Kernel

    /// Standard geht immer; sonst nur gültige Werte, die der Kernel kann
    static func isSupported(_ options: BlendOptions) -> Bool {
        if options.isStandard { return true }
        return options.isValid && PCKShape.supports(blendOptions: options.kernel)
    }

    /// Kann der Kernel überhaupt eine Nicht-Standard-Option? (sonst Hinweis statt grauer Knöpfe ohne Erklärung)
    static var kernelHasOptions: Bool {
        var setback = BlendOptions.standard
        setback.corner = .setback
        setback.setback = 3
        var g2 = BlendOptions.standard
        g2.continuity = .g2
        var keep = BlendOptions.standard
        keep.overflow = .keepEdge
        return [setback, g2, keep].contains { isSupported($0) }
    }

    /// Optionen nach einer Wahl: zuerst zusammen mit den übrigen Optionen, sonst die Wahl allein (die übrigen
    /// auf Standard). nil = der Kernel kann die Wahl nicht (Knopf grau).
    static func variant(of current: BlendOptions, _ change: (inout BlendOptions) -> Void) -> BlendOptions? {
        var combined = current
        change(&combined)
        combined = cleaned(combined)
        if isSupported(combined) { return combined }
        var single = BlendOptions.standard
        change(&single)
        single = cleaned(single)
        return isSupported(single) ? single : nil
    }

    // MARK: Anzeige

    static func cornerTitle(_ corner: BlendOptions.Corner) -> String {
        corner == .setback ? "Setback" : "Rolling Ball"
    }

    /// Zahl mit Komma (Rho 0,5)
    static func decimal(_ value: Double) -> String {
        CommandFormat.plain(value).replacingOccurrences(of: ".", with: ",")
    }

    /// Zusammenfassungszeile, z. B. „Ecken: Setback 3 mm · G2 · Rho 0,5“
    static func summary(_ options: BlendOptions) -> String {
        var parts: [String] = []
        if options.corner == .setback, let setback = options.setback {
            parts.append("Ecken: Setback \(LengthUnit.current.format(setback))")
        } else {
            parts.append("Ecken: Rolling Ball")
        }
        parts.append(options.continuity == .g2 ? "G2" : "G1")
        if options.continuity == .g2 {
            if options.profile == .conic, let rho = options.rho {
                parts.append("Rho \(decimal(rho))")
            } else {
                parts.append("Kreis")
            }
        }
        if options.overflow == .keepEdge { parts.append("Kante halten") }
        return parts.joined(separator: " · ")
    }

    /// Kurzes Abzeichen im Verlauf („SB“, „G2“, „SB·G2“); nil bei Standard
    static func badge(_ options: BlendOptions) -> String? {
        var parts: [String] = []
        if options.corner == .setback { parts.append("SB") }
        if options.continuity == .g2 { parts.append(options.profile == .conic ? "G2ρ" : "G2") }
        if options.overflow == .keepEdge { parts.append("KH") }
        return parts.isEmpty ? nil : parts.joined(separator: "·")
    }

    // MARK: Fehlschlag (C4)

    enum Fix: Equatable {
        /// „Rolling Ball verwenden“
        case rollingBall
        /// „G1 verwenden“
        case g1
        /// „Standard verwenden“ (Kernel kann die Option nicht)
        case standard
    }

    /// Welche Abhilfe zu einem Fehlertext passt (Meldungstexte aus ModelStore, H-B2)
    @MainActor static func fixes(for error: String?, options: BlendOptions) -> [Fix] {
        guard let error, !options.isStandard else { return [] }
        var result: [Fix] = []
        if options.corner == .setback, error.contains(ModelStore.blendSetbackFailedMessage) { result.append(.rollingBall) }
        if options.continuity == .g2, error.contains(ModelStore.blendG2FailedMessage) { result.append(.g1) }
        if result.isEmpty, error.contains(ModelStore.blendOptionsUnsupportedMessage) { result.append(.standard) }
        return result
    }

    static func apply(_ fix: Fix, to cmd: ModelCommand) {
        switch fix {
        case .rollingBall:
            cmd.choices[BlendOptionKeys.corner] = BlendOptions.Corner.rollingBall.rawValue
        case .g1:
            cmd.choices[BlendOptionKeys.continuity] = BlendOptions.Continuity.g1.rawValue
            cmd.choices[BlendOptionKeys.profile] = BlendOptions.Profile.circle.rawValue
        case .standard:
            store(.standard, in: cmd)
        }
    }

    static func title(_ fix: Fix) -> String {
        switch fix {
        case .rollingBall: "Rolling Ball verwenden"
        case .g1: "G1 verwenden"
        case .standard: "Standardoptionen verwenden"
        }
    }
}

// MARK: - Blatt (Popover am Zahnrad bzw. an der Zusammenfassungszeile)

/// Rundungsoptionen wie die Shapr3D-Einstellungen: Ecken, Stetigkeit, Profil (nur G2), Überlauf (nur wenn der Kernel
/// es kann). Jede Änderung rechnet die Vorschau neu.
struct BlendSettingsSheet: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        let current = BlendOptionsForm.options(cmd)
        let allowed = BlendOptionsForm.allowsOptions(cmd)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Rundungsoptionen")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Button("Standard") {
                        BlendOptionsForm.store(.standard, in: cmd)
                        BlendOptionsForm.resetSetback(in: cmd)
                        refresh()
                    }
                    .font(.callout)
                    .disabled(current.isStandard && !BlendOptionsForm.isSetbackManual(cmd))
                }
                if !allowed {
                    PaletteHint(text: ModelStore.blendOptionsConstantOnlyMessage)
                } else if !BlendOptionsForm.kernelHasOptions {
                    PaletteHint(text: ModelStore.blendOptionsUnsupportedMessage)
                }
                cornerRows(current, allowed: allowed)
                continuityRows(current, allowed: allowed)
                overflowRows(current, allowed: allowed)
            }
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 520)
    }

    private func refresh() {
        CommandCache.refreshNow(cmd, workspace)
    }

    /// Wahl übernehmen, wenn der Kernel sie kann (variant prüft das)
    private func choose(_ current: BlendOptions, _ change: (inout BlendOptions) -> Void) {
        guard let next = BlendOptionsForm.variant(of: current, change) else { return }
        BlendOptionsForm.store(next, in: cmd)
        refresh()
    }

    private func enabled(_ current: BlendOptions, allowed: Bool, _ change: (inout BlendOptions) -> Void) -> Bool {
        allowed && BlendOptionsForm.variant(of: current, change) != nil
    }

    @ViewBuilder private func cornerRows(_ current: BlendOptions, allowed: Bool) -> some View {
        let setback = BlendOptionsForm.setbackValue(cmd)
        let setSetback: (inout BlendOptions) -> Void = { $0.corner = .setback; $0.setback = setback }
        CommandSegmentRow(title: "Ecken", options: [
            CommandChoice(id: BlendOptions.Corner.rollingBall.rawValue, title: "Rolling Ball", isEnabled: allowed),
            CommandChoice(id: BlendOptions.Corner.setback.rawValue, title: "Setback",
                          isEnabled: enabled(current, allowed: allowed, setSetback)),
        ], selected: current.corner.rawValue) { id in
            if id == BlendOptions.Corner.setback.rawValue {
                choose(current, setSetback)
            } else {
                choose(current) { $0.corner = .rollingBall }
            }
        }
        Text(current.corner == .setback
             ? "Die Ecke wird weich verblendet; die Rundungen enden im Setback-Abstand vor der Ecke."
             : "Eine Kugel rollt über alle Kanten (Standard).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if current.corner == .setback {
            PaletteNumberRow(title: "Setback-Abstand", value: setback, unit: "mm") { value in
                guard value.isFinite, value > 0 else { return }
                BlendOptionsForm.setManualSetback(value, in: cmd)
                refresh()
            }
            HStack(alignment: .top, spacing: 6) {
                Text(BlendOptionsForm.isSetbackManual(cmd)
                     ? "Muss größer als der Radius sein (\(LengthUnit.current.format(BlendOptionsForm.radius(cmd))))."
                     : "Muss größer als der Radius sein · folgt 1,5 × Radius, bis du einen Wert eingibst.")
                    .font(.caption)
                    .foregroundStyle(setback < BlendOptionsForm.radius(cmd) ? SketchTheme.error : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if BlendOptionsForm.isSetbackManual(cmd) {
                    Button("1,5 × Radius") {
                        BlendOptionsForm.resetSetback(in: cmd)
                        refresh()
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private func continuityRows(_ current: BlendOptions, allowed: Bool) -> some View {
        CommandSegmentRow(title: "Stetigkeit", options: [
            CommandChoice(id: BlendOptions.Continuity.g1.rawValue, title: "G1", isEnabled: allowed),
            CommandChoice(id: BlendOptions.Continuity.g2.rawValue, title: "G2",
                          isEnabled: enabled(current, allowed: allowed) { $0.continuity = .g2 }),
        ], selected: current.continuity.rawValue) { id in
            if id == BlendOptions.Continuity.g2.rawValue {
                choose(current) { $0.continuity = .g2 }
            } else {
                choose(current) { $0.continuity = .g1 }
            }
        }
        Text(current.continuity == .g2 ? "G2 krümmungsstetig – weicher Lichtverlauf." : "G1 tangential (Standard).")
            .font(.caption)
            .foregroundStyle(.secondary)
        if current.continuity == .g2 {
            let rho = BlendOptionsForm.rhoValue(cmd)
            let setConic: (inout BlendOptions) -> Void = { $0.continuity = .g2; $0.profile = .conic; $0.rho = rho }
            CommandSegmentRow(title: "Profil", options: [
                CommandChoice(id: BlendOptions.Profile.circle.rawValue, title: "Kreis", isEnabled: allowed),
                CommandChoice(id: BlendOptions.Profile.conic.rawValue, title: "Kegelschnitt",
                              isEnabled: enabled(current, allowed: allowed, setConic)),
            ], selected: current.profile.rawValue) { id in
                if id == BlendOptions.Profile.conic.rawValue {
                    choose(current, setConic)
                } else {
                    choose(current) { $0.profile = .circle }
                }
            }
            if current.profile == .conic {
                RhoSlider(cmd: cmd, workspace: workspace)
            }
        }
    }

    @ViewBuilder private func overflowRows(_ current: BlendOptions, allowed: Bool) -> some View {
        let keepEdge: (inout BlendOptions) -> Void = { $0.overflow = .keepEdge }
        // Überlauf nur zeigen, wenn der Kernel „Kante halten“ kann (Shapr3D „Overflow“)
        if current.overflow == .keepEdge || BlendOptionsForm.variant(of: .standard, keepEdge) != nil {
            CommandSegmentRow(title: "Überlauf", options: [
                CommandChoice(id: BlendOptions.Overflow.automatic.rawValue, title: "Automatisch", isEnabled: allowed),
                CommandChoice(id: BlendOptions.Overflow.keepEdge.rawValue, title: "Kante halten",
                              isEnabled: enabled(current, allowed: allowed, keepEdge)),
            ], selected: current.overflow.rawValue) { id in
                if id == BlendOptions.Overflow.keepEdge.rawValue {
                    choose(current, keepEdge)
                } else {
                    choose(current) { $0.overflow = .automatic }
                }
            }
        }
    }
}

/// Rho-Schieber 0,1 … 0,9 in Stufen von 0,05: klein = flacher, groß = voller.
private struct RhoSlider: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        let rho = BlendOptionsForm.rhoValue(cmd)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Rho")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(BlendOptionsForm.decimal(rho))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: Binding(get: { rho }, set: { value in
                let stepped = (value / BlendOptionKeys.rhoStep).rounded() * BlendOptionKeys.rhoStep
                let clamped = min(max(stepped, BlendOptionKeys.rhoRange.lowerBound), BlendOptionKeys.rhoRange.upperBound)
                guard abs(clamped - BlendOptionsForm.rhoValue(cmd)) > 1e-9 else { return }
                cmd.putNumber(BlendOptionKeys.rho, clamped)
                CommandCache.refreshNow(cmd, workspace)
            }), in: BlendOptionKeys.rhoRange, step: BlendOptionKeys.rhoStep)
            .accessibilityLabel("Profil Rho")
            .accessibilityValue(BlendOptionsForm.decimal(rho))
            HStack {
                Text("flacher").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("voller").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Zusammenfassungszeile im Abrunden-Panel; Antippen öffnet dasselbe Blatt wie das Zahnrad.
struct BlendOptionsSummaryRow: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    @State private var showsSettings = false

    var body: some View {
        let allowed = BlendOptionsForm.allowsOptions(cmd)
        let options = BlendOptionsForm.effectiveOptions(cmd)
        PaletteLabeled(title: "Optionen") {
            Button {
                showsSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(options.isStandard ? Color.secondary : Color.accentColor)
                    Text(allowed ? BlendOptionsForm.summary(options) : "Standard (nur bei konstanter Rundung änderbar)")
                        .font(.footnote)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton)
                .background(PaletteStyle.field,
                            in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                        .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rundungsoptionen")
            .accessibilityValue(BlendOptionsForm.summary(options))
            .popover(isPresented: $showsSettings) {
                BlendSettingsSheet(cmd: cmd, workspace: workspace, model: model)
            }
        }
    }
}

/// Abhilfe-Knöpfe nach einem Fehlschlag mit Optionen (kein stiller Rückfall: der Nutzer entscheidet).
struct BlendOptionsFixRow: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        let fixes = BlendOptionsForm.fixes(for: cmd.error, options: BlendOptionsForm.effectiveOptions(cmd))
        if !fixes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fixes.indices, id: \.self) { index in
                    let fix = fixes[index]
                    PrimaryWideButton(title: BlendOptionsForm.title(fix),
                                      systemImage: fix == .g1 ? "circle.dashed" : "circle.grid.cross",
                                      isPrimary: false) {
                        BlendOptionsForm.apply(fix, to: cmd)
                        cmd.error = nil
                        CommandCache.refreshNow(cmd, workspace)
                    }
                }
            }
        }
    }
}
