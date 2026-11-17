import Foundation
import simd

// Build 80 (Kai): Projizieren › Kontur mit dem Stift nachfahren. Der Umriss der Körper (SketchSilhouette.swift)
// liegt dünn grau unter der Skizze; was der Stift entlangfährt, wird blau und bleibt blau (auch über mehrere
// Striche). Ist eine Kontur ganz nachgefahren, wird sie grün = geschlossen und als Skizzenkontur übernommen.
// Ein blaues Teilstück lässt sich über „Teilstück übernehmen“ als offene Linie übernehmen.

extension SketchController {
    /// Gerechneter Umriss für diese Ebene (leer = noch keiner). key verhindert altes Nachfahren auf neuer Ebene.
    struct TraceState {
        var key: String = ""
        var loops: [[Point2]] = []
        /// Je Kontur und Teilstück k (Punkt k → k + 1): nachgefahren?
        var covered: [[Bool]] = []
        /// Ganz nachgefahren und übernommen (grün)
        var done: Set<Int> = []
        /// Laufender Strich: zuletzt getroffene Kontur und Teilstück, zurückgelegte Strecke
        var last: (loop: Int, segment: Int)?
        var strokeStart: Point2?
        var strokeLength: Double = 0
        var previous: Point2?
    }

    /// Umriss setzen (vom Viewport berechnet); gleicher key = vorhandenes Nachfahren bleibt.
    func setTraceLoops(_ loops: [[Point2]], key: String) {
        guard trace.key != key else { return }
        var state = TraceState()
        state.key = key
        state.loops = loops.filter { $0.count >= 3 }
        state.covered = state.loops.map { [Bool](repeating: false, count: max(0, $0.count - 1)) }
        trace = state
        changed()
    }

    var hasTraceLoops: Bool { !trace.loops.isEmpty }

    /// Der Strich war ein Nachfahren (kein Antippen): dann projiziert der Viewport keine einzelne Kante.
    var traceWasDrag: Bool { trace.strokeLength > 0 }

    func traceBegan(at p: Point2, tolerance: Double) {
        trace.last = nil
        trace.strokeStart = p
        trace.strokeLength = 0
        trace.previous = p
        traceMark(p, tolerance: tolerance)
    }

    func traceMoved(to p: Point2, tolerance: Double) {
        if let previous = trace.previous {
            let distance = simd_distance(previous, p)
            trace.strokeLength += distance
            // Schnelle Striche: Zwischenpunkte, damit kein Teilstück übersprungen wird
            let steps = min(40, Int(distance / max(tolerance * 0.25, 1e-6)))
            if steps > 1 {
                for k in 1..<steps { traceMark(previous + (p - previous) * (Double(k) / Double(steps)), tolerance: tolerance) }
            }
        }
        trace.previous = p
        traceMark(p, tolerance: tolerance)
        changed(publish: false)
    }

    /// Strich zu Ende: ganz nachgefahrene Konturen grün und als Skizzenkontur übernehmen.
    func traceEnded(at p: Point2, tolerance: Double) {
        traceMoved(to: p, tolerance: tolerance)
        trace.last = nil
        trace.previous = nil
        // Kurzer Tipp: kein Nachfahren (der Viewport projiziert dann wie bisher eine Kante)
        if trace.strokeLength < tolerance * 1.5 {
            trace.strokeLength = 0
            return
        }
        var closedNow: [[Point2]] = []
        for (index, flags) in trace.covered.enumerated() where !trace.done.contains(index) && !flags.isEmpty {
            // Fast ganz (≥ 97 % der Länge): als geschlossen werten, Rest auffüllen
            let loop = trace.loops[index]
            var total: Double = 0, covered: Double = 0
            for k in flags.indices {
                let length = simd_distance(loop[k], loop[k + 1])
                total += length
                if flags[k] { covered += length }
            }
            guard total > 0, covered / total >= 0.97 else { continue }
            trace.covered[index] = [Bool](repeating: true, count: flags.count)
            trace.done.insert(index)
            closedNow.append(loop)
        }
        if !closedNow.isEmpty {
            addProjected(closedNow)
            notice = closedNow.count == 1 ? "Kontur geschlossen (grün) und übernommen"
                : "\(closedNow.count) Konturen geschlossen (grün) und übernommen"
        } else if traceHasOpenPart {
            notice = "Blau = nachgefahren · ganz herum fahren schließt die Kontur (grün)"
        }
        changed()
    }

    /// Nachgefahrene, noch nicht übernommene Stücke vorhanden?
    var traceHasOpenPart: Bool {
        trace.covered.enumerated().contains { pair in !trace.done.contains(pair.offset) && pair.element.contains(true) }
    }

    /// Blaue Teilstücke als offene Linien übernehmen.
    func applyTracePartial() {
        var runs: [[Point2]] = []
        for (index, flags) in trace.covered.enumerated() where !trace.done.contains(index) {
            let loop = trace.loops[index]
            let n = flags.count
            guard n > 0, flags.contains(true) else { continue }
            // Anfang eines Laufs: ein nachgefahrenes Stück, dessen Vorgänger nicht nachgefahren ist
            for k in 0..<n where flags[k] && !flags[(k - 1 + n) % n] {
                var run: [Point2] = [loop[k]]
                var m = k
                while flags[m % n], run.count <= n {
                    run.append(loop[(m % n) + 1])
                    m += 1
                }
                if run.count >= 2 { runs.append(run) }
            }
            trace.covered[index] = [Bool](repeating: false, count: n)
        }
        guard !runs.isEmpty else { return }
        addProjected(runs)
        notice = runs.count == 1 ? "Teilstück übernommen" : "\(runs.count) Teilstücke übernommen"
        changed()
    }

    /// Nachfahren zurücksetzen (Umriss bleibt).
    func resetTrace() {
        trace.covered = trace.loops.map { [Bool](repeating: false, count: max(0, $0.count - 1)) }
        trace.done = []
        trace.last = nil
        notice = nil
        changed()
    }

    /// Linien für den Viewport: Umriss grau, nachgefahren blau, geschlossen grün.
    func traceGeometry() -> (outline: [[Point2]], blue: [[Point2]], green: [[Point2]]) {
        guard tool == .project, !trace.loops.isEmpty else { return ([], [], []) }
        var blue: [[Point2]] = [], green: [[Point2]] = []
        for (index, loop) in trace.loops.enumerated() {
            if trace.done.contains(index) {
                green.append(loop)
                continue
            }
            let flags = trace.covered[index]
            var run: [Point2] = []
            for k in flags.indices {
                if flags[k] {
                    if run.isEmpty { run.append(loop[k]) }
                    run.append(loop[k + 1])
                } else if !run.isEmpty {
                    blue.append(run)
                    run = []
                }
            }
            if !run.isEmpty { blue.append(run) }
        }
        return (trace.loops, blue, green)
    }

    /// Teilstücke nahe p als nachgefahren markieren; Lücken zum zuletzt getroffenen Stück derselben Kontur füllen.
    private func traceMark(_ p: Point2, tolerance: Double) {
        var best: (loop: Int, segment: Int, distance: Double)?
        for (index, loop) in trace.loops.enumerated() where !trace.done.contains(index) {
            for k in 0..<(loop.count - 1) {
                let d = Self.distance(p, loop[k], loop[k + 1])
                if d <= tolerance, d < (best?.distance ?? .infinity) { best = (index, k, d) }
            }
        }
        guard let best else { return }
        trace.covered[best.loop][best.segment] = true
        if let last = trace.last, last.loop == best.loop, last.segment != best.segment {
            // Kürzerer Weg rund um die Kontur zwischen den beiden Stücken (höchstens 12 Stücke)
            let n = trace.covered[best.loop].count
            let forward = (best.segment - last.segment + n) % n
            let backward = (last.segment - best.segment + n) % n
            if min(forward, backward) <= 12 {
                if forward <= backward {
                    for step in 0...forward { trace.covered[best.loop][(last.segment + step) % n] = true }
                } else {
                    for step in 0...backward { trace.covered[best.loop][(best.segment + step) % n] = true }
                }
            }
        }
        trace.last = (best.loop, best.segment)
    }

    private static func distance(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let ab: Point2 = b - a
        let length2: Double = simd_dot(ab, ab)
        guard length2 > 1e-18 else { return simd_distance(p, a) }
        let t: Double = min(max(simd_dot(p - a, ab) / length2, 0), 1)
        return simd_distance(p, a + ab * t)
    }
}
