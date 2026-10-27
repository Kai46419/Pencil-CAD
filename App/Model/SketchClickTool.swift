import Foundation
import simd

// Zeichenwerkzeuge als Klickfolge nach SolidCraft (MIT OR Apache-2.0, crates/ui-egui/src/tools.rs, sketch_dims.rs):
// Jeder Tipp setzt einen Punkt, zwischen den Punkten folgt eine Live-Vorschau dem Stift (Schweben oder Ziehen).
// Auf dem iPad gilt zusätzlich: Aufsetzen–Ziehen–Abheben setzt die ersten beiden Punkte in einem Zug
// („von A nach B ziehen“), danach zieht der Stift den Rest auf (z. B. den 3-Punkt-Bogen), Abheben bzw. Tippen setzt
// ihn. Das Werkzeug bleibt nach der fertigen Form aktiv; jeder Fang wird beim Absetzen zu einer Bedingung.

/// Ein gesetzter Punkt der Klickfolge mit seinem Fang.
struct SketchClickPoint {
    var point: Point2
    var target: SnapTarget?
}

/// Werkzeugart der Klickfolge.
enum SketchClickKind: Equatable {
    /// Linienzug (SolidCraft `Draw(0)`): jedes Stück beginnt am Ende des vorigen
    case line
    case rectangle
    case rectangleThreePoint
    /// Kreis aus Mittelpunkt bzw. 2 Punkten
    case circle
    case circleThreePoint
    /// Kurven antippen: 2 bzw. 3 Tangenten
    case tangentCircle(Int)
    /// Start, Ende, Punkt auf dem Bogen
    case arcThreePoint
    /// Mitte, Start, Ende (der Bogenwinkel folgt dem Stift, auch über 180°)
    case arcCenter
    /// Linien- bzw. Bogenende, dann das Bogenende
    case arcTangent
    case polygon
    case slot
    case ellipse
    case point

    /// Punkte bis zur fertigen Form (0 = Kette, endet mit „Fertig“)
    var requiredPoints: Int {
        switch self {
        case .line: 0
        case .point: 1
        case .rectangle, .circle, .arcTangent, .polygon, .ellipse: 2
        case .rectangleThreePoint, .circleThreePoint, .arcThreePoint, .arcCenter, .slot: 3
        case .tangentCircle(let n): n
        }
    }

    /// Aufsetzen setzt den ersten Punkt, Abheben nach dem Ziehen den zweiten.
    var pressPlacesFirstPoint: Bool {
        switch self {
        case .point, .tangentCircle: false
        default: true
        }
    }
}

/// Zustand der laufenden Klickfolge (gehört dem SketchController).
struct SketchClickState {
    struct Press {
        /// Ungefangener Aufsetzpunkt
        var raw: Point2
        /// Fang beim Aufsetzen ohne Vorgänger (für einen neuen Linienzug)
        var fresh: SnapCandidate
        /// Das Aufsetzen hat den ersten Punkt gesetzt
        var placedFirst: Bool
        /// Linie: abseits des Zugendes aufgesetzt – Ziehen beginnt einen neuen Linienzug
        var restart: Bool
        /// Der neue Linienzug hat beim Ziehen schon begonnen (Vorschau und Fang ab dem Aufsetzpunkt)
        var restarted = false
        /// Zeitpunkt des Aufsetzens (Systemlaufzeit, s)
        var time: TimeInterval = 0
        /// Zweites Tippen eines Doppeltipps: setzt beim Antippen nichts
        var secondTap = false
        /// Vor dem Aufsetzen lief keine Form (bzw. kein Linienzug)
        var startedEmpty = false
    }

    /// Letztes Antippen für den Doppeltipp: Zeit, ungefangene Stelle und ob es eine Form begonnen hat
    struct Tap {
        var time: TimeInterval
        var raw: Point2
        var startedShape: Bool
    }

    var points: [SketchClickPoint] = []
    /// Anfang des Linienzugs (Antippen schließt ihn)
    var chainFirst: Point2?
    /// Fang am Stift während der Vorschau (Schweben bzw. Ziehen); nil nach dem Abheben
    var hover: SnapCandidate?
    /// Letzter Stiftpunkt (gefangen bzw. mit gesperrten Werten) – auch nach dem Abheben, für die Wertfelder
    var pointer: Point2?
    /// Letzter ungefangener Stiftpunkt
    var raw: Point2?
    var press: Press?
    /// Letztes Antippen (Doppeltipp-Erkennung); nil nach einem Ziehen
    var lastTap: Tap?
    /// Mittelpunkt-Bogen: mitgezählter Bogenwinkel (Bogenmaß, Vorzeichen = Drehsinn)
    var sweep = 0.0
    var lastAngle = 0.0
    /// Tangentenkreise: angetippte Kurven mit Tippstelle
    var picks: [(ref: SketchCurveRef, at: Point2)] = []
    /// Erkannte Abhängigkeit beim Aufziehen eines Kreises (PencilCAD: tangential, gleicher Radius)
    var circleInference: SketchController.CircleInference?
    /// mm je Bildschirmpunkt beim letzten Fang (für die Lage der Wertfelder)
    var mmPerPoint = 0.1
    /// Gemerkte Fangpunkte (zuletzt berührte bzw. gesetzte Punkte) für die Ausrichtung, die neuesten zuletzt
    var tracked: [(kind: SnapKind, point: Point2)] = []

    var isEmpty: Bool { points.isEmpty && picks.isEmpty }
}

extension SketchController {
    // MARK: Werkzeug

    /// Klickfolge-Werkzeug des aktuellen Werkzeugs; nil = bisherige Eingabe (klassisch bzw. andere Werkzeuge).
    /// Die neuen Varianten (Tangentialbogen, Tangentenkreise, abgerundetes Rechteck) gibt es nur als Klickfolge.
    var clickKind: SketchClickKind? {
        let solid = options.isSolidCraft
        switch tool {
        case .polyline:
            return solid ? .line : nil
        case .rectangle:
            if rectangleMode == .rounded { return .rectangle }
            guard solid else { return nil }
            return rectangleMode == .threePoint ? .rectangleThreePoint : .rectangle
        case .circle:
            switch circleMode {
            case .twoTangent: return .tangentCircle(2)
            case .threeTangent: return .tangentCircle(3)
            case .center, .twoPoint: return solid ? .circle : nil
            case .threePoint: return solid ? .circleThreePoint : nil
            }
        case .arc:
            switch arcMode {
            case .tangent: return .arcTangent
            case .threePoint: return solid ? .arcThreePoint : nil
            case .center: return solid ? .arcCenter : nil
            }
        case .polygon: return solid ? .polygon : nil
        case .slot: return solid ? .slot : nil
        case .ellipse: return solid ? .ellipse : nil
        case .point: return solid ? .point : nil
        default: return nil
        }
    }

    /// Fangradien für den Fangradius des Viewports (20 Bildschirmpunkte in mm).
    func snapMetrics(_ tolerance: Double) -> SnapMetrics {
        SnapMetrics(mmPerPoint: max(tolerance / 20, 1e-9), input: snapInput, viewHalfHeight: viewHalfHeight)
    }

    /// Fang nach SolidCraft für einen Stiftpunkt (Schweben, Ziehen, Tippen); tracking = Winkelschritte und gemerkte
    /// Punkte der Klickfolge.
    func solidCraftSnap(_ raw: Point2, tolerance: Double, prev: Point2?, lineTool: Bool,
                        tracking: SnapTracking = SnapTracking()) -> SnapCandidate {
        let metrics = snapMetrics(tolerance)
        click.mmPerPoint = metrics.mmPerPoint
        // Fang unterdrückt: Stift fest drücken oder (SolidCraft-Modus) einen Finger auflegen
        if snapSuspended || arcModifier { return .free(raw) }
        let extra = click.points.map(\.point) + splinePoints + marks
        updateWokenCenter(raw, metrics: metrics, extra: extra)
        let gridOn = snapEnabled && snapKinds.contains(.grid)
        let step = options.gridAuto || gridStep <= 0 ? metrics.fineGridStep : gridStep
        return inference.refine(raw, prev: prev, lineTool: lineTool, metrics: metrics, midOnly: options.midpointOnly,
                                kinds: snapKinds, extra: extra, woken: wokenCenter, fineStep: step, gridOn: gridOn,
                                tracking: tracking)
    }

    // MARK: Ausrichtung und gemerkte Fangpunkte (PencilCAD, wie der klassische Fang bis Build 149)

    /// Höchstens so viele zuletzt berührte Punkte bleiben gemerkt
    private static let trackedLimit = 6

    /// Winkelschritte, voriges Linienstück und Ausrichtungspunkte für den Fang der Klickfolge. fresh = Fang ohne
    /// Vorgänger (Aufsetzen für einen neuen Linienzug).
    private func clickTracking(_ raw: Point2, metrics: SnapMetrics, fresh: Bool) -> SnapTracking {
        var tracking = SnapTracking()
        if !fresh {
            tracking.angleSteps = clickKind == .line || clickKind == .rectangleThreePoint && click.points.count == 1
            if tracking.angleSteps { tracking.previous = previousSegment() }
        }
        guard snapKinds.contains(.alignment) else { return tracking }
        var points = click.tracked.map { $0.point } + click.points.map(\.point)
        if let first = click.chainFirst { points.append(first) }
        points += inference.alignmentPoints(near: raw, reach: metrics.alignReach, kinds: snapKinds)
        var unique: [Point2] = []
        for p in points where !unique.contains(where: { simd_distance($0, p) < 1e-9 }) { unique.append(p) }
        tracking.points = unique
        return tracking
    }

    /// Linie, an deren Ende der vorige Punkt liegt: Richtung, in der sie dort weiterliefe (für den Winkel zum
    /// vorigen Stück und das gerade Weiterzeichnen).
    private func previousSegment() -> (direction: Point2, ref: SketchCurveRef)? {
        guard let last = click.points.last, case .point(let ref?)? = last.target, entities.indices.contains(ref.entity),
              ref.index <= 1, case .line(let a, let b) = entities[ref.entity] else { return nil }
        let from = ref.index == 1 ? a : b
        let at = ref.index == 1 ? b : a
        guard simd_distance(from, at) > 1e-9, simd_distance(at, last.point) < 1e-6 else { return nil }
        return (simd_normalize(at - from), SketchCurveRef(entity: ref.entity, index: 0))
    }

    /// Punkt merken (zuletzt berührt bzw. gesetzt), ohne Doppelte, höchstens trackedLimit.
    private func rememberTracked(_ kind: SnapKind, _ p: Point2) {
        click.tracked.removeAll { simd_distance($0.point, p) < 1e-9 }
        click.tracked.append((kind: kind, point: p))
        if click.tracked.count > Self.trackedLimit { click.tracked.removeFirst(click.tracked.count - Self.trackedLimit) }
    }

    /// Gemerkte Fangpunkte pflegen und für die Anzeige sammeln: Punktfänge am Stift werden gemerkt, verfallene
    /// (z. B. nach Rückgängig) fallen weg; angezeigt werden die Fangpunkte in Stiftnähe und die gemerkten.
    private func updateTracking(_ snapped: SnapCandidate, raw: Point2, metrics: SnapMetrics) {
        click.tracked.removeAll { !inference.holds($0.point) }
        if let kind = inference.trackKind(snapped.target, at: snapped.point) { rememberTracked(kind, snapped.point) }
        var shown = inference.trackedNodes(near: raw, radius: metrics.trackRadius, kinds: snapKinds,
                                           extra: click.points.map(\.point))
        for item in click.tracked where !shown.contains(where: { simd_distance($0.point, item.point) < 1e-9 }) {
            shown.append(item)
        }
        clickTrackedPoints = shown
    }

    /// SolidCraft `wake_centre`: der Rand eines Kreises bzw. Bogens unter dem Stift weckt dessen Mitte; sie bleibt
    /// wach, solange der Stift durchs Innere zu ihr wandert. Ein anderer Punkt bzw. eine andere Kurve lässt sie schlafen.
    private func updateWokenCenter(_ raw: Point2, metrics: SnapMetrics, extra: [Point2]) {
        if let node = inference.pointHit(raw, metrics: metrics, kinds: snapKinds, extra: extra) {
            if let woken = wokenCenter, simd_distance(woken, node.point) < 1e-9 { return }
            wokenCenter = nil
            return
        }
        guard let curve = inference.curveHit(raw, radius: metrics.curvePick) else { return }
        wokenCenter = snapKinds.contains(.center) ? curve.shape.round?.center : nil
    }

    // MARK: Gesperrte Werte (sketch_dims.rs `effective`)

    /// Wert eines gesperrten Felds (mm bzw. Bogenmaß; „Seiten“ als Zahl); nil = folgt dem Stift.
    func lockedValue(_ key: String) -> Double? {
        guard let text = options.locked[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        switch key {
        case "Winkel", "Bogenwinkel":
            return (try? Formula.evaluate(text, variables: variableValues)).map { $0 * .pi / 180 }
        case "Seiten":
            return try? Formula.evaluate(text, variables: variableValues)
        default:
            return try? Formula.evaluateLength(text, variables: variableValues)
        }
    }

    /// Wertfelder der aktuellen Stufe (SolidCraft `boxes_for`).
    var clickBoxKeys: [String] {
        guard let kind = clickKind else { return [] }
        let n = click.points.count
        switch (kind, n) {
        case (.line, let n) where n >= 1: return ["Länge", "Winkel"]
        case (.rectangle, 1): return rectangleMode == .rounded ? ["Breite", "Höhe", "Radius"] : ["Breite", "Höhe"]
        case (.circle, 1): return ["Durchmesser"]
        case (.arcCenter, 1): return ["Radius"]
        case (.arcCenter, 2): return ["Bogenwinkel"]
        case (.polygon, 1): return ["Radius", "Seiten"]
        case (.slot, 1): return ["Länge"]
        case (.slot, 2): return ["Breite"]
        default: return []
        }
    }

    private var hasLockedBox: Bool {
        clickBoxKeys.contains { lockedValue($0) != nil }
    }

    private static func direction(_ v: Point2) -> Point2 {
        let length = simd_length(v)
        return length > 1e-12 ? v / length : Point2(1, 0)
    }

    private static func sign(_ x: Double) -> Double { x < 0 ? -1 : 1 }

    /// Nächster Punkt für den Stift an h, mit den gesperrten Werten.
    func clickEffective(_ h: Point2, axisLimit: Double) -> Point2 {
        guard let kind = clickKind, let a = click.points.last?.point else { return h }
        let first = click.points.first?.point ?? a
        let n = click.points.count
        let v = h - a
        switch (kind, n) {
        case (.line, _):
            let length = lockedValue("Länge") ?? simd_length(v)
            let angle = lockedValue("Winkel") ?? SketchInference.snapAxis(atan2(v.y, v.x), limit: axisLimit)
            return a + Point2(cos(angle), sin(angle)) * length
        case (.rectangle, 1):
            let half = rectangleMode == .center ? 0.5 : 1.0
            let w = lockedValue("Breite").map { $0 * half * Self.sign(v.x) } ?? v.x
            let hh = lockedValue("Höhe").map { $0 * half * Self.sign(v.y) } ?? v.y
            return a + Point2(w, hh)
        case (.circle, 1):
            let factor = circleMode == .center ? 0.5 : 1.0
            return a + Self.direction(v) * (lockedValue("Durchmesser").map { $0 * factor } ?? simd_length(v))
        case (.arcCenter, 1), (.polygon, 1):
            return a + Self.direction(v) * (lockedValue("Radius") ?? simd_length(v))
        case (.arcCenter, 2):
            let r = simd_distance(a, first)
            let a0 = atan2(a.y - first.y, a.x - first.x)
            let sweep = lockedValue("Bogenwinkel") ?? click.sweep
            return first + Point2(cos(a0 + sweep), sin(a0 + sweep)) * r
        case (.slot, 1):
            guard let length = lockedValue("Länge") else { return h }
            return a + Self.direction(v) * (slotMode == .centerPoint ? length * 0.5 : length)
        case (.slot, 2):
            guard let width = lockedValue("Breite") else { return h }
            let along = Self.direction(a - first)
            let normal = Point2(-along.y, along.x)
            let side = Self.sign(simd_dot(normal, h - first))
            return first + (a - first) * 0.5 + normal * (width * 0.5 * side)
        default:
            return h
        }
    }

    /// Punkt, den ein Tipp setzt (SolidCraft `placed`): getippte Werte schlagen jeden Fang; ein freies Linienende
    /// rastet auf waagerecht/senkrecht (2,5°), eines auf einer Kurve wandert an den Achsschnitt.
    func clickPlaced(_ candidate: SnapCandidate, metrics: SnapMetrics) -> SnapCandidate {
        guard let kind = clickKind, let a = click.points.last?.point else { return candidate }
        if hasLockedBox {
            let p = clickEffective(candidate.point, axisLimit: metrics.axisSnap)
            // Nur die Länge getippt: ein eingerasteter Winkel bleibt samt Leitlinie (die Richtung ändert sich nicht)
            var alongRay = false
            switch candidate.target {
            case .some(.horizontal), .some(.vertical), .some(.angle), .some(.parallel), .some(.perpendicular):
                alongRay = true
            default: break
            }
            if kind == .line, alongRay, lockedValue("Winkel") == nil, let target = candidate.target,
               simd_distance(candidate.point, a) > 1e-9, simd_distance(p, a) > 1e-9 {
                let u = simd_normalize(candidate.point - a), w = simd_normalize(p - a)
                if abs(u.x * w.y - u.y * w.x) < 1e-9, simd_dot(u, w) > 0 {
                    return SnapCandidate(point: p, target: target, guide: (a, p), label: candidate.label)
                }
            }
            return SnapCandidate.free(p)
        }
        guard kind == .line else {
            var result = candidate
            result.point = clickEffective(candidate.point, axisLimit: metrics.axisSnap)
            return result
        }
        if case .throughCenter? = candidate.target { return candidate }
        // Leitlinien (Winkelschritt, Ausrichtung, //, ⊥, Verlängerung) liegen schon genau: kein Achsfang darüber
        if candidate.target?.isGuide == true { return candidate }
        if !candidate.hasArgument {
            let p = clickEffective(candidate.point, axisLimit: metrics.axisSnap)
            if simd_distance(p, candidate.point) < 1e-9 { return candidate }
            // Achsfang: H/V statt der Inferenz
            let axis: SnapTarget = abs(p.y - a.y) < 1e-9 ? .horizontal : .vertical
            return SnapCandidate(point: p, target: axis, guide: nil, label: "")
        }
        // Schnitt einer Leitlinie mit der Kurve: liegt schon genau
        if candidate.guide != nil { return candidate }
        return inference.onCurveAxis(start: a, candidate: candidate, limit: metrics.axisSnap) ?? candidate
    }

    /// Fang des Stifts für die Klickfolge (mit PencilCAD-Kreis-Erkennung beim Mittelpunkt-Kreis).
    private func clickCandidate(_ raw: Point2, tolerance: Double) -> SnapCandidate {
        let metrics = snapMetrics(tolerance)
        let lineTool = clickKind == .line
        let tracking = clickTracking(raw, metrics: metrics, fresh: false)
        let snapped = solidCraftSnap(raw, tolerance: tolerance, prev: click.points.last?.point, lineTool: lineTool,
                                     tracking: tracking)
        updateTracking(snapped, raw: raw, metrics: metrics)
        // Mittelpunkt-Bogen: den Bogenwinkel mit dem Stiftpunkt mitzählen, bevor clickEffective den Punkt auf den
        // Kreis beim bisherigen Winkel legt – sonst zählte trackSweep den schon gelegten Punkt, der Winkel blieb 0
        // und nach Mitte und Start erschien nur die Radiuslinie, nie ein Bogen (Kai)
        trackSweep(snapped.point)
        var result = clickPlaced(snapped, metrics: metrics)
        // 3-Punkt-Bogen bzw. -Kreis: ein Fang (z. B. waagerecht zum Ende B einer waagerechten Sehne), der den dritten
        // Punkt auf die Gerade A–B legt, ergäbe keinen Bogen – dann gilt der freie Stiftpunkt
        if click.points.count == 2, clickKind == .arcThreePoint || clickKind == .circleThreePoint, !hasLockedBox {
            let a = click.points[0].point, b = click.points[1].point
            if circleThrough(a, result.point, b) == nil, circleThrough(a, raw, b) != nil { result = .free(raw) }
        }
        click.circleInference = nil
        // PencilCAD-Mehrwert: Radius rastet tangential bzw. auf gleichen Radius ein, solange der Randpunkt keinen
        // Punktfang hat und nichts getippt ist
        if clickKind == .circle, circleMode == .center, click.points.count == 1, !hasLockedBox,
           !result.hasArgument, !snapSuspended, !arcModifier,
           let found = inferCircle(center: click.points[0].point, raw: raw, tolerance: tolerance) {
            click.circleInference = found
            let label = found.label.hasPrefix("Gleich") ? "=" : found.label.hasPrefix("Durch") ? "Pt" : "T"
            result = SnapCandidate(point: found.point, target: nil, guide: nil, label: label)
        }
        click.pointer = result.point
        click.raw = raw
        return result
    }

    /// Mittelpunkt-Bogen: Bogenwinkel des Stifts mitzählen (PencilCAD, auch über 180° und im Uhrzeigersinn).
    private func trackSweep(_ p: Point2) {
        guard clickKind == .arcCenter, click.points.count == 2 else { return }
        let c = click.points[0].point
        guard simd_distance(p, c) > 1e-9 else { return }
        let angle = atan2(p.y - c.y, p.x - c.x)
        click.sweep += remainder(angle - click.lastAngle, 2 * .pi)
        click.lastAngle = angle
    }

    /// Fang, der gerade gezeigt wird (Ziehen vor Schweben); nil = kein SolidCraft-Fang.
    var currentCandidate: SnapCandidate? {
        activeCandidate ?? hoverCandidate
    }

    // MARK: Eingabe

    func clickHover(at raw: Point2, tolerance: Double) {
        guard clickKind != nil else { return }
        if case .tangentCircle? = clickKind {
            hoverCandidate = nil
            click.hover = nil
            changed(publish: false)
            return
        }
        let candidate = clickCandidate(raw, tolerance: tolerance)
        click.hover = candidate
        hoverCandidate = candidate
        changed(publish: false)
    }

    /// Doppeltipp: höchstens so lange (s) nach dem vorigen Antippen …
    private static let doubleTapInterval: TimeInterval = 0.4
    /// Kürzer als das (s) und kaum bewegt: Antippen, auch wenn der Stift beim Andrücken etwas zittert
    private static let quickTapDuration: TimeInterval = 0.2

    /// Zweites Tippen eines Doppeltipps: kurz nach dem vorigen Antippen und nahe dabei.
    private func isSecondTap(_ raw: Point2, now: TimeInterval, metrics: SnapMetrics) -> Bool {
        guard let tap = click.lastTap else { return false }
        return now - tap.time <= Self.doubleTapInterval && simd_distance(tap.raw, raw) <= metrics.tapSlop * 3
    }

    func clickBegan(at raw: Point2, tolerance: Double) {
        guard let kind = clickKind else { return }
        hoverCandidate = nil
        let metrics = snapMetrics(tolerance)
        let now = ProcessInfo.processInfo.systemUptime
        // Kai: Zeichnen per Antippen statt Drücken – das zweite Tippen eines Doppeltipps setzt beim Aufsetzen nichts
        // (sonst begann es nach dem ersten Tippen gleich die nächste Form bzw. ein Stück der Länge null)
        let secondTap = isSecondTap(raw, now: now, metrics: metrics)
        let startedEmpty = click.isEmpty
        if case .tangentCircle = kind {
            click.press = SketchClickState.Press(raw: raw, fresh: .free(raw), placedFirst: false, restart: false,
                                                 time: now, secondTap: secondTap, startedEmpty: startedEmpty)
            changed()
            return
        }
        let fresh = solidCraftSnap(raw, tolerance: tolerance, prev: nil, lineTool: kind == .line,
                                   tracking: clickTracking(raw, metrics: metrics, fresh: true))
        let candidate = clickCandidate(raw, tolerance: tolerance)
        var placedFirst = false
        var restart = false
        if secondTap {
            // Erst beim Abheben klar: Tippen (Doppeltipp) oder Ziehen
        } else if click.points.isEmpty, kind.pressPlacesFirstPoint {
            clickPlace(candidate)
            placedFirst = !click.points.isEmpty
        } else if kind == .line, let last = click.points.last, simd_distance(last.point, fresh.point) > metrics.tapSlop {
            // Knapp neben dem Zugende aufgesetzt (ohne anderen Punktfang, z. B. auf dem letzten Stück selbst):
            // weiter am Zugende statt eines neuen, unverbundenen Linienzugs (Kai: „manchmal rastet es nicht ein“)
            let nearEnd = simd_distance(last.point, raw) <= metrics.chainReach && !(fresh.target?.isPointSnap ?? false)
            restart = !nearEnd
        }
        click.press = SketchClickState.Press(raw: raw, fresh: fresh, placedFirst: placedFirst, restart: restart,
                                             time: now, secondTap: secondTap, startedEmpty: startedEmpty)
        let shown = placedFirst ? clickCandidate(raw, tolerance: tolerance) : candidate
        click.hover = shown
        activeCandidate = shown
        changed()
    }

    func clickMoved(to raw: Point2, tolerance: Double) {
        guard let press = click.press, let kind = clickKind else { return }
        if case .tangentCircle = kind { return }
        // Abseits des Zugendes gezogen: der neue Linienzug beginnt sofort, damit Vorschau, Winkel und Fang vom
        // Aufsetzpunkt ausgehen (vorher erst beim Abheben – gezeigt wurde ein Fang zum alten Zugende)
        if press.restart, !press.restarted, simd_distance(raw, press.raw) > snapMetrics(tolerance).tapSlop {
            beginChain(at: press.fresh)
            click.press?.restarted = true
        }
        let candidate = clickCandidate(raw, tolerance: tolerance)
        click.hover = candidate
        activeCandidate = candidate
        changed(publish: false)
    }

    func clickEnded(at raw: Point2, tolerance: Double) {
        guard let press = click.press, let kind = clickKind else { return }
        click.press = nil
        let metrics = snapMetrics(tolerance)
        let now = ProcessInfo.processInfo.systemUptime
        let moved = simd_distance(raw, press.raw)
        // Kurz angetippt und dabei etwas verrutscht (Stift-Zittern beim Andrücken): bleibt ein Antippen
        let quickTap = now - press.time < Self.quickTapDuration && moved <= metrics.tapSlop * 2
        // Hat das Ziehen schon einen neuen Linienzug begonnen, bleibt es ein Ziehen
        let dragged = press.restarted || moved > metrics.tapSlop && !quickTap
        if case .tangentCircle(let count) = kind {
            activeCandidate = nil
            // Doppeltipp auf dieselbe Kurve wählt sie nicht gleich wieder ab
            if !dragged, !press.secondTap { pickTangentCurve(at: raw, metrics: metrics, count: count) }
            click.lastTap = dragged || press.secondTap ? nil : SketchClickState.Tap(time: now, raw: raw, startedShape: false)
            changed()
            return
        }
        if press.secondTap, !dragged {
            // Doppeltipp: das erste Tippen hat den Punkt gesetzt (bzw. die Form beendet). Hat es einen Linienzug erst
            // begonnen, bleibt der Startpunkt stehen – die Vorschau folgt dem schwebenden Stift; hat es ein Stück
            // angehängt, ist der Linienzug fertig.
            if kind == .line, let tap = click.lastTap, !tap.startedShape, !click.points.isEmpty {
                click.points = []
                click.chainFirst = nil
                if !options.locked.isEmpty { options.locked = [:] }
            }
            click.lastTap = nil
            activeCandidate = nil
            click.hover = nil
            changed()
            return
        }
        // Beim Abheben zittert der Stift: es gilt der zuletzt gezeigte Punkt
        var candidate: SnapCandidate
        // (bis zur Tipp-Schwelle; ein gezeigter Punktfang bleibt, solange der Stift in seinem Fangradius abhebt)
        if dragged, let shown = click.hover, let last = click.raw,
           simd_distance(last, raw) <= metrics.tapSlop
            || ((shown.target?.isPointSnap ?? false) && simd_distance(shown.point, raw) <= metrics.pointPick) {
            candidate = shown
        } else {
            candidate = clickCandidate(raw, tolerance: tolerance)
        }
        // Linie: den letzten Punkt angetippt, ohne dass der Fang ihn traf (z. B. Fang aus) – beendet den Zug statt
        // ein winziges Stück anzuhängen
        if kind == .line, !dragged, !hasLockedBox, let last = click.points.last,
           simd_distance(raw, last.point) <= metrics.tapSlop * 2, simd_distance(candidate.point, last.point) > 1e-9 {
            candidate = .free(last.point)
        }
        activeCandidate = nil
        if press.secondTap, dragged, click.points.isEmpty, kind.pressPlacesFirstPoint {
            // Doppeltippen und gleich ziehen: wie Aufsetzen–Ziehen–Abheben von A nach B
            clickPlace(press.fresh)
            if !click.points.isEmpty {
                candidate = clickCandidate(raw, tolerance: tolerance)
                clickPlace(candidate)
            }
        } else if press.placedFirst {
            if dragged { clickPlace(candidate) }
        } else if press.restart, dragged {
            // Abseits des Zugendes gezogen: neuer Linienzug ab dem Aufsetzpunkt (meist schon beim Ziehen begonnen)
            if !press.restarted {
                beginChain(at: press.fresh)
                candidate = clickCandidate(raw, tolerance: tolerance)
            }
            clickPlace(candidate)
        } else {
            clickPlace(candidate)
        }
        // Merken fürs Doppeltippen; „begonnen“ = vorher lief nichts, jetzt eine Form bzw. ein Linienzug
        click.lastTap = dragged ? nil
            : SketchClickState.Tap(time: now, raw: raw, startedShape: press.startedEmpty && !click.points.isEmpty)
        click.hover = nil
        // Nach dem Abheben nur noch die gemerkten Fangpunkte zeigen (die in Stiftnähe folgen beim Schweben)
        clickTrackedPoints = click.tracked
        changed()
    }

    /// Neuer Linienzug ab dem Fang beim Aufsetzen.
    private func beginChain(at fresh: SnapCandidate) {
        if !options.locked.isEmpty { options.locked = [:] }
        click.points = [SketchClickPoint(point: fresh.point, target: fresh.target)]
        click.chainFirst = fresh.point
        placedPointCount += 1
    }

    /// Mit den getippten Werten setzen (Enter im Wertfeld); der Stift bestimmt nur noch die Seite.
    func placeLocked() {
        guard clickKind != nil, hasLockedBox, let last = click.points.last?.point else { return }
        let h = click.pointer ?? last + Point2(1, 0)
        let p = clickEffective(h, axisLimit: 2.5 * .pi / 180)
        clickPlace(SnapCandidate.free(p))
        click.hover = nil
        changed()
    }

    /// Laufende Form verwerfen (SolidCraft Esc). false = es lief keine.
    @discardableResult
    func cancelClickShape() -> Bool {
        let had = !click.isEmpty || click.press != nil
        let keepPointer = click.mmPerPoint
        click = SketchClickState()
        click.mmPerPoint = keepPointer
        clickTrackedPoints = []
        activeCandidate = nil
        hoverCandidate = nil
        if !options.locked.isEmpty { options.locked = [:] }
        return had
    }

    // MARK: Punkt setzen

    private func clickPlace(_ candidate: SnapCandidate) {
        guard let kind = clickKind else { return }
        let point = SketchClickPoint(point: candidate.point, target: candidate.target)
        defer { if options.midpointOnly { options.midpointOnly = false } }
        // Gesetzte Punkte bleiben für die Ausrichtung gemerkt (auch frühere Ecken des Linienzugs)
        rememberTracked(inference.trackKind(candidate.target, at: candidate.point) ?? .endpoint, candidate.point)
        if kind == .line {
            placeLinePoint(point)
            return
        }
        // Derselbe Punkt zweimal als erster und zweiter Punkt hat keine Ausdehnung: weiter warten
        if click.points.count == 1, simd_distance(click.points[0].point, point.point) < 1e-9, !hasLockedBox {
            return
        }
        if kind == .arcTangent, click.points.isEmpty, tangentStart(point) == nil {
            notice = "Tangentialbogen: am Ende einer Linie oder eines Bogens ansetzen."
            return
        }
        click.points.append(point)
        placedPointCount += 1
        if kind == .arcCenter, click.points.count == 2 {
            let c = click.points[0].point, s = point.point
            click.lastAngle = atan2(s.y - c.y, s.x - c.x)
            click.sweep = 0
        }
        guard click.points.count >= kind.requiredPoints else { return }
        let placed = click.points
        let inference = click.circleInference
        let sweep = lockedValue("Bogenwinkel") ?? click.sweep
        commitClickShape(kind, placed, sweep: sweep, circleInference: inference)
        click.points = []
        click.circleInference = nil
        click.sweep = 0
        if !options.locked.isEmpty { options.locked = [:] }
    }

    /// Linienzug: erster Punkt beginnt, jeder weitere setzt ein Stück; der letzte Punkt nochmal beendet den Zug,
    /// der Anfang schließt ihn.
    private func placeLinePoint(_ point: SketchClickPoint) {
        guard let last = click.points.last else {
            click.points = [point]
            click.chainFirst = point.point
            placedPointCount += 1
            return
        }
        if simd_distance(last.point, point.point) < 1e-9 {
            if !hasLockedBox {
                // Letzten Punkt erneut angetippt: Linienzug fertig
                click.points = []
                click.chainFirst = nil
            }
            return
        }
        guard let index = commitLine(from: last, to: point) else { return }
        placedPointCount += 1
        if !options.locked.isEmpty { options.locked = [:] }
        if let first = click.chainFirst, simd_distance(first, point.point) < 1e-9 {
            // Zurück am Anfang: geschlossen
            click.points = []
            click.chainFirst = nil
            return
        }
        click.points = [SketchClickPoint(point: point.point, target: .point(SketchPointRef(entity: index, index: 1)))]
    }

    /// Anfang des Tangentialbogens: Richtung, in der die Kurve dort weiterläuft, und die Kurve selbst.
    private func tangentStart(_ point: SketchClickPoint) -> (direction: Point2, entity: Int)? {
        guard case .point(let ref?)? = point.target, entities.indices.contains(ref.entity) else { return nil }
        return outwardTangent(at: point.point, tolerance: 1e-6)
    }

    // MARK: Tangentenkreise

    private func pickTangentCurve(at raw: Point2, metrics: SnapMetrics, count: Int) {
        guard let curve = inference.curveHit(raw, radius: metrics.curvePick) else {
            notice = "Linie, Kreis oder Bogen antippen."
            return
        }
        if case .polyline = curve.shape {
            notice = "Tangentenkreis: nur Linien, Kreise und Bögen."
            return
        }
        if click.picks.contains(where: { $0.ref == curve.ref }) {
            click.picks.removeAll { $0.ref == curve.ref }
            return
        }
        click.picks.append((curve.ref, raw))
        placedPointCount += 1
        guard click.picks.count >= count else { return }
        let picks = click.picks
        click.picks = []
        if count == 2 {
            commitTwoTangentCircle(picks)
        } else {
            commitThreeTangentCircle(picks)
        }
    }

    /// Angetippte Kurven der Tangentenkreise (hervorgehoben).
    var clickPickedPolylines: [[Point2]] {
        click.picks.compactMap { curvePolyline($0.ref) }
    }

    // MARK: Vorschau

    /// Formen der Live-Vorschau (exakt die spätere Geometrie) und das Gummiband.
    var clickPreview: (shapes: [SketchEntity], lines: [[Point2]]) {
        guard let kind = clickKind else { return ([], []) }
        let points = click.points.map(\.point)
        let h = click.hover?.point
        var shapes: [SketchEntity] = []
        var lines: [[Point2]] = []
        switch (kind, points.count) {
        case (.line, 1), (.rectangleThreePoint, 1), (.circleThreePoint, 1), (.arcThreePoint, 1), (.slot, 1):
            if let h { lines.append([points[0], h]) }
        case (.rectangle, 1):
            if let h { shapes += rectangleShapes(points[0], h) }
        case (.rectangleThreePoint, 2):
            if let h {
                let corners = Self.threePointCorners(points[0], points[1], h)
                shapes.append(.polyline(corners, closed: true))
            } else {
                lines.append(points)
            }
        case (.circle, 1):
            if let h, let circle = circleShape(points[0], h) {
                shapes.append(circle)
                if circleMode == .center { lines.append([points[0], h]) }
            }
        case (.circleThreePoint, 2):
            if let h, let circle = SketchShapes.circle(through: points[0], points[1], h) {
                shapes.append(circle)
            } else {
                lines.append(points)
            }
        case (.arcThreePoint, 2):
            // Bogen von A nach B durch den Stift; auf der anderen Seite der Sehne klappt er um
            if let h, circleThrough(points[0], h, points[1]) != nil {
                shapes.append(.arc(start: points[0], mid: h, end: points[1]))
            } else {
                lines.append(points)
            }
        case (.arcCenter, 1):
            if let h {
                lines.append([points[0], h])
                shapes.append(.circle(center: points[0], radius: simd_distance(points[0], h)))
            }
        case (.arcCenter, 2):
            lines.append(points)
            let sweep = lockedValue("Bogenwinkel") ?? click.sweep
            if let arc = SketchShapes.arc(center: points[0], start: points[1], sweep: sweep) { shapes.append(arc) }
        case (.arcTangent, 1):
            if let h, let start = tangentStart(click.points[0]),
               let arc = Self.tangentArcShape(start: points[0], direction: start.direction, end: h) {
                shapes.append(arc)
            } else if let h {
                lines.append([points[0], h])
            }
        case (.polygon, 1):
            if let h, let polygon = SketchShapes.polygon(center: points[0], through: h, sides: polygonSideCount,
                                                         mode: polygonMode) {
                shapes.append(polygon)
                lines.append([points[0], h])
            }
        case (.slot, 2):
            if let h, let slot = slotEntities(base: (points[0], points[1]), through: h) {
                shapes += slot
            } else {
                lines.append(points)
            }
        case (.ellipse, 1):
            if let h { shapes.append(.ellipse(center: points[0], radii: simd_abs(h - points[0]))) }
        default:
            break
        }
        return (shapes, lines)
    }

    /// Gezeigtes Gummiband der Linie ist genau waagerecht bzw. senkrecht: Mitte und Richtung für das „H“/„V“.
    var rubberBandAxis: (mid: Point2, horizontal: Bool)? {
        guard clickKind == .line, let a = click.points.last?.point, let h = click.hover?.point,
              simd_distance(a, h) > 1e-9 else { return nil }
        if abs(h.y - a.y) < 1e-9 { return ((a + h) / 2, true) }
        if abs(h.x - a.x) < 1e-9 { return ((a + h) / 2, false) }
        return nil
    }

    var polygonSideCount: Int {
        let locked = lockedValue("Seiten").map { Int($0.rounded()) }
        return max(locked ?? polygonSides, 3)
    }

    /// Kreis der Vorschau bzw. beim Setzen (Mittelpunkt oder 2 Punkte als Durchmesser).
    private func circleShape(_ a: Point2, _ b: Point2) -> SketchEntity? {
        switch circleMode {
        case .twoPoint: return SketchShapes.circle(diameterFrom: a, to: b)
        default:
            let r = simd_distance(a, b)
            return r > 1e-9 ? .circle(center: a, radius: r) : nil
        }
    }

    /// Rechteck aus Ecke und Gegenecke (Mitte und Ecke); abgerundet als 4 Linien und 4 Bögen.
    func rectangleShapes(_ a: Point2, _ b: Point2) -> [SketchEntity] {
        let corner: Point2, size: Point2
        if rectangleMode == .center {
            let half = b - a
            corner = a - half
            size = half * 2
        } else {
            corner = a
            size = b - a
        }
        guard abs(size.x) > 1e-9, abs(size.y) > 1e-9 else { return [] }
        guard rectangleMode == .rounded else { return [.rectangle(corner: corner, size: size)] }
        let lo = simd_min(corner, corner + size), hi = simd_max(corner, corner + size)
        let w = hi.x - lo.x, hgt = hi.y - lo.y
        let r = min(roundedCornerRadius(width: w, height: hgt), min(w, hgt) / 2 - 1e-6)
        guard r > 1e-6 else { return [.rectangle(corner: lo, size: hi - lo)] }
        let k = r * (1 - 1 / 2.0.squareRoot())
        // Gegen den Uhrzeigersinn: unten, rechts, oben, links mit den Eckbögen dazwischen
        return [
            .line(Point2(lo.x + r, lo.y), Point2(hi.x - r, lo.y)),
            .arc(start: Point2(hi.x - r, lo.y), mid: Point2(hi.x - k, lo.y + k), end: Point2(hi.x, lo.y + r)),
            .line(Point2(hi.x, lo.y + r), Point2(hi.x, hi.y - r)),
            .arc(start: Point2(hi.x, hi.y - r), mid: Point2(hi.x - k, hi.y - k), end: Point2(hi.x - r, hi.y)),
            .line(Point2(hi.x - r, hi.y), Point2(lo.x + r, hi.y)),
            .arc(start: Point2(lo.x + r, hi.y), mid: Point2(lo.x + k, hi.y - k), end: Point2(lo.x, hi.y - r)),
            .line(Point2(lo.x, hi.y - r), Point2(lo.x, lo.y + r)),
            .arc(start: Point2(lo.x, lo.y + r), mid: Point2(lo.x + k, lo.y + k), end: Point2(lo.x + r, lo.y)),
        ]
    }

    /// Eckradius: getippt, sonst aus dem Panel, sonst ein Fünftel der kürzeren Seite (SolidCraft).
    func roundedCornerRadius(width: Double, height: Double) -> Double {
        lockedValue("Radius") ?? options.roundedRadius ?? min(width, height) / 5
    }

    // MARK: Live-Werte (B.4)

    /// Werte der Wertfelder der aktuellen Stufe (mm bzw. Grad, „Seiten“ als Zahl).
    var clickLiveValues: [(key: String, value: Double)] {
        let keys = clickBoxKeys
        guard !keys.isEmpty, let a = click.points.last?.point else { return [] }
        let first = click.points.first?.point ?? a
        let h = click.pointer ?? a
        let v = h - a
        return keys.compactMap { key -> (key: String, value: Double)? in
            if key == "Seiten" { return (key, Double(polygonSideCount)) }
            if let locked = lockedValue(key) {
                let shown = key == "Winkel" || key == "Bogenwinkel" ? locked * 180 / .pi : locked
                return (key, shown)
            }
            let value: Double
            switch key {
            case "Länge":
                value = clickKind == .slot && slotMode == .centerPoint ? 2 * simd_length(v) : simd_length(v)
            case "Winkel":
                var degrees = atan2(v.y, v.x) * 180 / .pi
                if degrees < 0 { degrees += 360 }
                value = simd_length(v) > 1e-9 ? degrees : 0
            case "Breite":
                if clickKind == .slot {
                    value = 2 * SketchShapes.slotHalfWidth(first, a, through: h)
                } else {
                    value = abs(v.x) * (rectangleMode == .center ? 2 : 1)
                }
            case "Höhe":
                value = abs(v.y) * (rectangleMode == .center ? 2 : 1)
            case "Durchmesser":
                value = simd_length(v) * (circleMode == .center ? 2 : 1)
            case "Radius":
                if clickKind == .rectangle {
                    let f = rectangleMode == .center ? 2.0 : 1.0
                    value = roundedCornerRadius(width: abs(v.x) * f, height: abs(v.y) * f)
                } else {
                    value = simd_length(v)
                }
            case "Bogenwinkel":
                value = click.sweep * 180 / .pi
            default:
                return nil
            }
            return (key, value)
        }
    }

    // MARK: Hinweise

    /// Hinweistext des Werkzeugs je Stufe (SolidCraft tools.rs `hint`, sketch_tools.rs `hint`, deutsch).
    var clickHint: String? {
        guard let kind = clickKind else { return nil }
        let n = click.points.count
        switch kind {
        case .line:
            return n == 0 ? "Linie: Punkte antippen (auch doppeltippen) – oder von A nach B ziehen"
                : "Linie: nächsten Punkt antippen (Länge/Winkel eintippbar) · doppeltippen, letzten Punkt erneut antippen oder „Fertig“ beendet · Anfang antippen schließt"
        case .arcThreePoint:
            switch n {
            case 0: return "Bogen: Start antippen – oder von Start nach Ende ziehen"
            case 1: return "Bogen: Ende antippen"
            default: return "Bogen: Punkt auf dem Bogen antippen – Schweben bzw. Ziehen zieht ihn auf"
            }
        case .arcCenter:
            switch n {
            case 0: return "Bogen: Mittelpunkt antippen – oder vom Mittelpunkt zum Start ziehen"
            case 1: return "Bogen: Start antippen (legt den Radius fest, eintippbar)"
            default: return "Bogen: Ende antippen – der Bogen folgt dem Stift, Bogenwinkel mit Vorzeichen eintippbar"
            }
        case .arcTangent:
            return n == 0 ? "Tangentialbogen: Ende einer Linie oder eines Bogens antippen" : "Tangentialbogen: Ende des Bogens antippen"
        case .circle:
            if circleMode == .twoPoint {
                return n == 0 ? "Kreis: zwei Enden des Durchmessers antippen oder ziehen" : "Kreis: zweites Ende antippen (Durchmesser eintippbar)"
            }
            return n == 0 ? "Kreis: Mittelpunkt antippen, dann einen Punkt auf dem Kreis – oder aufziehen"
                : "Kreis: Punkt auf dem Kreis antippen (Durchmesser eintippbar)"
        case .circleThreePoint:
            return ["Kreis: ersten Punkt antippen", "Kreis: zweiten Punkt antippen", "Kreis: dritten Punkt antippen"][min(n, 2)]
        case .tangentCircle(let count):
            let picked = click.picks.count
            return count == 2
                ? "2-Tangenten-Kreis: zwei Kurven antippen – der Kreis liegt zwischen den Stellen (\(picked)/2)"
                : "3-Tangenten-Kreis: drei Kurven antippen (\(picked)/3)"
        case .rectangle:
            switch rectangleMode {
            case .center: return n == 0 ? "Mittelpunkt-Rechteck: Mitte antippen, dann eine Ecke" : "Ecke antippen (Breite/Höhe eintippbar)"
            case .rounded: return n == 0 ? "Abgerundetes Rechteck: zwei gegenüberliegende Ecken antippen" : "Gegenecke antippen (Breite, Höhe, Eckradius eintippbar)"
            default: return n == 0 ? "Rechteck: zwei gegenüberliegende Ecken antippen oder ziehen" : "Gegenecke antippen (Breite/Höhe eintippbar)"
            }
        case .rectangleThreePoint:
            return n < 2 ? "3-Punkt-Rechteck: zwei Punkte einer Kante antippen" : "3-Punkt-Rechteck: Breite antippen"
        case .polygon:
            return n == 0 ? "Polygon: Mitte antippen, dann eine Ecke" : "Polygon: Ecke antippen (Radius, Seiten eintippbar)"
        case .slot:
            return n < 2 ? "Langloch: beide Enden antippen bzw. ziehen" : "Langloch: Breite antippen"
        case .ellipse:
            return n == 0 ? "Ellipse: Mitte antippen, dann eine Ecke" : "Ellipse: Ecke antippen"
        case .point:
            return "Punkt: antippen"
        }
    }
}
