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
    /// Build 43: zusätzlich gleich lang wie diese Linie (Parallel- bzw. Rechtwinkelfang mit gleicher Länge)
    var alsoEqual: SketchCurveRef? = nil
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
    /// Build 66 (Kai): per Fingertipp gesperrte Länge (gelb) bzw. Richtung (grün) des laufenden Linienstücks;
    /// gilt bis zum Setzen des Endpunkts, Doppeltipp mit dem Finger hebt die Sperre auf
    var latchedLength: (length: Double, ref: SketchCurveRef?)?
    var latchedDirection: (direction: Point2, target: SnapTarget)?
    /// Build 66 (Kai): Verlängerung der schrägen Linie bis zur ersten getroffenen Kurve (gestrichelt)
    var forwardHit: (from: Point2, to: Point2)?
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
    /// Ausdrücklich gemerkte Spurpunkte (Stift 0,5 s schweben lassen, Stift drücken, Finger-Doppeltipp; nochmal
    /// entmerkt): liefern Objektfangspuren (SketchInference.trackLeads), die neuesten zuletzt
    var pinned: [Point2] = []
    /// Build 43 (Linie endet nach dem Strich): Ende der zuletzt gezeichneten Linie. Hier wieder ansetzen bzw. es
    /// antippen zeichnet weiter (auch knapp daneben oder bei ausgeschaltetem Fang)
    var lastLineEnd: SketchPointRef?
    /// Build 43: Anfang der Kontur über das Weiterzeichnen hinweg (zurück am Anfang = geschlossen, wie im Linienzug)
    var contourFirst: Point2?

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
        // Fang aus (Hauptschalter „Fang“ – wirkte hier bisher nicht, Kai) bzw. unterdrückt: Stift fest drücken
        // oder (SolidCraft-Modus) einen Finger auflegen
        // Build 52 (Kai): im SolidCraft-Stil hält ein aufgelegter Finger den Stift an Punkten fest – Linienenden,
        // Zentren, Schnitte und Körperecken fangen dann dreimal so weit, alle anderen Fänge ruhen
        if arcModifier, options.isSolidCraft, snapEnabled {
            return fingerPointLock(raw, metrics: metrics)
        }
        if !snapEnabled || snapSuspended || arcModifier { return .free(raw) }
        let extra = click.points.map(\.point) + splinePoints + marks
        updateWokenCenter(raw, metrics: metrics, extra: extra)
        let gridOn = snapKinds.contains(.grid)
        let step = options.gridAuto || gridStep <= 0 ? metrics.fineGridStep : gridStep
        let found = withHelperSnap(inference.refine(raw, prev: prev, lineTool: lineTool, metrics: metrics,
                                                   midOnly: options.midpointOnly, kinds: snapKinds, extra: extra,
                                                   woken: wokenCenter, fineStep: step, gridOn: gridOn,
                                                   tracking: tracking),
                                   raw: raw, tolerance: metrics.pointPick, kinds: snapKinds)
        // Build 54 (Kai): auf einer Linie entlanggleitend rasten Anfang und Ende schon aus 2,5-facher Punktweite ein
        if case .onCurve? = found.target,
           let node = inference.pointHit(raw, metrics: metrics, kinds: [.endpoint], extra: [],
                                         reach: metrics.pointPick * Self.endpointOnCurveFactor) {
            return SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: "")
        }
        // „Entfernte Kanten“: ohne anderen Fang auf eine projizierte Körperkante (wirkte bisher nur im klassischen Stil)
        if found.target == nil || found.target == .grid, snapKinds.contains(.distantEdge),
           let edge = Self.nearestOnPolylines(raw, modelGuides.curves, reach: metrics.onCurve) {
            return SnapCandidate(point: edge, target: .modelVertex(edge), guide: nil, label: "Kante")
        }
        return found
    }

    /// Fangweite der Linienenden, solange der Stift auf der Linie gleitet (Vielfaches von pointPick)
    static let endpointOnCurveFactor = 2.5

    /// Fangweite des Punktfangs mit aufgelegtem Finger (Vielfaches von pointPick, ca. 30 pt)
    static let fingerLockFactor = 3.0

    /// Finger aufgelegt (Build 52): nächster Punkt (Ende, Zentrum, Schnitt, Körperecke, Punkte des Zugs) in
    /// großer Weite; ohne Punkt in der Nähe bleibt der Stift frei.
    func fingerPointLock(_ raw: Point2, metrics: SnapMetrics) -> SnapCandidate {
        let extra = click.points.map(\.point) + splinePoints + marks
        let reach = metrics.pointPick * Self.fingerLockFactor
        var best: (distance: Double, candidate: SnapCandidate)?
        func offer(_ point: Point2, _ candidate: @autoclosure () -> SnapCandidate) {
            let d = simd_distance(point, raw)
            guard d < reach, d < (best?.distance ?? .infinity) else { return }
            best = (d, candidate())
        }
        if let node = inference.pointHit(raw, metrics: metrics, kinds: [.endpoint, .center], extra: extra, reach: reach) {
            offer(node.point, SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: ""))
        }
        if let crossing = inference.nearestCrossing(raw, tolerance: reach, extra: extra) {
            offer(crossing.point, SnapCandidate(point: crossing.point, target: .crossing(crossing.a, crossing.b),
                                                guide: nil, label: "X"))
        }
        for q in inference.modelPoints {
            offer(q, SnapCandidate(point: q, target: .modelVertex(q), guide: nil, label: "Pt"))
        }
        return best?.candidate ?? .free(raw)
    }

    /// Rastweite der Richtung bei festgehaltener Länge (Grad)
    static let fingerAngleSnapDegrees = 5.0

    /// Build 53: Länge der laufenden Linie, wenn sie gerade gelb ist (gleich lang wie eine vorhandene Linie).
    func currentEqualLengthLock() -> (length: Double, ref: SketchCurveRef?)? {
        guard clickKind == .line, let a = click.points.last?.point, let hover = click.hover else { return nil }
        let length = simd_distance(a, hover.point)
        guard length > 1e-9 else { return nil }
        if case .equalLength(let ref)? = hover.target { return (length, ref) }
        if let ref = hover.alsoEqual { return (length, ref) }
        let tolerance = max(1e-6, length * 1e-9)
        for curve in inference.curves where !curve.construction {
            guard case .line(let p, let q) = curve.shape else { continue }
            if abs(simd_distance(p, q) - length) <= tolerance { return (length, curve.ref) }
        }
        return nil
    }

    /// Build 53: Länge fest, der Stift gibt nur die Richtung vor. Die Richtung rastet (± 5°) parallel bzw.
    /// gespiegelt zu vorhandenen Linien (auch versetzt, davor, dahinter, darüber) und waagerecht/senkrecht ein.
    func lengthLockedCandidate(_ raw: Point2, from a: Point2, lock: (length: Double, ref: SketchCurveRef?)) -> SnapCandidate {
        let v = raw - a
        guard simd_length(v) > 1e-9 else {
            return SnapCandidate(point: click.pointer ?? a, target: nil, guide: nil, label: "")
        }
        let u = simd_normalize(v)
        var best: (angle: Double, direction: Point2, target: SnapTarget)?
        func offer(_ d: Point2, _ target: SnapTarget) {
            // Beide Richtungen der Geraden zählen
            for dir in [d, -d] {
                let angle = acos(min(1, max(-1, simd_dot(u, dir)))) * 180 / .pi
                if angle <= Self.fingerAngleSnapDegrees, angle < (best?.angle ?? .infinity) {
                    best = (angle, dir, target)
                }
            }
        }
        if snapEnabled {
            offer([1, 0], .horizontal)
            offer([0, 1], .vertical)
            for curve in inference.curves where !curve.construction {
                guard case .line(let p, let q) = curve.shape, simd_distance(p, q) > 1e-9 else { continue }
                let d = simd_normalize(q - p)
                offer(d, .parallel(curve.ref))
                if abs(d.x) > 1e-9, abs(d.y) > 1e-9 { offer([d.x, -d.y], .mirroredAngle(curve.ref)) }
            }
        }
        let direction = best?.direction ?? u
        let end = a + direction * lock.length
        guard let best else {
            return SnapCandidate(point: end, target: lock.ref.map { .equalLength($0) }, guide: nil, label: "=")
        }
        var result = SnapCandidate(point: end, target: best.target, guide: (a, end), label: "")
        result.alsoEqual = lock.ref
        return result
    }

    /// Nächster Punkt auf den Linienzügen innerhalb reach (für „Entfernte Kanten“).
    private static func nearestOnPolylines(_ p: Point2, _ lines: [[Point2]], reach: Double) -> Point2? {
        var best: (distance: Double, point: Point2)?
        for line in lines where line.count >= 2 {
            for i in 1..<line.count {
                let a = line[i - 1], b = line[i]
                let ab = b - a
                let l2 = simd_length_squared(ab)
                let t = l2 > 1e-18 ? min(max(simd_dot(p - a, ab) / l2, 0), 1) : 0
                let q = a + ab * t
                let d = simd_distance(q, p)
                if d <= reach, d < (best?.distance ?? .infinity) { best = (d, q) }
            }
        }
        return best?.point
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
        // Spurpunkte: Start des Linienzugs (immer) und die ausdrücklich gemerkten
        var traces: [Point2] = []
        var sources: [Point2] = Array(click.pinned.reversed())
        if let first = click.chainFirst { sources.insert(first, at: 0) }
        for p in sources where !traces.contains(where: { simd_distance($0, p) < 1e-9 }) { traces.append(p) }
        tracking.traces = traces
        var points = click.tracked.map { $0.point } + click.points.map(\.point) + click.pinned
        if let first = click.chainFirst { points.append(first) }
        points += inference.alignmentPoints(near: raw, reach: metrics.alignReach,
                                            axisTolerance: metrics.refine, kinds: snapKinds)
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

    /// Der angezeigte Innenwinkel beginnt am gemeinsamen Eckpunkt in Richtung des vorigen Strichs.
    private func lineAngle(to direction: Point2) -> Double {
        guard simd_length(direction) > 1e-9 else { return 0 }
        let absolute = atan2(direction.y, direction.x)
        guard let previous = previousSegment()?.direction else { return positiveAngle(absolute) }
        let back = atan2(-previous.y, -previous.x)
        return abs(remainder(absolute - back, 2 * .pi))
    }

    /// Ein getippter Innenwinkel hat zwei Seiten; die Stiftlage wählt die nähere.
    private func lineDirection(for angle: Double, toward pointer: Point2) -> Double {
        guard let previous = previousSegment()?.direction else { return angle }
        let back = atan2(-previous.y, -previous.x)
        let plus = back + angle, minus = back - angle
        let current = atan2(pointer.y, pointer.x)
        return abs(remainder(plus - current, 2 * .pi)) <= abs(remainder(minus - current, 2 * .pi))
            ? plus : minus
    }

    /// Ein genau paralleler, schräger Bezug bleibt erkennbar, auch wenn der 15°-Fang ihn zuerst als Winkel fand.
    private func exactParallelReference(from a: Point2, to b: Point2) -> SketchCurveRef? {
        let delta = b - a, length = simd_length(delta)
        guard length > 1e-9 else { return nil }
        let direction = delta / length
        var best: (distance: Double, ref: SketchCurveRef)?
        for curve in inference.curves {
            guard case .line(let start, let end) = curve.shape else { continue }
            let other = end - start, otherLength = simd_length(other)
            guard otherLength > 1e-9, abs(other.x) > 1e-6, abs(other.y) > 1e-6 else { continue }
            let unit = other / otherLength
            guard abs(direction.x * unit.y - direction.y * unit.x) < 1e-7 else { continue }
            let distance = simd_distance((a + b) / 2, (start + end) / 2)
            if distance < (best?.distance ?? .infinity) { best = (distance, curve.ref) }
        }
        return best?.ref
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
        let placed = click.points.map(\.point)
        click.pinned.removeAll { q in !inference.holds(q) && !placed.contains { simd_distance($0, q) < 1e-9 } }
        if let kind = inference.trackKind(snapped.target, at: snapped.point) { rememberTracked(kind, snapped.point) }
        // Fang aus: nichts zeigen; „Leitpunkte“ (Zeigen) aus: keine Knoten in Stiftnähe, nur die gemerkten
        guard snapEnabled else {
            clickTrackedPoints = []
            return
        }
        var shown = showsGuidePoints
            ? inference.trackedNodes(near: raw, radius: metrics.trackRadius, kinds: snapKinds,
                                     extra: click.points.map(\.point))
            : []
        for item in click.tracked where !shown.contains(where: { simd_distance($0.point, item.point) < 1e-9 }) {
            shown.append(item)
        }
        clickTrackedPoints = shown
    }

    /// Höchstens so viele ausdrücklich gemerkte Spurpunkte
    private static let pinnedLimit = 6

    /// Spurpunkt unter dem Stift merken bzw. wieder entmerken (Stift 0,5 s schweben lassen, Stift drücken,
    /// Finger-Doppeltipp; Sketch.captureHovered). Ein einziger gemerkter Punkt liefert sofort Spuren.
    /// nil = kein Punktfang (Ende, Mitte, Zentrum, Schnitt, Körperecke) in der Nähe.
    func togglePinnedPoint(at raw: Point2, tolerance: Double) -> (point: Point2, added: Bool)? {
        guard snapEnabled else { return nil }
        let metrics = snapMetrics(tolerance)
        let kinds = snapKinds.union([SnapKind.endpoint, .midpoint, .center, .intersection, .modelPoint])
        let extra = click.points.map(\.point) + marks
        let found = withHelperSnap(inference.refine(raw, prev: nil, lineTool: false, metrics: metrics,
                                                   midOnly: false, kinds: kinds, extra: extra,
                                                   woken: wokenCenter, fineStep: 0, gridOn: false),
                                   raw: raw, tolerance: metrics.pointPick, kinds: kinds)
        guard let kind = inference.trackKind(found.target, at: found.point) else { return nil }
        let p = found.point
        let added: Bool
        if let index = click.pinned.firstIndex(where: { simd_distance($0, p) < 1e-9 }) {
            click.pinned.remove(at: index)
            notice = "Punkt nicht mehr gemerkt."
            added = false
        } else {
            click.pinned.append(p)
            if click.pinned.count > Self.pinnedLimit {
                click.pinned.removeFirst(click.pinned.count - Self.pinnedLimit)
            }
            rememberTracked(kind, p)
            notice = snapKinds.contains(.alignment)
                ? "Punkt gemerkt – Spuren aktiv (gestrichelt senkrecht zu den Linien daran, waagerecht und senkrecht)."
                : "Punkt gemerkt – Spuren erscheinen erst mit „Skizzenleitlinien“ im Fang-Menü."
            added = true
        }
        return (p, added)
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
            let angle = lockedValue("Winkel").map { lineDirection(for: $0, toward: v) }
                ?? SketchInference.snapAxis(atan2(v.y, v.x), limit: axisLimit)
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
        // Achsfang (2,5°) gehört zu „Waagerecht/Senkrecht“; mit Fang aus bzw. ohne diese Fangart frei
        let axisLimit = snapEnabled && snapKinds.contains(.alignment) ? metrics.axisSnap : 0
        if hasLockedBox {
            let p = clickEffective(candidate.point, axisLimit: axisLimit)
            // Nur die Länge getippt: ein eingerasteter Winkel bleibt samt Leitlinie (die Richtung ändert sich nicht)
            var alongRay = false
            switch candidate.target {
            case .some(.horizontal), .some(.vertical), .some(.angle), .some(.parallel), .some(.perpendicular), .some(.mirroredAngle):
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
            result.point = clickEffective(candidate.point, axisLimit: axisLimit)
            return result
        }
        if case .throughCenter? = candidate.target { return candidate }
        // Leitlinien (Winkelschritt, Ausrichtung, //, ⊥, Verlängerung) liegen schon genau: kein Achsfang darüber
        if candidate.target?.isGuide == true { return candidate }
        if !candidate.hasArgument {
            let p = clickEffective(candidate.point, axisLimit: axisLimit)
            if simd_distance(p, candidate.point) < 1e-9 { return candidate }
            // Achsfang: H/V statt der Inferenz
            let axis: SnapTarget = abs(p.y - a.y) < 1e-9 ? .horizontal : .vertical
            return SnapCandidate(point: p, target: axis, guide: nil, label: "")
        }
        // Schnitt einer Leitlinie mit der Kurve: liegt schon genau
        if candidate.guide != nil { return candidate }
        return inference.onCurveAxis(start: a, candidate: candidate, limit: axisLimit) ?? candidate
    }

    /// Fang des Stifts für die Klickfolge (mit PencilCAD-Kreis-Erkennung beim Mittelpunkt-Kreis).
    private func clickCandidate(_ raw: Point2, tolerance: Double) -> SnapCandidate {
        let metrics = snapMetrics(tolerance)
        let lineTool = clickKind == .line
        click.forwardHit = nil
        if lineTool, let anchor = click.points.last?.point,
           click.latchedLength != nil || click.latchedDirection != nil {
            let result = latchedCandidate(raw, from: anchor, metrics: metrics)
            click.pointer = result.point
            click.raw = raw
            return result
        }
        if lineTool, let lock = fingerLengthLock, let anchor = click.points.last?.point {
            let result = lengthLockedCandidate(raw, from: anchor, lock: lock)
            click.pointer = result.point
            click.raw = raw
            return result
        }
        let tracking = clickTracking(raw, metrics: metrics, fresh: false)
        var snapped = solidCraftSnap(raw, tolerance: tolerance, prev: click.points.last?.point, lineTool: lineTool,
                                    tracking: tracking)
        if clickKind == .arcCenter, click.points.count == 2, !hasLockedBox {
            snapped = centerArcCandidate(snapped, raw: raw, tolerance: metrics.onCurve)
        }
        updateTracking(snapped, raw: raw, metrics: metrics)
        // Mittelpunkt-Bogen: den Bogenwinkel mit dem Stiftpunkt mitzählen, bevor clickEffective den Punkt auf den
        // Kreis beim bisherigen Winkel legt – sonst zählte trackSweep den schon gelegten Punkt, der Winkel blieb 0
        // und nach Mitte und Start erschien nur die Radiuslinie, nie ein Bogen (Kai)
        trackSweep(snapped.point)
        var result = clickPlaced(snapped, metrics: metrics)
        if clickKind == .line, let start = click.points.last?.point, snapEnabled,
           snapKinds.contains(.parallel), !snapSuspended, !arcModifier {
            let angleOnly: Bool
            switch result.target {
            case nil, .some(.grid), .some(.angle): angleOnly = true
            default: angleOnly = false
            }
            if angleOnly, let reference = exactParallelReference(from: start, to: result.point) {
                result = SnapCandidate(point: result.point, target: .parallel(reference),
                                       guide: (start, result.point), label: "//")
            }
        }
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
           !result.hasArgument, snapEnabled, !snapSuspended, !arcModifier,
           let found = inferCircle(center: click.points[0].point, raw: raw, tolerance: tolerance) {
            click.circleInference = found
            let label = found.label.hasPrefix("Gleich") ? "=" : found.label.hasPrefix("Durch") ? "Pt" : "T"
            result = SnapCandidate(point: found.point, target: nil, guide: nil, label: label)
        }
        // Längenfang ergänzt freie und achsparallele Richtungen. Kurven-, Tangenten- und Bezugslinienfang gewinnt.
        let lengthMayReplace: Bool
        switch result.target {
        case nil, .some(.grid), .some(.horizontal), .some(.vertical), .some(.angle), .some(.aligned):
            lengthMayReplace = true
        default:
            lengthMayReplace = false
        }
        if clickKind == .line, let anchor = click.points.last?.point,
           snapEnabled, snapKinds.contains(.equalLength), !snapSuspended, !arcModifier,
           lockedValue("Länge") == nil, lengthMayReplace,
           let match = inference.equalLength(from: anchor, toward: result.point, raw: raw,
                                             tolerance: metrics.refine) {
            result = match
        }
        // Build 43 (Kai, Parallelogramm): Parallel bzw. rechtwinklig UND gleich lang – bisher schloss der Parallelfang
        // den Längenfang aus, die Gegenseite wurde nie gelb. Die Richtung bleibt, die Länge rastet ein.
        if clickKind == .line, let anchor = click.points.last?.point,
           snapEnabled, snapKinds.contains(.equalLength), !snapSuspended, !arcModifier,
           lockedValue("Länge") == nil, !hasLockedBox {
            switch result.target {
            case .some(.parallel), .some(.perpendicular), .some(.mirroredAngle):
                if let match = inference.equalLength(from: anchor, toward: result.point, raw: raw,
                                                     tolerance: metrics.refine),
                   case .equalLength(let ref)? = match.target, inference.curve(ref)?.construction == false {
                    result.point = match.point
                    result.alsoEqual = ref
                    if result.guide != nil { result.guide = (anchor, match.point) }
                }
            default:
                break
            }
        }
        if clickKind == .line, let anchor = click.points.last?.point,
           lockedValue("Länge") == nil, !arcModifier, result.alsoEqual == nil {
            switch result.target {
            case nil, .some(.grid):
                // Build 41: gerasterten Punkt (XY-Raster) als Richtung nehmen, nicht den rohen Stiftpunkt –
                // außer er fällt auf den Startpunkt (sonst Länge 0 statt mindestens eines Schritts)
                let direction = simd_distance(result.point, anchor) > 1e-9 ? result.point : raw
                result.point = steppedLineEnd(direction, from: anchor, roundAngle: true)
            case .some(.horizontal), .some(.vertical), .some(.angle),
                 .some(.parallel), .some(.perpendicular), .some(.mirroredAngle):
                result.point = steppedLineEnd(result.point, from: anchor)
            default:
                break
            }
        }
        if clickKind == .line, let anchor = click.points.last?.point, snapEnabled, !snapSuspended,
           lockedValue("Länge") == nil, !arcModifier, !hasLockedBox {
            applyForwardHit(&result, from: anchor, raw: raw, metrics: metrics)
        }
        click.pointer = result.point
        click.raw = raw
        return result
    }

    // MARK: Build 66 – Fingertipp sperrt Länge/Richtung, Verlängerung bis zur nächsten Kurve

    /// Schräge Linie a→Ende: Verlängerung bis zur ersten getroffenen Kurve merken (gestrichelt gezeigt). Liegt das
    /// Ende kurz davor, rastet es in derselben Richtung genau dort ein (die Richtung bleibt, nur die Länge wächst).
    func applyForwardHit(_ result: inout SnapCandidate, from a: Point2, raw: Point2, metrics: SnapMetrics) {
        switch result.target {
        case nil, .some(.grid), .some(.angle), .some(.parallel), .some(.perpendicular), .some(.mirroredAngle),
             .some(.equalLength):
            break
        default:
            return
        }
        let end = result.point
        let v = end - a
        let length = simd_length(v)
        guard length > 1e-9 else { return }
        let u = v / length
        // Nur schräge Linien (waagerecht/senkrecht haben eigene Spuren)
        let skew = sin(1.0 * .pi / 180)
        guard abs(u.x) > skew, abs(u.y) > skew else { return }
        let reach = max(length * 50, 1000)
        let ray = TrimPrimitive.segment(end, end + u * reach)
        var best: (distance: Double, point: Point2, ref: SketchCurveRef)?
        for curve in inference.curves {
            for primitive in curve.shape.primitives {
                for hit in SketchTrim.intersections(ray, primitive) {
                    let along = simd_dot(hit - end, u)
                    guard along > 1e-6, simd_distance(hit, a) > 1e-6 else { continue }
                    if along < (best?.distance ?? .infinity) { best = (along, hit, curve.ref) }
                }
            }
        }
        guard let best else { return }
        // Abstand vom Stift (nicht vom auf mm gerasterten Ende) bis zum Treffer, längs der Linie
        let penGap = simd_dot(best.point - raw, u)
        if penGap <= metrics.pointPick, simd_dot(raw - a, u) > 0, result.alsoEqual == nil {
            if case .equalLength? = result.target { return }
            result.point = best.point
            result.target = .onCurve(best.ref)
            result.guide = (a, best.point)
            result.label = "Ext"
        } else {
            click.forwardHit = (end, best.point)
        }
    }

    /// Fester Fingertipp-Zustand: Länge und/oder Richtung gesperrt, der Stift gibt den Rest vor.
    private func latchedCandidate(_ raw: Point2, from a: Point2, metrics: SnapMetrics) -> SnapCandidate {
        let length = click.latchedLength
        guard let direction = click.latchedDirection else {
            return lengthLockedCandidate(raw, from: a, lock: length!)
        }
        let u = direction.direction
        var result: SnapCandidate
        if let length {
            let end = a + u * length.length
            result = SnapCandidate(point: end, target: direction.target, guide: (a, end), label: "")
            result.alsoEqual = length.ref
            return result
        }
        let along = max(simd_dot(raw - a, u), 1e-6)
        var end = steppedLineEnd(a + u * along, from: a)
        if simd_dot(end - a, u) <= 1e-9 { end = a + u * along }
        result = SnapCandidate(point: end, target: direction.target, guide: (a, end), label: "")
        // Gleiche Länge in derselben Richtung rastet zusätzlich ein (gelb)
        if snapEnabled, snapKinds.contains(.equalLength),
           let match = inference.equalLength(from: a, toward: end, raw: raw, tolerance: metrics.refine),
           case .equalLength(let ref)? = match.target {
            let w = match.point - a
            if abs(w.x * u.y - w.y * u.x) < 1e-6, simd_dot(w, u) > 0 {
                result.point = match.point
                result.alsoEqual = ref
                result.guide = (a, match.point)
            }
        }
        if result.alsoEqual == nil { applyForwardHit(&result, from: a, raw: raw, metrics: metrics) }
        return result
    }

    /// Richtung der laufenden Linie, wenn sie gerade grün ist (parallel bzw. gespiegelt zu einer vorhandenen Linie).
    private func currentDirectionLock() -> (direction: Point2, target: SnapTarget)? {
        guard clickKind == .line, let a = click.points.last?.point, let hover = click.hover else { return nil }
        let v = hover.point - a
        guard simd_length(v) > 1e-9 else { return nil }
        let u = simd_normalize(v)
        switch hover.target {
        case .parallel?, .perpendicular?, .mirroredAngle?:
            return (u, hover.target!)
        default:
            break
        }
        for curve in inference.curves where !curve.construction {
            guard case .line(let p, let q) = curve.shape, simd_distance(p, q) > 1e-9 else { continue }
            let d = simd_normalize(q - p)
            if abs(u.x * d.y - u.y * d.x) < Self.lineMatchAngleTolerance { return (u, .parallel(curve.ref)) }
            if abs(d.x) > 1e-9, abs(d.y) > 1e-9, abs(u.x * d.y + u.y * d.x) < Self.lineMatchAngleTolerance {
                return (u, .mirroredAngle(curve.ref))
            }
        }
        return nil
    }

    /// Was ein Fingertipp jetzt sperren würde (beim Auflegen des Fingers gemerkt, bevor der Finger den Fang ändert).
    struct FingerLockSnapshot {
        var length: (length: Double, ref: SketchCurveRef?)?
        var direction: (direction: Point2, target: SnapTarget)?
    }

    func fingerLockSnapshot() -> FingerLockSnapshot? {
        guard options.isSolidCraft, clickKind == .line, !click.points.isEmpty else { return nil }
        let snapshot = FingerLockSnapshot(length: currentEqualLengthLock(), direction: currentDirectionLock())
        return snapshot.length == nil && snapshot.direction == nil ? nil : snapshot
    }

    /// Fingertipp beim Zeichnen einer Linie: gelb sperrt die Länge, grün die Richtung (beides möglich).
    /// false = nichts Neues gesperrt.
    @discardableResult
    func latchFingerLocks(_ snapshot: FingerLockSnapshot? = nil) -> Bool {
        guard let snapshot = snapshot ?? fingerLockSnapshot(), clickKind == .line, !click.points.isEmpty else {
            return false
        }
        var latched = false
        if click.latchedLength == nil, let lock = snapshot.length {
            click.latchedLength = lock
            latched = true
        }
        if click.latchedDirection == nil, let lock = snapshot.direction {
            click.latchedDirection = lock
            latched = true
        }
        guard latched else { return false }
        let parts = [click.latchedLength != nil ? "Länge" : nil, click.latchedDirection != nil ? "Winkel" : nil]
            .compactMap { $0 }.joined(separator: " und ")
        notice = "\(parts) gesperrt – Doppeltipp mit dem Finger hebt die Sperre auf."
        if let raw = click.raw, click.press == nil {
            click.hover = clickCandidate(raw, tolerance: click.mmPerPoint * 20)
        }
        changed()
        return true
    }

    /// Doppeltipp mit dem Finger: Sperren aufheben. false = es war nichts gesperrt.
    @discardableResult
    func clearFingerLocks() -> Bool {
        guard click.latchedLength != nil || click.latchedDirection != nil else { return false }
        click.latchedLength = nil
        click.latchedDirection = nil
        notice = "Sperre aufgehoben."
        if let raw = click.raw, click.press == nil {
            click.hover = clickCandidate(raw, tolerance: click.mmPerPoint * 20)
        }
        changed()
        return true
    }

    var hasFingerLocks: Bool { click.latchedLength != nil || click.latchedDirection != nil }

    /// Der Endpunkt eines Mittelpunktbogens muss auf Radiuskreis UND Fangkurve liegen.
    /// Ein nur auf die Fangkurve projizierter Punkt trägt sonst eine falsche Abhängigkeit.
    private func centerArcCandidate(_ candidate: SnapCandidate, raw: Point2, tolerance: Double) -> SnapCandidate {
        let center = click.points[0].point
        let radius = simd_distance(center, click.points[1].point)
        guard radius > 1e-9, let target = candidate.target else { return candidate }
        if case .onCurve(let ref) = target, let curve = inference.curve(ref) {
            let hits = curve.shape.primitives.flatMap {
                SketchTrim.intersections(.circle(center: center, radius: radius), $0)
            }
            if let hit = hits.min(by: { simd_distance($0, raw) < simd_distance($1, raw) }),
               simd_distance(hit, raw) <= tolerance {
                return SnapCandidate(point: hit, target: target, guide: candidate.guide, label: candidate.label)
            }
            return .free(raw)
        }
        // Punkt-, Schnitt- und Mittelfang außerhalb des Radiuskreises ist ebenfalls kein Bogen-Endpunkt.
        if candidate.hasArgument && abs(simd_distance(candidate.point, center) - radius) > 1e-6 {
            return .free(raw)
        }
        return candidate
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
        let elapsed = now - tap.time
        return elapsed >= 0 && elapsed <= Self.doubleTapInterval
            && simd_distance(tap.raw, raw) <= metrics.tapSlop * 3
    }

    func clickBegan(at raw: Point2, tolerance: Double) {
        // Build 53: eine festgehaltene Länge gilt nur für den Strich, in dem der Finger aufgelegt wurde
        fingerLengthLock = nil
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
            clickPlace(lineContinuation(raw: raw, fresh: fresh, metrics: metrics) ?? candidate)
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
            if !dragged, !(press.secondTap && quickTap) { pickTangentCurve(at: raw, metrics: metrics, count: count) }
            click.lastTap = dragged || press.secondTap ? nil : SketchClickState.Tap(time: now, raw: raw, startedShape: false)
            changed()
            return
        }
        if press.secondTap, quickTap && !dragged {
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
        // Den zuletzt sichtbaren geometrischen Punktfang auch bei einem kurzen Tipp
        // beibehalten. Vorher wurde nur beim Ziehen die Vorschau übernommen; beim
        // Abheben eines getippten Endpunkts konnte ein erneuter Snap auf eine andere
        // nahe Kurve wechseln. Freie Vorschauen bleiben dagegen nur bei einem Ziehen
        // mit geringer Abweichung gültig.
        let shown = click.hover
        let releaseNearPreview = shown.map {
            ($0.target?.isPointSnap ?? false) && simd_distance($0.point, raw) <= metrics.pointPick
        } ?? false
        let releaseNearLastSample = click.raw.map {
            simd_distance($0, raw) <= metrics.tapSlop
        } ?? false
        if let shown, releaseNearPreview || (dragged && releaseNearLastSample) {
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
            clickPlace(lineContinuation(raw: press.raw, fresh: press.fresh, metrics: metrics) ?? press.fresh)
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
        // Build 43: Ein Tipp, der einen Einzelstrich abschließt, ist kein erstes Tippen eines Doppeltipps – sonst ginge
        // schnelles erneutes Antippen des Linienendes (Weiterzeichnen) verloren
        let endedStroke = kind == .line && lineSingleStroke && !press.startedEmpty && click.points.isEmpty
        click.lastTap = dragged || endedStroke ? nil
            : SketchClickState.Tap(time: now, raw: raw, startedShape: press.startedEmpty && !click.points.isEmpty)
        click.hover = nil
        // Nach dem Abheben nur noch die gemerkten Fangpunkte zeigen (die in Stiftnähe folgen beim Schweben)
        clickTrackedPoints = click.tracked
        changed()
    }

    /// Build 43: Ansetzen am Ende der zuletzt gezeichneten Linie (bzw. knapp daneben, ohne anderen Punktfang)
    /// setzt den neuen Strich genau dort an – mit dem Linienende als Fang, damit Ecke und Winkel zum vorigen
    /// Strich stimmen. nil = nicht in der Nähe bzw. Linienzug-Modus.
    private func lineContinuation(raw: Point2, fresh: SnapCandidate, metrics: SnapMetrics) -> SnapCandidate? {
        guard clickKind == .line, lineSingleStroke, let ref = click.lastLineEnd,
              entities.indices.contains(ref.entity), ref.index <= 1,
              case .line(let a, let b) = entities[ref.entity] else { return nil }
        let end = ref.index == 1 ? b : a
        guard simd_distance(end, raw) <= metrics.chainReach else { return nil }
        // Ein anderer Punktfang (z. B. ein näherer Endpunkt) gewinnt
        if fresh.target?.isPointSnap == true, simd_distance(fresh.point, end) > 1e-9 { return nil }
        return SnapCandidate(point: end, target: .point(ref), guide: nil, label: "")
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
        let point = SketchClickPoint(point: candidate.point, target: candidate.target, alsoEqual: candidate.alsoEqual)
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
            if lineSingleStroke, case .point(let ref?)? = point.target, ref == click.lastLineEnd,
               let first = click.contourFirst {
                // Weitergezeichnet: die Kontur beginnt weiter beim ersten Strich
                click.chainFirst = first
            } else {
                click.chainFirst = point.point
            }
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
        click.latchedLength = nil
        click.latchedDirection = nil
        click.forwardHit = nil
        if !options.locked.isEmpty { options.locked = [:] }
        if let first = click.chainFirst, simd_distance(first, point.point) < 1e-9 {
            // Zurück am Anfang: geschlossen
            click.points = []
            click.chainFirst = nil
            tool = .select
            return
        }
        if lineSingleStroke {
            // Build 43 (Kai): Der Strich endet hier. Länge und Winkel stehen als änderbare Maße an der Linie
            // (editableIndex); weiter geht es erst, wenn das Linienende wieder angetippt bzw. dort angesetzt wird.
            click.contourFirst = click.chainFirst
            click.points = []
            click.chainFirst = nil
            click.lastLineEnd = SketchPointRef(entity: index, index: 1)
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
               let arc = Self.tangentArcShape(start: points[0], direction: start.direction, end: h,
                                              opposite: tangentArcOpposite) {
                shapes.append(arc)
            } else if let h {
                lines.append([points[0], h])
            }
        case (.polygon, 1) where generatedShape != nil:
            if let h {
                shapes += generatedShapePreview(center: points[0], through: h)
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

    /// Temporäre Darstellung des Längenfangs; nach Abbruch oder Verlassen des Fangbereichs leer.
    var equalLengthPreview: (reference: [Point2], connector: [Point2])? {
        guard clickKind == .line, let a = click.points.last?.point, let b = click.hover?.point,
              case .equalLength(let ref)? = currentCandidate?.target,
              let curve = inference.curve(ref), case .line(let u, let v) = curve.shape else { return nil }
        return ([u, v], [(u + v) / 2, (a + b) / 2])
    }

    /// Alle Bezugsgeraden der aktuellen Gleichlängen-Gruppe, auch über mehrere Abhängigkeiten hinweg.
    var equalLengthReferenceLines: [[Point2]] {
        guard clickKind == .line, case .equalLength(let reference)? = currentCandidate?.target else { return [] }
        var neighbors: [SketchCurveRef: [SketchCurveRef]] = [:]
        for constraint in constraints where !constraint.isSuspended {
            guard case .equalLength(let a, let b) = constraint.variant else { continue }
            neighbors[a, default: []].append(b)
            neighbors[b, default: []].append(a)
        }
        var connected: Set<SketchCurveRef> = [reference]
        var pending = [reference]
        while let current = pending.popLast() {
            for neighbor in neighbors[current] ?? [] {
                if connected.insert(neighbor).inserted { pending.append(neighbor) }
            }
        }
        return connected.sorted { ($0.entity, $0.index) < ($1.entity, $1.index) }.compactMap { ref in
            guard let curve = inference.curve(ref), case .line(let a, let b) = curve.shape else { return nil }
            return [a, b]
        }
    }

    /// Bezugslinie des aktiven Parallel-Fangs im Standard-Eingabestil.
    var parallelPreview: [Point2]? {
        guard clickKind == .line, !click.points.isEmpty, click.hover != nil,
              case .parallel(let ref)? = currentCandidate?.target,
              let curve = inference.curve(ref), case .line(let a, let b) = curve.shape else { return nil }
        return [a, b]
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
        // Seitenzahl erst klemmen, dann wandeln (1e20 bzw. NaN stürzte ab)
        let locked = lockedValue("Seiten").map { clampedCount($0, min: 3, max: 200) }
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
                value = lineAngle(to: v) * 180 / .pi
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
        case .line where lineSingleStroke:
            return n == 0 ? "Linie: von A nach B ziehen oder A und B antippen · Maße an der Linie antippen zum Ändern · Linienende antippen bzw. dort ansetzen zeichnet weiter"
                : "Linie: Ende antippen (Länge/Winkel eintippbar) – der Strich endet dort"
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
        case .polygon where generatedShape != nil:
            return n == 0 ? "Form: Mitte antippen, dann Größe und Drehung" : "Form: Größe und Drehung antippen"
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

// MARK: - Build 43: Farbhinweise beim Zeichnen einer Linie (Kai)

// „Wenn ich denselben Winkel habe wie die erste Linie, soll mein Strich grün werden. Wenn ich die Länge von irgendeiner
// dieser bis jetzt gezeichneten Konstruktionen habe, wird die Linie gelb, und auch die dazugehörige Linie.“
// Geprüft wird die gezeigte Vorschau selbst (nach allen Fängen): genau gleiche Richtung wie eine vorhandene Linie
// (parallel, gleicher Winkel zur Waagerechten) = grün, genau gleiche Länge = gelb – jeweils mit allen passenden
// Linien. Beides zugleich: grün-gelb gestreift. Die Fänge Parallel und Gleiche Länge machen die Werte genau.
extension SketchController {
    struct LineMatchHints {
        /// Vorhandene Linien mit derselben Richtung (grün)
        var parallel: [[Point2]] = []
        /// Vorhandene Linien mit derselben Länge (gelb)
        var equal: [[Point2]] = []

        var isEmpty: Bool { parallel.isEmpty && equal.isEmpty }
    }

    /// Richtungsgleichheit: Kreuzprodukt der Einheitsvektoren (≈ Winkel im Bogenmaß; 1e-7 ≈ 0,000006°)
    static let lineMatchAngleTolerance = 1e-7

    /// Hinweise für das Gummiband der Linie; leer ohne laufenden Strich bzw. bei anderen Werkzeugen.
    var lineMatchHints: LineMatchHints {
        guard clickKind == .line, let a = click.points.last?.point, let b = click.hover?.point else {
            return LineMatchHints()
        }
        return Self.lineMatches(from: a, to: b, curves: inference.curves)
    }

    /// Passende Linien zu a→b unter den (nicht konstruktiven) geraden Kurven der Skizze.
    static func lineMatches(from a: Point2, to b: Point2, curves: [SketchInference.Curve]) -> LineMatchHints {
        let v = b - a
        let length = simd_length(v)
        guard length > 1e-9, length.isFinite else { return LineMatchHints() }
        let u = v / length
        let lengthTolerance = max(1e-6, length * 1e-9)
        var hints = LineMatchHints()
        var seen = Set<SketchCurveRef>()
        for curve in curves where !curve.construction {
            guard case .line(let p, let q) = curve.shape, seen.insert(curve.ref).inserted else { continue }
            let w = q - p
            let l = simd_length(w)
            guard l > 1e-9, l.isFinite else { continue }
            let d = w / l
            // Build 44 (Kai): auch gleicher Winkel gespiegelt (z. B. 60° und 120°) wird grün
            if abs(u.x * d.y - u.y * d.x) < lineMatchAngleTolerance
                || (abs(d.x) > 1e-9 && abs(d.y) > 1e-9 && abs(u.x * d.y + u.y * d.x) < lineMatchAngleTolerance) {
                hints.parallel.append([p, q])
            }
            if abs(l - length) <= lengthTolerance { hints.equal.append([p, q]) }
        }
        return hints
    }
}
