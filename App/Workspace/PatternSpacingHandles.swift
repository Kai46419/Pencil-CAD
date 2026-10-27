import SwiftUI
import simd

// Rechteckmuster (Kai, Punkt 6): zwei Ziehpfeile für den Abstand in Richtung 1 und Richtung 2 an der Mustervorschau,
// im Panel darunter „Abstand zwischen den Objekten“ (lichter Abstand = Abstand − Breite in der Richtung) und
// „Gesamtgröße“ (Ausdehnung des ganzen Musters). Gilt für das Skizzen-Rechteckmuster (SketchController) und das
// Körper-Rechteckmuster (PatternRectDriver). Die Pfeile sind HandleKind.command(…): Rasten und Haptik wie bei den
// übrigen Befehlspfeilen (Viewport.swift, CommandManipulators.swift).

/// Rechenhilfen für Abstand und Gesamtgröße eines Rechteckmusters.
enum PatternSpacingMath {
    /// Lichter Abstand zwischen zwei Exemplaren (negativ = sie überlappen)
    static func gap(spacing: Double, width: Double) -> Double {
        abs(spacing) - width
    }

    /// Ausdehnung des ganzen Musters in einer Richtung
    static func total(count: Int, spacing: Double, width: Double) -> Double {
        Double(max(count, 1) - 1) * abs(spacing) + width
    }

    /// Breite einer Box (halbe Kantenlängen) entlang einer Einheitsrichtung
    static func width(half: SIMD3<Double>, along direction: SIMD3<Double>) -> Double {
        2 * (abs(direction.x) * half.x + abs(direction.y) * half.y + abs(direction.z) * half.z)
    }
}

// MARK: - Skizze

extension SketchController {
    /// Schlüssel der beiden Abstandspfeile im Skizzen-Rechteckmuster
    static let patternHandleKeyX = "sketchPatternSpacingX"
    static let patternHandleKeyY = "sketchPatternSpacingY"

    /// Umgebendes Rechteck der gewählten Elemente (lokale Skizzenkoordinaten), nil = nichts gewählt.
    var patternSourceBox: (low: Point2, high: Point2)? {
        guard tool == .rectPattern else { return nil }
        var low = Point2(repeating: .infinity), high = Point2(repeating: -.infinity)
        func add(_ p: Point2) {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        for index in transformSources where entities.indices.contains(index) {
            let entity = entities[index]
            if case .point(let p) = entity { add(p) }
            for loop in entity.loops { loop.polygon.forEach(add) }
            for segment in entity.openSegments { segment.samples.forEach(add) }
        }
        guard low.x <= high.x, low.y <= high.y, low.x.isFinite, high.y.isFinite else { return nil }
        return (low, high)
    }
}

extension Workspace {
    /// Abstandspfeile des Skizzen-Rechteckmusters: Fuß an der Außenkante der zweiten Spalte bzw. Zeile.
    var sketchPatternHandles: [DragHandle] {
        guard sketch.isActive, sketch.tool == .rectPattern, let box = sketch.patternSourceBox else { return [] }
        let plane = sketch.plane
        let middle: Point2 = (box.low + box.high) / 2
        let blue = Self.handleBlue
        let green = SIMD3<Float>(0.25, 0.7, 0.3)
        // Negativer Abstand: Exemplare liegen auf der anderen Seite, Fuß dann an deren Außenkante
        let edgeX: Double = sketch.patternSpacingX < 0 ? box.low.x : box.high.x
        let edgeY: Double = sketch.patternSpacingY < 0 ? box.low.y : box.high.y
        let originX = SIMD3<Float>(plane.world(Point2(edgeX, middle.y)))
        let originY = SIMD3<Float>(plane.world(Point2(middle.x, edgeY)))
        let directionX = SIMD3<Float>(simd_normalize(plane.world(direction: Point2(1, 0))))
        let directionY = SIMD3<Float>(simd_normalize(plane.world(direction: Point2(0, 1))))
        return [
            DragHandle(kind: .command(SketchController.patternHandleKeyX), axisOrigin: originX, direction: directionX,
                       value: sketch.patternSpacingX, color: blue),
            DragHandle(kind: .command(SketchController.patternHandleKeyY), axisOrigin: originY, direction: directionY,
                       value: sketch.patternSpacingY, color: green),
        ]
    }

    /// Abstandspfeil im Skizzen-Rechteckmuster gezogen (true = erledigt). Bei Anzahl 1 wird daraus 2, damit das
    /// Ziehen sofort ein Exemplar zeigt.
    func applySketchPatternHandle(_ key: String, value: Double) -> Bool {
        guard sketch.isActive, sketch.tool == .rectPattern, value.isFinite else { return false }
        switch key {
        case SketchController.patternHandleKeyX:
            if sketch.patternColumns < 2 { sketch.patternColumns = 2 }
            if value != sketch.patternSpacingX { sketch.patternSpacingX = value }
            return true
        case SketchController.patternHandleKeyY:
            if sketch.patternRows < 2 { sketch.patternRows = 2 }
            if value != sketch.patternSpacingY { sketch.patternSpacingY = value }
            return true
        default:
            return false
        }
    }
}

// MARK: - Körper

@MainActor
enum PatternRectHandles {
    static let keySpacing = "spacing"
    static let keySpacing2 = "spacing2"

    /// Mitte und halbe Kantenlängen der gewählten Körper (vor der Vorschau gemerkt, CommandCache.anchors).
    static func box(_ cmd: ModelCommand) -> (center: SIMD3<Double>, half: SIMD3<Double>)? {
        guard let anchor = CommandCache.anchors[ObjectIdentifier(cmd)] else { return nil }
        // BodyCommandHelpers.cacheCenter speichert die Ecke als Richtung × Länge
        let half = simd_abs(anchor.direction * anchor.size)
        return (anchor.origin, half)
    }

    /// Einheitsrichtungen 1 und 2 (Auswahlfeld, sonst Achse; Umkehren eingerechnet)
    static func directions(_ cmd: ModelCommand, _ model: ModelStore) -> (SIMD3<Double>, SIMD3<Double>) {
        let d1 = PatternCommand.direction(cmd, input: "dir1", choice: "axis", fallback: 0, model)
        let d2 = PatternCommand.direction(cmd, input: "dir2", choice: "axis2", fallback: 1, model)
        return (unit(d1, fallback: [1, 0, 0]), unit(d2, fallback: [0, 1, 0]))
    }

    private static func unit(_ v: SIMD3<Double>, fallback: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(v)
        return length > 1e-12 ? v / length : fallback
    }

    /// Zwei Pfeile: Fuß an der Außenseite des zweiten Exemplars in Richtung 1 bzw. 2, Wert = Abstand.
    static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard let box = box(cmd) else { return [] }
        let (d1, d2) = directions(cmd, ws.model)
        let w1 = PatternSpacingMath.width(half: box.half, along: d1)
        let w2 = PatternSpacingMath.width(half: box.half, along: d2)
        let s1: Double = cmd.number(keySpacing, default: 20)
        let s2: Double = cmd.number(keySpacing2, default: 20)
        // Negativer Abstand: Exemplare liegen auf der anderen Seite, Fuß dann an deren Außenseite
        let origin1: SIMD3<Double> = box.center + d1 * (s1 < 0 ? -w1 / 2 : w1 / 2)
        let origin2: SIMD3<Double> = box.center + d2 * (s2 < 0 ? -w2 / 2 : w2 / 2)
        return [
            DragHandle(kind: .command(keySpacing), axisOrigin: SIMD3<Float>(origin1), direction: SIMD3<Float>(d1),
                       value: s1, color: Workspace.handleBlue),
            DragHandle(kind: .command(keySpacing2), axisOrigin: SIMD3<Float>(origin2), direction: SIMD3<Float>(d2),
                       value: s2, color: SIMD3<Float>(0.25, 0.7, 0.3)),
        ]
    }

    /// Pfeil gezogen: Abstand übernehmen; Anzahl 1 wird 2, damit das Ziehen sofort ein Exemplar zeigt.
    static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = kind, value.isFinite else { return }
        let countKey: String
        switch key {
        case keySpacing: countKey = "count"
        case keySpacing2: countKey = "count2"
        default: return
        }
        let fallbackCount: Double = key == keySpacing ? 4 : 1
        var changed = false
        if cmd.number(countKey, default: fallbackCount) < 2 {
            cmd.putNumber(countKey, 2)
            changed = true
        }
        if value != cmd.number(key, default: 20) {
            cmd.putNumber(key, value)
            changed = true
        }
        if changed { ws.refreshCommandPreview() }
    }
}

// MARK: - Anzeige im Panel

/// „Abstand zwischen den Objekten“ und „Gesamtgröße“ unter den Musterfeldern (schmales 160-pt-Fenster).
struct PatternSpacingInfo: View {
    /// Lichter Abstand Richtung 1 und 2 (nil = noch nichts gewählt)
    let gap1: Double?
    let gap2: Double?
    /// Gesamtgröße Richtung 1 und 2
    let total1: Double?
    let total2: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteLabeled(title: "Abstand zwischen den Objekten") {
                VStack(alignment: .leading, spacing: 2) {
                    line("R1", gap1)
                    line("R2", gap2)
                }
            }
            PaletteLabeled(title: "Gesamtgröße") {
                VStack(alignment: .leading, spacing: 2) {
                    line("R1", total1)
                    line("R2", total2)
                }
            }
        }
    }

    private func line(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.map { LengthUnit.current.format($0) } ?? "–")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(value.map { $0 < 0 } == true ? SketchTheme.warning : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}
