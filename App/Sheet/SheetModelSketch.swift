import Foundation
import simd

// PencilCAD-Skizzen → SolidCraft-Skizzen (SheetKit/API.md „Skizzen übergeben“): freie Ebene aus SketchPlane
// (origin, u, v), Konturen der gewählten Bereiche als Linien, Bögen, Kreise, Ellipsen und Splines in lokalen
// Skizzenkoordinaten (dieselben wie in PencilCAD), dann sketch.finish.

extension ModelStore {
    /// sketch.create mit freier Ebene; name eindeutig je Übergabe.
    static func sheetSketchCreate(_ plane: SketchPlane, name: String) -> SheetStep {
        SheetStep("Skizze", SheetCommand("sketch.create", [
            "plane": ["origin": SheetJSON(plane.origin), "x_dir": SheetJSON(plane.u), "y_dir": SheetJSON(plane.v)],
            "name": .string(name),
        ]))
    }

    static func sheetSketchFinish() -> SheetStep {
        SheetStep("Skizze", SheetCommand("sketch.finish"))
    }

    /// Neuer, eindeutiger Skizzenname im Rezept.
    static func sheetSketchName() -> String { "pc-\(UUID().uuidString.prefix(8))" }

    /// Befehle für eine geschlossene Kontur (lokale Koordinaten).
    static func sheetLoopCommands(_ loop: SketchLoop) -> [SheetCommand] {
        switch loop {
        case .circle(let center, let radius):
            return [SheetCommand("sketch.circle.center", ["center": SheetJSON(center), "radius": .number(radius)])]
        case .ellipse(let center, let radii):
            // Große Achse entlang x bzw. y der Skizze
            let major = radii.x >= radii.y ? center + SIMD2(radii.x, 0) : center + SIMD2(0, radii.y)
            return [SheetCommand("sketch.ellipse", [
                "center": SheetJSON(center), "major": SheetJSON(major), "minor_radius": .number(min(radii.x, radii.y)),
            ])]
        case .periodic:
            // Geschlossener Kontrollpunkt-Spline: glatt durch abgetastete Punkte (höchstens 500)
            var points = loop.polygon
            if points.count > 480 {
                let step = Double(points.count) / 480
                points = (0..<480).map { points[Int(Double($0) * step)] }
            }
            return [SheetCommand("sketch.spline.fit_point", ["points": .array(points.map { SheetJSON($0) }), "periodic": true])]
        case .chain(let segments):
            return sheetChainCommands(segments, closed: true)
        }
    }

    /// Befehle für eine Segmentkette; aufeinanderfolgende Linien werden ein sketch.line-Zug.
    /// closed: reine Linienkette als geschlossener Zug. ids: eigene Kurven-IDs (nur reine Linienketten).
    static func sheetChainCommands(_ segments: [SketchSegment], closed: Bool, ids: [String]? = nil) -> [SheetCommand] {
        let allLines = segments.allSatisfy { if case .line = $0 { return true } else { return false } }
        if allLines, let first = segments.first {
            var points = [first.start] + segments.map(\.end)
            var params: SheetJSON = [:]
            if closed, points.count > 2, simd_distance(points[0], points[points.count - 1]) < 1e-9 {
                points.removeLast()
                params["closed"] = true
            }
            params["points"] = .array(points.map { SheetJSON($0) })
            if let ids { params["ids"] = .array(ids.map { .string($0) }) }
            return [SheetCommand("sketch.line", params)]
        }
        var commands: [SheetCommand] = []
        var run: [SIMD2<Double>] = []
        func flush() {
            if run.count >= 2 { commands.append(SheetCommand("sketch.line", ["points": .array(run.map { SheetJSON($0) })])) }
            run = []
        }
        for segment in segments {
            switch segment {
            case .line(let a, let b):
                if run.isEmpty { run = [a] }
                run.append(b)
            case .arc(let a, let m, let b):
                flush()
                commands.append(SheetCommand("sketch.arc.three_point", [
                    "start": SheetJSON(a), "through": SheetJSON(m), "end": SheetJSON(b),
                ]))
            case .bezier(let poles):
                flush()
                // Kubische Bézierstücke: je vier Pole = geklemmter kubischer B-Spline
                var k = 0
                while k + 3 < poles.count {
                    let piece = Array(poles[k...k + 3])
                    commands.append(SheetCommand("sketch.spline.control_point", ["points": .array(piece.map { SheetJSON($0) })]))
                    k += 3
                }
            case .bspline(let poles):
                flush()
                commands.append(SheetCommand("sketch.spline.control_point", ["points": .array(poles.map { SheetJSON($0) })]))
            }
        }
        flush()
        return commands
    }

    /// Punkt sicher im Bereich (nicht in einem Loch), lokal.
    static func sheetInteriorPoint(_ region: SketchRegion) -> SIMD2<Double>? {
        let inside = { (p: SIMD2<Double>) -> Bool in
            polygonContains(region.polygon, p) && !region.holes.contains { polygonContains($0.polygon, p) }
        }
        guard !region.polygon.isEmpty else { return nil }
        let center = region.polygon.reduce(SIMD2<Double>.zero, +) / Double(region.polygon.count)
        if inside(center) { return center }
        var lo = region.polygon[0], hi = region.polygon[0]
        for p in region.polygon {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        // Raster, am Ende der dem Schwerpunkt nächste innere Punkt
        var best: SIMD2<Double>?
        let n = 24
        for i in 1..<n {
            for j in 1..<n {
                let p = lo + (hi - lo) * SIMD2(Double(i) / Double(n), Double(j) / Double(n))
                guard inside(p) else { continue }
                if best.map({ simd_distance($0, center) > simd_distance(p, center) }) ?? true { best = p }
            }
        }
        return best
    }

    // MARK: Pläne

    /// Grundflansch: neue Blechkörper-Rezept aus Skizzenbereichen.
    func sheetBaseFlangePlan(sketch index: Int, regions: [Int], rule ruleName: String?, flip: Bool) throws -> SheetPlan {
        guard sketches.indices.contains(index) else { throw SheetKernelError("Skizze nicht gefunden.") }
        let sketch = sketches[index]
        let chosen = regions.filter { sketch.regions.indices.contains($0) }
        guard !chosen.isEmpty else { throw SheetKernelError("Geschlossenen Skizzenbereich wählen.") }
        // Ein Grundflansch ist ein Blechkörper: mehrere Bereiche ergäben in SolidCraft mehrere Körper
        guard chosen.count == 1 else {
            throw SheetKernelError("Für einen Grundflansch genau einen Bereich wählen (je Bereich ein Blechkörper).")
        }
        let rule = try sheetRule(ruleName)
        let name = Self.sheetSketchName()
        var steps = [SheetStep(rule.command(active: true).title, rule.command(active: true))]
        steps.append(Self.sheetSketchCreate(sketch.plane, name: name))
        var picks: [SheetJSON] = []
        for regionIndex in chosen {
            let region = sketch.regions[regionIndex]
            for loop in [region.outer] + region.holes {
                for command in Self.sheetLoopCommands(loop) { steps.append(SheetStep("Skizze", command)) }
            }
            guard let point = Self.sheetInteriorPoint(region) else { throw SheetKernelError("Bereich ist zu schmal.") }
            picks.append(["point": SheetJSON(point)])
        }
        steps.append(Self.sheetSketchFinish())
        let kernelBody = "Blech"
        var params: SheetJSON = [
            "type": "base", "sketch": .string(name), "profiles": .array(picks), "rule": .string(rule.name),
            "body_name": .string(kernelBody),
        ]
        if flip { params["flip"] = true }
        steps.append(SheetStep("Grundflansch", SheetCommand("sheet.flange", params)))
        return try sheetCreatePlan(steps, kernelBody: kernelBody, rule: rule.name, sketch: sketch.id, title: "Grundflansch")
    }

    /// Konturflansch aus einer offenen Linienkette (Elemente der Skizze).
    func sheetContourFlangePlan(sketch index: Int, entities: [Int], distance: Double, rule ruleName: String?,
                                flip: Bool, reverse: Bool) throws -> SheetPlan {
        guard sketches.indices.contains(index) else { throw SheetKernelError("Skizze nicht gefunden.") }
        let sketch = sketches[index]
        let chain = try Self.sheetLineChain(sketch, entities: entities, startNear: nil)
        let rule = try sheetRule(ruleName)
        let name = Self.sheetSketchName()
        let ids = (1..<chain.count).map { "c\($0)" }
        var steps = [SheetStep(rule.command(active: true).title, rule.command(active: true))]
        steps.append(Self.sheetSketchCreate(sketch.plane, name: name))
        steps.append(SheetStep("Skizze", SheetCommand("sketch.line", [
            "points": .array(chain.map { SheetJSON($0) }), "ids": .array(ids.map { .string($0) }),
        ])))
        steps.append(Self.sheetSketchFinish())
        let kernelBody = "Blech"
        var params: SheetJSON = [
            "type": "contour", "sketch": .string(name), "curves": .array(ids.map { .string($0) }),
            "distance": .number(distance), "rule": .string(rule.name), "body_name": .string(kernelBody),
        ]
        if flip { params["flip"] = true }
        if reverse { params["reverse"] = true }
        steps.append(SheetStep("Konturflansch", SheetCommand("sheet.flange", params)))
        return try sheetCreatePlan(steps, kernelBody: kernelBody, rule: rule.name, sketch: sketch.id, title: "Konturflansch")
    }

    /// Pfadflansch: Linienkette einer Skizze quer zur Kante, ab dem Ende nahe der Kante.
    func sheetPathFlangePlan(to body: Int, edge: SIMD3<Double>, sketch index: Int, entities: [Int],
                             radius: Double?) throws -> SheetPlan {
        guard sketches.indices.contains(index) else { throw SheetKernelError("Skizze nicht gefunden.") }
        let sketch = sketches[index]
        let chain = try Self.sheetLineChain(sketch, entities: entities, startNear: sketch.plane.local(edge))
        guard chain.count - 1 <= 64 else { throw SheetKernelError("Höchstens 64 Linien im Pfad.") }
        let name = Self.sheetSketchName()
        let ids = (1..<chain.count).map { "p\($0)" }
        var steps = [Self.sheetSketchCreate(sketch.plane, name: name)]
        steps.append(SheetStep("Skizze", SheetCommand("sketch.line", [
            "points": .array(chain.map { SheetJSON($0) }), "ids": .array(ids.map { .string($0) }),
        ])))
        steps.append(Self.sheetSketchFinish())
        var params: SheetJSON = ["edge": SheetJSON(edge), "sketch": .string(name), "curves": .array(ids.map { .string($0) })]
        if let radius { params["radius"] = .number(radius) }
        steps.append(SheetStep("Pfadflansch", SheetCommand("sheet.path_flange", params)))
        return try sheetAppendPlan(steps, to: body)
    }

    /// Neuer Blechkörper aus einem Rezept.
    private func sheetCreatePlan(_ steps: [SheetStep], kernelBody: String, rule: String, sketch: UUID?,
                                 title: String) throws -> SheetPlan {
        let info = SheetBodyInfo(steps: steps, kernelBody: kernelBody, rule: rule)
        var built = try sheetBuild(info, base: nil, name: "Blech")
        built.body.sketchID = sketch
        let data = SheetFeatureData(mode: "create", steps: steps, bodyName: built.body.name, kernelBody: kernelBody,
                                    rule: rule, sketchID: sketch)
        let feature = Self.sheetFeature("Blech: \(title)", data: data, target: nil)
        return SheetPlan(bodies: bodies + [built.body], feature: feature, name: title, warnings: built.warnings)
    }

    /// Regel nach Name (nil = aktive).
    func sheetRule(_ name: String?) throws -> SheetRule {
        guard let name else { return sheetDocument.activeRule }
        guard let rule = sheetDocument.rule(named: name) else { throw SheetKernelError("Blechregel „\(name)“ fehlt.") }
        return rule
    }

    /// Offene Kette aus Linien bzw. offenen Polylinien der Skizze als Punktfolge (lokal). startNear: Ende, das
    /// diesem Punkt am nächsten liegt, kommt zuerst.
    static func sheetLineChain(_ sketch: StoredSketch, entities: [Int], startNear: SIMD2<Double>?) throws -> [SIMD2<Double>] {
        var pieces: [[SIMD2<Double>]] = []
        for index in entities where sketch.entities.indices.contains(index) {
            switch sketch.entities[index] {
            case .line(let a, let b): pieces.append([a, b])
            case .polyline(let points, let closed) where !closed && points.count >= 2: pieces.append(points)
            default: throw SheetKernelError("Nur Linien wählen (eine offene Linienkette).")
            }
        }
        guard var chain = pieces.first else { throw SheetKernelError("Linien der Skizze wählen.") }
        var rest = Array(pieces.dropFirst())
        let tolerance = 1e-6
        while !rest.isEmpty {
            guard let head = chain.first, let tail = chain.last else { break }
            if let k = rest.firstIndex(where: { simd_distance($0[0], tail) < tolerance }) {
                chain += rest.remove(at: k).dropFirst()
            } else if let k = rest.firstIndex(where: { simd_distance($0[$0.count - 1], tail) < tolerance }) {
                chain += rest.remove(at: k).reversed().dropFirst()
            } else if let k = rest.firstIndex(where: { simd_distance($0[$0.count - 1], head) < tolerance }) {
                chain = Array(rest.remove(at: k).dropLast()) + chain
            } else if let k = rest.firstIndex(where: { simd_distance($0[0], head) < tolerance }) {
                chain = Array(rest.remove(at: k).reversed().dropLast()) + chain
            } else {
                throw SheetKernelError("Die Linien bilden keine zusammenhängende Kette.")
            }
        }
        guard chain.count >= 2 else { throw SheetKernelError("Linien der Skizze wählen.") }
        if simd_distance(chain[0], chain[chain.count - 1]) < tolerance {
            throw SheetKernelError("Die Linienkette muss offen sein.")
        }
        if let startNear, simd_distance(chain[chain.count - 1], startNear) < simd_distance(chain[0], startNear) {
            chain.reverse()
        }
        return chain
    }
}
