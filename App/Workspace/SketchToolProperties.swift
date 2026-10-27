import SwiftUI

// Abschnitt „Werkzeug“ der Skizzenpalette (SolidCraft „Feature Options“ und Befehlsfenster, zusammengelegt):
// Varianten als Bildknöpfe, darunter die Werte des Werkzeugs senkrecht untereinander, zuletzt der Hinweis.
// Übernimmt die bisherigen Inhalte von ParameterCard.toolOptions (Panels.swift).

/// Eigenschaften des aktiven Skizzenwerkzeugs bzw. der wartenden Bedingung.
struct SketchToolSection: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        if let pending = sketch.pendingAction {
            PaletteSection("Bedingung", detail: pending.title, collapsible: false) {
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    PaletteHint(text: sketch.paletteHint)
                    PrimaryWideButton(title: "Beenden", systemImage: "xmark", isPrimary: false, action: sketch.cancelPending)
                }
            }
        } else {
            PaletteSection("Werkzeug", detail: sketch.tool.rawValue) {
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    SketchToolVariants(sketch: sketch, options: options)
                    SketchToolFields(sketch: sketch, options: options)
                    PaletteHint(text: sketch.paletteHint)
                }
            }
        }
    }
}

// MARK: Varianten

/// Varianten der Werkzeugfamilie als Bildknöpfe; Antippen wechselt die Variante, das Werkzeug bleibt aktiv.
private struct SketchToolVariants: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    private struct Family {
        let choices: [IconChoice]
        let selected: String
        let pick: (String) -> Void
    }

    var body: some View {
        if let family {
            VStack(alignment: .leading, spacing: 4) {
                IconSegment(choices: family.choices, selected: [family.selected], pick: family.pick)
                if let title = family.choices.first(where: { $0.id == family.selected })?.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var family: Family? {
        switch sketch.tool {
        case .polyline: return lineFamily
        case .rectangle: return rectangleFamily
        case .circle: return circleFamily
        case .arc: return arcFamily
        case .polygon: return polygonFamily
        case .slot: return slotFamily
        case .spline: return splineFamily
        case .chamfer: return chamferFamily
        case .offset: return offsetFamily
        case .trim, .extend, .breakCurve, .splitAtPoint: return cutFamily
        default: return nil
        }
    }

    /// Linie und tangentialer Bogen am Linienende (PC: „Bogen“-Knopf, nächster Strich wird Bogen)
    private var lineFamily: Family {
        let choices = [
            IconChoice(id: "line", title: "Linie", icon: "sc.line"),
            IconChoice(id: "arc", title: "Tangentialbogen (nächster Strich)", icon: "sc.arc3"),
        ]
        return Family(choices: choices, selected: sketch.arcNext ? "arc" : "line") { id in
            sketch.arcNext = id == "arc"
        }
    }

    private var rectangleFamily: Family {
        let choices = RectangleMode.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) }
        return Family(choices: choices, selected: sketch.rectangleMode.rawValue) { id in
            if let mode = RectangleMode(rawValue: id) { sketch.rectangleMode = mode }
        }
    }

    private var circleFamily: Family {
        let choices = CircleMode.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) }
        return Family(choices: choices, selected: sketch.circleMode.rawValue) { id in
            if let mode = CircleMode(rawValue: id) { sketch.circleMode = mode }
        }
    }

    private var arcFamily: Family {
        let choices = ArcMode.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) }
        return Family(choices: choices, selected: sketch.arcMode.rawValue) { id in
            if let mode = ArcMode(rawValue: id) { sketch.arcMode = mode }
        }
    }

    private var polygonFamily: Family {
        let choices = PolygonMode.allCases.map { mode in
            IconChoice(id: mode.rawValue, title: mode == .inscribed ? "Innen (Radius bis Ecke)" : "Außen (Radius bis Kante)",
                       icon: mode == .inscribed ? "sc.polygon" : "hexagon")
        }
        return Family(choices: choices, selected: sketch.polygonMode.rawValue) { id in
            if let mode = PolygonMode(rawValue: id) { sketch.polygonMode = mode }
        }
    }

    private var slotFamily: Family {
        let choices = SlotMode.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) }
        return Family(choices: choices, selected: sketch.slotMode.rawValue) { id in
            if let mode = SlotMode(rawValue: id) { sketch.slotMode = mode }
        }
    }

    /// Fit- und Kontrollpunkte, Freihand, Punkt einfügen
    private var splineFamily: Family {
        let kinds = SplineKind.allCases.map { kind in
            IconChoice(id: "kind.\(kind.rawValue)", title: kind.rawValue, icon: kind == .control ? "sc.spline_cv" : "sc.spline")
        }
        let inputs = [SplineInput.freehand, SplineInput.insert].map { input in
            IconChoice(id: "input.\(input.rawValue)", title: input.rawValue, icon: input.systemImage)
        }
        let selected = sketch.splineInput == .points ? "kind.\(sketch.splineKind.rawValue)" : "input.\(sketch.splineInput.rawValue)"
        return Family(choices: kinds + inputs, selected: selected) { id in
            if let kind = SplineKind.allCases.first(where: { "kind.\($0.rawValue)" == id }) {
                sketch.splineInput = .points
                sketch.splineKind = kind
            } else if let input = SplineInput.allCases.first(where: { "input.\($0.rawValue)" == id }) {
                sketch.splineInput = input
            }
        }
    }

    private var chamferFamily: Family {
        let choices = ChamferType.allCases.map { type in
            IconChoice(id: type.rawValue, title: type.rawValue, icon: Self.chamferIcon(type))
        }
        return Family(choices: choices, selected: options.chamferType.rawValue) { id in
            if let type = ChamferType(rawValue: id) { options.chamferType = type }
        }
    }

    private static func chamferIcon(_ type: ChamferType) -> String {
        switch type {
        case .equalDistance: "sc.sketch_chamfer"
        case .twoDistances: "ruler"
        case .distanceAngle: "angle"
        }
    }

    private var offsetFamily: Family {
        let choices = OffsetDirectionMode.allCases.map { mode in
            IconChoice(id: mode.rawValue, title: mode.rawValue, icon: Self.offsetIcon(mode))
        }
        return Family(choices: choices, selected: options.offsetMode.rawValue) { id in
            if let mode = OffsetDirectionMode(rawValue: id) { options.offsetMode = mode }
        }
    }

    private static func offsetIcon(_ mode: OffsetDirectionMode) -> String {
        switch mode {
        case .oneSide: "arrow.right"
        case .twoSides: "arrow.left.arrow.right"
        case .symmetric: "arrow.left.and.right"
        }
    }

    /// Familie „Schneiden“: Beschneiden, Teilen an Punkt, Unterbrechen, Verlängern
    private var cutFamily: Family {
        let tools: [SketchTool] = [.trim, .splitAtPoint, .breakCurve, .extend]
        let choices = tools.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) }
        return Family(choices: choices, selected: sketch.tool.rawValue) { id in
            if let tool = SketchTool(rawValue: id) { sketch.tool = tool }
        }
    }
}

// MARK: Felder

/// Werte des Werkzeugs (B.3 der Spezifikation). Zeichenwerte sind sperrbar (`options.locked`), Werkzeugwerte
/// (Radius, Abstand, Faktor) gehen direkt auf den Controller.
private struct SketchToolFields: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        switch sketch.tool {
        case .polyline: lineFields
        case .rectangle: rectangleFields
        case .circle: circleFields
        case .arc: arcFields
        case .polygon: polygonFields
        case .slot: slotFields
        case .spline: splineFields
        case .text: TextToolFields(sketch: sketch)
        case .fillet: filletFields
        case .chamfer: ChamferFields(sketch: sketch, options: options)
        case .offset: OffsetFields(sketch: sketch, options: options)
        case .scale: scaleFields
        case .mirror: mirrorFields
        case .rectPattern: RectPatternFields(sketch: sketch)
        case .circPattern: circPatternFields
        case .measure: measureFields
        default: EmptyView()
        }
    }

    private func lock(_ title: String, unit: String = "mm") -> PaletteLockRow {
        PaletteLockRow(title: title, key: title, unit: unit, live: sketch.paletteLiveValue(title), options: options)
    }

    // MARK: Erstellen

    private var lineFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            lock("Länge")
            lock("Winkel", unit: "°")
            Text("Richtung")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Richtungssperre für den nächsten Strich (SketchUp: Shift bzw. Pfeiltasten)
            IconSegment(choices: DirectionLock.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) },
                        selected: Set(sketch.directionLock.map { [$0.rawValue] } ?? [])) { id in
                let chosen = DirectionLock(rawValue: id)
                sketch.directionLock = sketch.directionLock == chosen ? nil : chosen
            }
            if sketch.hasOpenChain {
                PrimaryWideButton(title: "Linie absetzen", systemImage: "scissors", isPrimary: false, action: sketch.endChain)
            }
        }
    }

    private var rectangleFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            lock("Breite")
            lock("Höhe")
            if sketch.paletteRectangleRounded {
                lock("Radius")
            }
        }
    }

    @ViewBuilder private var circleFields: some View {
        if sketch.circleMode == .center || sketch.circleMode == .twoPoint {
            lock("Durchmesser")
        }
    }

    @ViewBuilder private var arcFields: some View {
        if sketch.arcMode == .center {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                lock("Radius")
                lock("Bogenwinkel", unit: "°")
            }
        }
    }

    private var polygonFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CountRow(title: "Seiten", value: $sketch.polygonSides, range: 3...200)
            lock("Radius")
        }
    }

    private var slotFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            lock("Länge")
            lock("Breite")
        }
    }

    @ViewBuilder private var splineFields: some View {
        if sketch.hasOpenSpline {
            PrimaryWideButton(title: "Spline beenden", systemImage: "checkmark", action: sketch.finishSpline)
        }
    }

    // MARK: Ändern

    private var filletFields: some View {
        PaletteNumberRow(title: "Radius", value: sketch.filletRadius) { value in
            if value > 0 { sketch.filletRadius = value }
        }
    }

    private var scaleFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteNumberRow(title: "Faktor", value: sketch.scaleFactor, unit: "×") { value in
                if value > 0 { sketch.scaleFactor = value }
            }
            Text(sketch.selection.isEmpty ? "Ganze Skizze" : "\(sketch.selection.count) gewählt")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryWideButton(title: "Skalieren", systemImage: "checkmark", action: sketch.applyScale)
        }
    }

    // MARK: Muster

    private var mirrorFields: some View {
        PrimaryWideButton(title: "Spiegeln", systemImage: "checkmark", action: sketch.applyTransform)
            .disabled(!sketch.canApplyTransform)
            .opacity(sketch.canApplyTransform ? 1 : 0.45)
    }

    private var circPatternFields: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CountRow(title: "Anzahl", value: $sketch.circularCount, range: 2...500)
            PaletteNumberRow(title: "Gesamtwinkel", value: sketch.circularAngle, unit: "°") { value in
                if value != 0 { sketch.circularAngle = max(-360, min(360, value)) }
            }
            PrimaryWideButton(title: "Erstellen", systemImage: "checkmark", action: sketch.applyTransform)
                .disabled(!sketch.canApplyTransform)
                .opacity(sketch.canApplyTransform ? 1 : 0.45)
        }
    }

    // MARK: Prüfen

    private var measureFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sketch.measurement.lines, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sketch.measureRefs.isEmpty {
                PrimaryWideButton(title: "Neu messen", systemImage: "arrow.counterclockwise", isPrimary: false,
                                  action: sketch.clearMeasure)
            }
        }
    }
}

/// Text: Schrift, Höhe, Ausrichtung.
private struct TextToolFields: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteLabeled(title: "Schrift") {
                FontPickerButton(selection: $sketch.textFont)
            }
            PaletteNumberRow(title: "Höhe", value: sketch.textHeight) { value in
                if value > 0 { sketch.textHeight = value }
            }
            IconSegment(choices: TextAlignmentOption.allCases.map { IconChoice(id: $0.rawValue, title: $0.rawValue,
                                                                               icon: Self.icon($0)) },
                        selected: [sketch.textAlignment.rawValue]) { id in
                if let alignment = TextAlignmentOption(rawValue: id) { sketch.textAlignment = alignment }
            }
        }
    }

    private static func icon(_ alignment: TextAlignmentOption) -> String {
        switch alignment {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

/// Fase: Abstand bzw. Abstand 1, Abstand 2, Winkel, Umkehren (SolidCraft `sketch_modify_ui.rs:477-490`).
private struct ChamferFields: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteNumberRow(title: options.chamferType == .twoDistances ? "Abstand 1" : "Abstand",
                             value: sketch.chamferDistance) { value in
                if value > 0 { sketch.chamferDistance = value }
            }
            if options.chamferType == .twoDistances {
                PaletteNumberRow(title: "Abstand 2", value: options.chamferDistance2) { value in
                    if value > 0 { options.chamferDistance2 = value }
                }
            }
            if options.chamferType == .distanceAngle {
                PaletteNumberRow(title: "Winkel", value: options.chamferAngle, unit: "°") { value in
                    if value > 0, value < 180 { options.chamferAngle = value }
                }
            }
            if options.chamferType != .equalDistance {
                CheckRow(title: "Umkehren", icon: "arrow.uturn.left", isOn: $options.chamferFlip)
            }
        }
    }
}

/// Versatz: Abstand, Abstand 2 (zwei Seiten), Umkehren, Kette, Übernehmen (SolidCraft `sketch_modify_ui.rs:416-428`).
private struct OffsetFields: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteNumberRow(title: options.offsetMode == .twoSides ? "Abstand 1" : "Abstand",
                             value: sketch.offsetDistance) { sketch.offsetDistance = $0 }
            if options.offsetMode == .twoSides {
                PaletteNumberRow(title: "Abstand 2", value: options.offsetDistance2) { options.offsetDistance2 = $0 }
            }
            if options.offsetMode != .symmetric {
                CheckRow(title: "Umkehren", icon: "arrow.uturn.left", isOn: $options.offsetFlip)
            }
            // Kette = ganze Kontur (bisher „Schleife“), aus = einzelne Kurve
            CheckRow(title: "Kette", icon: "link", isOn: Binding(get: { sketch.offsetKind == .loop }, set: { on in
                sketch.offsetKind = on ? .loop : .single
                options.offsetChain = on
            }))
            if sketch.hasOffsetTarget {
                PrimaryWideButton(title: "Übernehmen", systemImage: "checkmark", action: sketch.applyOffset)
            }
        }
    }
}

/// Rechteckmuster: Spalten und Zeilen mit Abstand (Anzahl enthält das Original).
private struct RectPatternFields: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            Text("RICHTUNG 1")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            CountRow(title: "Anzahl", value: $sketch.patternColumns, range: 1...500)
            PaletteNumberRow(title: "Abstand", value: sketch.patternSpacingX) { sketch.patternSpacingX = $0 }
            Text("RICHTUNG 2")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            CountRow(title: "Anzahl", value: $sketch.patternRows, range: 1...500)
            PaletteNumberRow(title: "Abstand", value: sketch.patternSpacingY) { sketch.patternSpacingY = $0 }
            Text("Die Anzahl enthält das Original.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryWideButton(title: "Erstellen", systemImage: "checkmark", action: sketch.applyTransform)
                .disabled(!sketch.canApplyTransform)
                .opacity(sketch.canApplyTransform ? 1 : 0.45)
        }
    }
}
