import Foundation
import simd

// „In Blech umwandeln“ (sheet.convert) mit Wahl der offenen Kanten (Kais Wunsch): Der Benutzer wählt, welche Kanten
// offen (aufgeschnitten) sind; jede andere gerade Kante zwischen zwei ebenen Wänden wird Biegekante. SolidCraft schneidet
// Kanten zwischen Blechflächen, die keine Biegung sind, mit dem Spalt der Regel auf – die Liste `bends` entscheidet also
// genau „offen oder Biegung“. Der automatische Vorschlag legt einen Spannbaum über die Flächennachbarschaft (ab der
// größten ebenen Fläche): Baumkanten = Biegungen, alle anderen Kanten = offen; so ist die Abwicklung zusammenhängend und
// ohne Zyklen. Eine Probe-Wiedergabe in einer eigenen Sitzung prüft Fehler und Überlappungen im Flachmuster.
//
// Topologie aus OpenCASCADE (gleiche Kanten- und Flächennummern wie die Auswahl im Ansichtsfenster).

extension ModelStore {
    /// Wände (ebene Flächen ohne Stirnflächen und Fasenstreifen) und Kanten mit Nachbarflächen. Wie SolidCraft
    /// (crates/doc/src/sheet_convert.rs): Bei einem Vollkörper werden alle Flächen Blech; bei einem dünnen Körper
    /// (Schale, Platte: zur größten Fläche gibt es eine Gegenfläche im kleinen Abstand) bleiben die Stirnflächen
    /// (zwischen zwei Gegenflächen im Abstand der Dicke) draußen, so dass der Baum auf einer Haut bleibt. Modellierte
    /// Biegungen – Zylinder zwischen zwei tangentialen Wänden oder schmale Fasenstreifen – verbinden ihre beiden Wände
    /// wie eine Kante; vertreten werden sie durch ihre längste Kante zur ersten Wand, gesendet wird ein Punkt auf der
    /// Biegefläche.
    nonisolated static func sheetTopology(_ shape: PCKShape) -> (faces: [SheetModelFace], edges: [SheetModelEdge]) {
        guard PCKShape.kernelAvailable, shape.faceCount > 0 else { return ([], []) }
        struct FaceInfo {
            var kind: Int
            var normal: SIMD3<Double>?
            var origin: SIMD3<Double>?
            var area: Double
            var point: SIMD3<Double>?
        }
        let inner = sheetInteriorPoints(shape)
        var info: [Int: FaceInfo] = [:]
        var edgeFaces: [Int: [Int]] = [:]
        var faceEdges: [Int: [Int]] = [:]
        for face in 1...shape.faceCount {
            let numbers = shape.edgeNumbers(ofFace: face).map(\.intValue)
            faceEdges[face] = numbers
            for number in numbers where !(edgeFaces[number]?.contains(face) ?? false) {
                edgeFaces[number, default: []].append(face)
            }
            let kind = shape.surface(ofFace: face)?.first?.intValue ?? 5
            var entry = FaceInfo(kind: kind, area: shape.area(ofFace: face), point: inner[face])
            if kind == 0, let plane = shape.plane(ofFace: face)?.map(\.doubleValue), plane.count == 6 {
                entry.origin = SIMD3(plane[0], plane[1], plane[2])
                entry.normal = simd_normalize(SIMD3(plane[3], plane[4], plane[5]))
            }
            if entry.point == nil {
                // Rückfall ohne Netzdreieck: Umrissmitte, auf die Fläche gezogen
                if let outline = shape.outline(ofFace: face, deflection: 0.1)?.map(\.doubleValue), outline.count >= 3 {
                    var sum = SIMD3<Double>.zero
                    var k = 0
                    while k + 2 < outline.count {
                        sum += SIMD3(outline[k], outline[k + 1], outline[k + 2])
                        k += 3
                    }
                    let center = sum / Double(outline.count / 3)
                    let snapped = shape.surfacePoint(ofFace: face, near: center)?.map(\.doubleValue) ?? []
                    entry.point = snapped.count >= 3 ? SIMD3(snapped[0], snapped[1], snapped[2]) : center
                }
            }
            info[face] = entry
        }
        func neighbours(_ face: Int) -> [Int] {
            var result: [Int] = []
            for edge in faceEdges[face] ?? [] {
                for other in edgeFaces[edge] ?? [] where other != face && !result.contains(other) { result.append(other) }
            }
            return result
        }
        func planeDistance(_ a: FaceInfo, _ b: FaceInfo) -> Double? {
            guard let na = a.normal, let oa = a.origin, let ob = b.origin else { return nil }
            return abs(simd_dot(ob - oa, na))
        }
        // Dicke eines dünnen Körpers: Gegenfläche der größten ebenen Fläche im kleinen Abstand
        let planar = info.filter { $0.value.normal != nil }.sorted { $0.value.area > $1.value.area }
        var thickness: Double?
        if let base = planar.first?.value, let nb = base.normal {
            for (_, other) in planar.dropFirst() {
                guard let no = other.normal, simd_dot(nb, no) < -0.999, other.area >= 0.3 * base.area,
                      let d = planeDistance(base, other), d > 1e-6, d <= 0.1 * base.area.squareRoot() else { continue }
                thickness = min(thickness ?? d, d)
            }
        }
        // Stirnflächen: grenzen an zwei Gegenflächen im Abstand der Dicke
        var rims: Set<Int> = []
        if let t = thickness {
            for face in info.keys {
                let around = neighbours(face).compactMap { info[$0] }.filter { $0.normal != nil }
                outer: for a in around {
                    for b in around where simd_dot(a.normal!, b.normal!) < -0.99 {
                        if let d = planeDistance(a, b), abs(d - t) <= 0.1 * t + 1e-3 {
                            rims.insert(face)
                            break outer
                        }
                    }
                }
            }
        }
        func edgeLength(_ edge: Int) -> Double { shape.length(ofEdge: edge) }
        func sharedEdges(_ a: Int, _ b: Int) -> [Int] {
            (faceEdges[a] ?? []).filter { (edgeFaces[$0] ?? []).contains(b) }
        }
        // Modellierte Biegungen: Biegefläche → ihre beiden Wände
        var bendFaces: [Int: (Int, Int)] = [:]
        for (face, entry) in info where !rims.contains(face) {
            let walls = neighbours(face).filter { info[$0]?.normal != nil && !rims.contains($0) }
            if entry.kind == 1, let cylinder = shape.cylinder(ofFace: face)?.map(\.doubleValue), cylinder.count >= 6 {
                // Zylinder: die zwei Wände, deren Normale quer zur Achse steht (tangential), nicht die Endflächen
                let axis = simd_normalize(SIMD3(cylinder[3], cylinder[4], cylinder[5]))
                let tangent = walls.filter { abs(simd_dot(info[$0]!.normal!, axis)) < 0.05 }
                if tangent.count == 2 { bendFaces[face] = (tangent[0], tangent[1]) }
            } else if entry.kind == 0, let nf = entry.normal {
                // Fasenstreifen: schmal, an den zwei längsten Kanten zwei Wände, deren Normalen er „halbiert“
                let lines = (faceEdges[face] ?? []).sorted { edgeLength($0) > edgeLength($1) }
                guard lines.count >= 2, edgeLength(lines[0]) > 1e-6 else { continue }
                let across = lines.prefix(2).compactMap { edge in (edgeFaces[edge] ?? []).first { $0 != face } }
                guard across.count == 2, across[0] != across[1], let a = info[across[0]], let b = info[across[1]],
                      let na = a.normal, let nb = b.normal, !rims.contains(across[0]), !rims.contains(across[1]) else { continue }
                let width = entry.area / edgeLength(lines[0])
                let knick = acos(max(-1, min(1, simd_dot(na, nb)))) * 180 / .pi
                if knick > 1, simd_dot(na, nb) > -0.99, simd_dot(nf, na) > 0, simd_dot(nf, nb) > 0,
                   width < 0.25 * min(a.area, b.area).squareRoot() {
                    bendFaces[face] = (across[0], across[1])
                }
            }
        }
        let walls = Set(info.keys.filter { info[$0]?.normal != nil && !rims.contains($0) && bendFaces[$0] == nil })
        var faces: [SheetModelFace] = []
        for face in walls.sorted() {
            guard let entry = info[face], let normal = entry.normal else { continue }
            faces.append(SheetModelFace(face: face, area: entry.area, normal: normal, point: entry.point ?? entry.origin ?? .zero))
        }
        func knickAngle(_ a: Int, _ b: Int) -> Double {
            guard let na = info[a]?.normal, let nb = info[b]?.normal else { return 0 }
            return acos(max(-1, min(1, simd_dot(na, nb)))) * 180 / .pi
        }
        var edges: [Int: SheetModelEdge] = [:]
        for (number, adjacent) in edgeFaces {
            guard let g = shape.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 11 else { continue }
            var edge = SheetModelEdge(edge: number, start: SIMD3(g[2], g[3], g[4]), end: SIMD3(g[5], g[6], g[7]),
                                      mid: SIMD3(g[8], g[9], g[10]), faces: adjacent, angle: 0, isCandidate: false)
            if adjacent.count == 2 {
                edge.angle = knickAngle(adjacent[0], adjacent[1])
                edge.isCandidate = g[0] == 0 && walls.contains(adjacent[0]) && walls.contains(adjacent[1])
                    && edge.angle > 1 && edge.angle < 179
            }
            edges[number] = edge
        }
        // Biegeflächen: ihre längste Kante zur ersten Wand vertritt die Biegung
        for (face, pair) in bendFaces where walls.contains(pair.0) && walls.contains(pair.1) {
            guard let representative = sharedEdges(face, pair.0).max(by: { edgeLength($0) < edgeLength($1) }),
                  var edge = edges[representative] else { continue }
            edge.faces = [pair.0, pair.1]
            edge.angle = knickAngle(pair.0, pair.1)
            edge.isCandidate = true
            edge.bendFace = face
            edge.bendPoint = info[face]?.point
            edges[representative] = edge
        }
        return (faces, edges.values.sorted { $0.edge < $1.edge })
    }

    /// Je Fläche ein Punkt sicher im Inneren: Schwerpunkt ihres größten Netzdreiecks (gewölbte Flächen auf die
    /// Fläche gezogen). Auch bei L-förmigen Flächen und Flächen mit Loch in der Mitte.
    nonisolated static func sheetInteriorPoints(_ shape: PCKShape) -> [Int: SIMD3<Double>] {
        let box = shape.boundingBox?.map(\.doubleValue) ?? []
        let size = box.count == 6 ? max(box[3] - box[0], box[4] - box[1], box[5] - box[2]) : 100
        let mesh = shape.triangulate(deflection: max(0.01, size * 0.002))
        let vertices: [Float] = mesh.vertexData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let indices: [UInt32] = mesh.indexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let faceOf: [UInt32] = mesh.faceIndexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        var best: [Int: (area: Double, point: SIMD3<Double>)] = [:]
        func vertex(_ i: UInt32) -> SIMD3<Double>? {
            let k = Int(i) * 6
            guard k + 2 < vertices.count else { return nil }
            return SIMD3(Double(vertices[k]), Double(vertices[k + 1]), Double(vertices[k + 2]))
        }
        for t in faceOf.indices where t * 3 + 2 < indices.count {
            guard let a = vertex(indices[t * 3]), let b = vertex(indices[t * 3 + 1]), let c = vertex(indices[t * 3 + 2]) else { continue }
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            let face = Int(faceOf[t])
            if area > (best[face]?.area ?? 0) { best[face] = (area, (a + b + c) / 3) }
        }
        var result: [Int: SIMD3<Double>] = [:]
        for (face, entry) in best {
            var point = entry.point
            // Gewölbte Flächen: Dreiecksmitte liegt knapp unter der Fläche
            if shape.surface(ofFace: face)?.first?.intValue != 0,
               let snapped = shape.surfacePoint(ofFace: face, near: point)?.map(\.doubleValue), snapped.count >= 3 {
                point = SIMD3(snapped[0], snapped[1], snapped[2])
            }
            result[face] = point
        }
        return result
    }

    /// Ebene Platte: keine Biege-Kandidaten (dünner Körper aus zwei Häuten und Stirnflächen).
    nonisolated static func sheetIsPlate(_ topology: (faces: [SheetModelFace], edges: [SheetModelEdge])) -> Bool {
        !topology.faces.isEmpty && !topology.edges.contains(where: \.isCandidate)
    }

    /// Biegekanten = alle Kandidaten ohne die offenen.
    nonisolated static func sheetBendEdges(_ edges: [SheetModelEdge], open: Set<Int>) -> Set<Int> {
        Set(edges.filter { $0.isCandidate && !open.contains($0.edge) }.map(\.edge))
    }

    /// Spannbaum über die Flächennachbarschaft ab base (Breitensuche bzw. Tiefensuche): Baumkanten = Biegungen,
    /// übrige Kandidaten = offen. Flächen, die von base nicht erreichbar sind, gehören nicht zum Blech.
    nonisolated static func sheetSpanningTree(_ topology: (faces: [SheetModelFace], edges: [SheetModelEdge]), base: Int,
                                              depthFirst: Bool = false) -> (bends: Set<Int>, open: Set<Int>) {
        let candidates = topology.edges.filter(\.isCandidate)
        var neighbours: [Int: [SheetModelEdge]] = [:]
        for edge in candidates {
            neighbours[edge.faces[0], default: []].append(edge)
            neighbours[edge.faces[1], default: []].append(edge)
        }
        // Größere Nachbarflächen zuerst: lange Biegekanten, kompakte Abwicklung
        let area = Dictionary(uniqueKeysWithValues: topology.faces.map { ($0.face, $0.area) })
        var visited: Set<Int> = [base]
        var frontier = [base]
        var bends: Set<Int> = []
        while !frontier.isEmpty {
            let face = depthFirst ? frontier.removeLast() : frontier.removeFirst()
            let next = (neighbours[face] ?? []).sorted { a, b in
                let fa = a.faces[0] == face ? a.faces[1] : a.faces[0]
                let fb = b.faces[0] == face ? b.faces[1] : b.faces[0]
                return (area[fa] ?? 0) > (area[fb] ?? 0)
            }
            for edge in next {
                let other = edge.faces[0] == face ? edge.faces[1] : edge.faces[0]
                guard !visited.contains(other) else { continue }
                visited.insert(other)
                bends.insert(edge.edge)
                frontier.append(other)
            }
        }
        let open = Set(candidates.map(\.edge)).subtracting(bends)
        return (bends, open)
    }

    // MARK: Probe und Vorschlag

    /// Rezept für die Umwandlung (Regel, Ausgangskörper, sheet.convert). sourceFile im Ordner sheet/.
    /// gap ≠ nil: abgeleitete Regel „<Regel> · Spalt x mm“ nur im Rezept (sheet.convert lehnt mit `bends` Regelwerte
    /// als Parameter ab; einen Spalt je Kante kennt SolidCraft nicht).
    static func sheetConvertSteps(rule base: SheetRule, basePoint: SIMD3<Double>, bendPoints: [SIMD3<Double>],
                                  plateOnly: Bool, gap: Double? = nil) -> [SheetStep] {
        var rule = base
        if let gap, gap != base.gap {
            rule.gap = gap
            rule.name = "\(base.name) · Spalt \(Self.sheetNumberText(gap)) mm"
        }
        var params: SheetJSON = ["body": "$src", "face": SheetJSON(basePoint), "rule": .string(rule.name)]
        if !plateOnly, !bendPoints.isEmpty { params["bends"] = .array(bendPoints.map { SheetJSON($0) }) }
        return [
            SheetStep(rule.command(active: true).title, rule.command(active: true)),
            SheetStep("Ausgangskörper", SheetCommand("psk.import_step", ["path": "$source", "name": "Quelle"]), alias: "$src"),
            SheetStep("In Blech umwandeln", SheetCommand("sheet.convert", params), alias: "$sheet"),
        ]
    }

    /// Probe-Wiedergabe in eigener Sitzung (im Hintergrund mit Zeitlimit): problem nil = in Ordnung.
    static func sheetProbe(_ shape: PCKShape, steps: [SheetStep]) -> (problem: String?, timedOut: Bool) {
        let directory = FileManager.default.temporaryDirectory
        let file = "pencil-sheet-probe-\(UUID().uuidString).step"
        let url = directory.appending(path: file)
        // Unabhängige Kopie: der Vordergrund vernetzt den Körper weiter; geschrieben wird auf der Warteschlange.
        // Ohne Kopie im Vordergrund schreiben (das Original darf nie auf die Warteschlange, s. sheetWriteSTEP).
        let path = url.path(percentEncoded: false)
        let copy: PCKShape? = shape.independentCopy().flatMap { $0 === shape ? nil : $0 }
        if copy == nil {
            guard PCKShape.writeSTEP([shape], path: path) else {
                return ("Körper ließ sich nicht als STEP schreiben.", false)
            }
        }
        var info = SheetBodyInfo(steps: steps, kernelBody: "$sheet", rule: "")
        info.sourceFile = file
        do {
            let flat = try SheetWorker.run { () throws -> FlatPattern in
                defer { try? FileManager.default.removeItem(at: url) }
                if let copy, !PCKShape.writeSTEP([copy], path: path) {
                    throw SheetKernelError("Körper ließ sich nicht als STEP schreiben.")
                }
                let result = try Self.sheetReplay(info, directory: directory)
                return FlatPattern(json: try result.kernel.execute(SheetCommand("sheet.flat_pattern", ["body": .string(result.bodyName)])))
            }
            return (sheetOverlapProblem(flat), false)
        } catch let error as SheetKernelError {
            return (error.message, error.timedOut)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    /// Überlappt sich das Flachmuster (Kontur schneidet sich selbst, Teile liegen übereinander)?
    nonisolated static func sheetOverlapProblem(_ flat: FlatPattern) -> String? {
        guard !flat.outline.isEmpty else { return "Das Flachmuster ist leer." }
        for loop in flat.outline where loop.count <= 4000 && polylineIntersectsItself(loop) {
            return "Die Abwicklung überlappt sich – andere Kanten öffnen."
        }
        if flat.outline.count > 1 {
            for (i, a) in flat.outline.enumerated() {
                for b in flat.outline[(i + 1)...] where !a.isEmpty && !b.isEmpty {
                    if polygonContains(a, b[0]) || polygonContains(b, a[0]) {
                        return "Teile der Abwicklung liegen übereinander – andere Kanten öffnen."
                    }
                }
            }
            return "Die Abwicklung zerfällt in \(flat.outline.count) Teile – weniger Kanten öffnen."
        }
        return nil
    }

    /// Schneiden sich zwei nicht benachbarte Strecken des geschlossenen Linienzugs?
    nonisolated private static func polylineIntersectsItself(_ points: [SIMD2<Double>]) -> Bool {
        let n = points.count
        guard n >= 4 else { return false }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        let size = points.reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
        let eps = 1e-9 * max(1, size * size)
        for i in 0..<(n - 2) {
            let a1 = points[i], a2 = points[(i + 1) % n]
            for j in (i + 2)..<n {
                if i == 0 && j == n - 1 { continue }
                let b1 = points[j], b2 = points[(j + 1) % n]
                let d1 = cross(a2 - a1, b1 - a1), d2 = cross(a2 - a1, b2 - a1)
                let d3 = cross(b2 - b1, a1 - b1), d4 = cross(b2 - b1, a2 - b1)
                if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) && ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps)) {
                    return true
                }
            }
        }
        return false
    }

    func sheetSuggestConversion(_ body: Int, baseFace: Int?, rule ruleName: String?) -> SheetConversionPlan? {
        guard bodies.indices.contains(body), let rule = try? sheetRule(ruleName) else { return nil }
        let shape = bodies[body].shape
        let topology = Self.sheetTopology(shape)
        let byArea = topology.faces.sorted { $0.area > $1.area }
        guard !byArea.isEmpty else { return nil }
        // Grundflächen in Reihenfolge: gewählte bzw. größte, dann die nächstgrößten; je Breiten- und Tiefensuche
        var bases = byArea.prefix(3).map(\.face)
        if let baseFace, topology.faces.contains(where: { $0.face == baseFace }) {
            bases.removeAll { $0 == baseFace }
            bases.insert(baseFace, at: 0)
        }
        // Ebene Platte (Befund 15/21): ohne Biegungen, alle Kanten bleiben Rand
        if Self.sheetIsPlate(topology) {
            return sheetPlanFor(shape, topology: topology, base: bases[0], open: [], rule: rule)
        }
        var first: SheetConversionPlan?
        for base in bases {
            for depthFirst in [false, true] {
                let tree = Self.sheetSpanningTree(topology, base: base, depthFirst: depthFirst)
                guard let plan = sheetPlanFor(shape, topology: topology, base: base, open: tree.open, rule: rule) else { continue }
                if plan.problem == nil { return plan }
                first = first ?? plan
                // Zeitlimit: keine weiteren Versuche
                if plan.timedOut { return plan }
                // Ohne Blechmodul gibt es keine Probe: der erste Vorschlag gilt
                if !SheetKernel.isAvailable { return plan }
            }
            if baseFace != nil, first != nil { break }
        }
        return first
    }

    func sheetCheckConversion(_ body: Int, baseFace: Int, openEdges: Set<Int>, rule ruleName: String?,
                              gap: Double? = nil) -> SheetConversionPlan? {
        guard bodies.indices.contains(body), let rule = try? sheetRule(ruleName) else { return nil }
        let shape = bodies[body].shape
        return sheetPlanFor(shape, topology: Self.sheetTopology(shape), base: baseFace, open: openEdges, rule: rule, gap: gap)
    }

    /// Zahl ohne überflüssige Nachkommastellen („2“, „0.5“).
    static func sheetNumberText(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// Plan mit Probe-Wiedergabe.
    private func sheetPlanFor(_ shape: PCKShape, topology: (faces: [SheetModelFace], edges: [SheetModelEdge]),
                              base: Int, open: Set<Int>, rule: SheetRule, gap: Double? = nil) -> SheetConversionPlan? {
        guard let face = topology.faces.first(where: { $0.face == base }) else { return nil }
        let bends = Self.sheetBendEdges(topology.edges, open: open)
        let points = topology.edges.filter { bends.contains($0.edge) }.map { $0.bendPoint ?? $0.mid }
        var plan = SheetConversionPlan(baseFace: base, basePoint: face.point, openEdges: open, bendEdges: bends)
        plan.plateOnly = Self.sheetIsPlate(topology)
        if SheetKernel.isAvailable {
            let steps = Self.sheetConvertSteps(rule: rule, basePoint: face.point, bendPoints: points, plateOnly: plan.plateOnly,
                                               gap: gap)
            let probe = Self.sheetProbe(shape, steps: steps)
            plan.problem = probe.problem
            plan.timedOut = probe.timedOut
        } else {
            plan.problem = SheetKernelError.notBuilt.message
        }
        return plan
    }

    /// Umwandeln: Ausgangskörper speichern, Rezept wiedergeben, Körper an seiner Stelle ersetzen.
    func sheetConvertPlan(_ body: Int, baseFace: Int, openEdges: Set<Int>, rule ruleName: String?,
                          plateOnly: Bool, gap: Double? = nil) throws -> SheetPlan {
        guard bodies.indices.contains(body) else { throw SheetKernelError("Körper wählen.") }
        if bodies[body].sheetMetal != nil, !sheetBodyIsModified(body) {
            throw SheetKernelError("„\(bodies[body].name)“ ist schon ein Blechkörper.")
        }
        let rule = try sheetRule(ruleName)
        let shape = bodies[body].shape
        let topology = Self.sheetTopology(shape)
        guard let face = topology.faces.first(where: { $0.face == baseFace }) else {
            throw SheetKernelError("Als Grundfläche eine ebene Fläche wählen.")
        }
        let bends = Self.sheetBendEdges(topology.edges, open: openEdges)
        let points = topology.edges.filter { bends.contains($0.edge) }.map { $0.bendPoint ?? $0.mid }
        let steps = Self.sheetConvertSteps(rule: rule, basePoint: face.point, bendPoints: points, plateOnly: plateOnly, gap: gap)
        let file = "\(UUID().uuidString).step"
        let url = sheetDocument.storageDirectory.appending(path: file)
        try sheetWriteSTEP(shape, to: url)
        var info = SheetBodyInfo(steps: steps, kernelBody: "$sheet", rule: rule.name)
        info.sourceFile = file
        let built: (body: SceneBody, warnings: [String])
        do {
            built = try sheetBuild(info, base: bodies[body], name: bodies[body].name)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        var result = bodies
        result[body] = built.body
        let data = SheetFeatureData(mode: "convert", steps: steps, kernelBody: "$sheet", rule: rule.name, sourceFile: file)
        let feature = Self.sheetFeature("Blech: In Blech umwandeln", data: data, target: body)
        return SheetPlan(bodies: result, feature: feature, name: "In Blech umwandeln", warnings: built.warnings)
    }
}
