import SwiftUI
import simd

// Blech-Werkzeug „Kanten“ (Punkt 9, Kai: „Ich markiere die Flanke vorne und sage: mach eine Kantung. Wenn die
// Flanke 40 mm ist, gebe ich 40 mm ein. An der gestrichelten Linie wird dann nach oben gekantet.“):
// - Vorhandenes flaches Blech wird an einer Linie hochgekantet (SolidCraft `sheet.fold`), anders als „Lasche“
//   (Kantenflansch), die Material anfügt. Die Zuschnittgröße bleibt gleich.
// - Außenkante antippen (mehrere möglich) → Flankenlänge eingeben → die Biegelinie erscheint gestrichelt parallel zur
//   Kante, dort wird gekantet. Winkel (Standard 90°), Richtung nach oben/unten, Maßbezug Außen-/Innenmaß.
// - Alternativ die Biegelinie als Skizzenlinie auf der Blechfläche wählen (wie „Falten“).
//
// Rechnung (SolidCraft crates/doc/src/sheet.rs `add_fold`, `HeightFrom::before_leg`): `sheet.fold` mit
// position „centerline“ legt die Mitte der Biegezone (Breite BA = θ·(R + K·T)) auf die Linie; die Seite zur Kante
// hin bewegt sich und behält ihre flache Länge s (Schenkel). Die Flankenlänge H wird wie bei der Lasche am
// virtuellen Scheitel gemessen: Außenmaß H = s + (R + T)·tan(θ/2), Innenmaß H = s + R·tan(θ/2) (über 90° wie
// SolidCraft „tangent“: R + T bzw. R). Die Biegelinie liegt also im Abstand d = H − Vorlauf + BA/2 von der Kante.
// Mehrere Kanten zugleich: gegenüberliegende Kanten und Laschen eines ausgeklinkten Zuschnitts (wie Kais Kreuzform)
// gehen in einem Schritt. Treffen sich zwei Kanten an einer Ecke ohne Freischnitt, meldet das Panel die nötige
// Ausklinkung (Abstand der Biegelinie + BA/2 je Seite): SolidCraft kantet nur, was die Kontur des Zuschnitts
// freigibt; ein nachträglicher Ausschnitt (solid.extrude cut) wird nur ein Loch und hilft nicht (geprüft mit einer
// SheetKit-Probe: zweite Kantung „a fold through a flange's bend“).

// MARK: - Biegerechnung

/// Biegezugabe und Lage der Biegelinie aus Dicke, Radius und K-Faktor (neutrale Faser).
enum SheetBendMath {
    /// Biegezugabe BA = θ·(R + K·T): Länge der neutralen Faser in der Biegung
    static func allowance(angle degrees: Double, radius: Double, thickness: Double, kFactor: Double) -> Double {
        degrees * .pi / 180 * (radius + kFactor * thickness)
    }

    /// Anteil der Flankenlänge vor dem geraden Schenkel (SolidCraft `HeightFrom::before_leg`; über 90° „tangent“).
    static func beforeLeg(angle degrees: Double, radius: Double, thickness: Double, outer: Bool) -> Double {
        let base = outer ? radius + thickness : radius
        guard degrees <= 90 + 1e-9 else { return base }
        return base * tan(degrees * .pi / 360)
    }

    /// Abstand der Biegelinie (Mitte der Biegezone) von der Kante im flachen Blech; nil = Flanke kürzer als die Biegung.
    static func lineOffset(height: Double, angle: Double, radius: Double, thickness: Double, kFactor: Double,
                                       outer: Bool) -> Double? {
        let leg = height - beforeLeg(angle: angle, radius: radius, thickness: thickness, outer: outer)
        guard leg > 0.01 else { return nil }
        return leg + allowance(angle: angle, radius: radius, thickness: thickness, kFactor: kFactor) / 2
    }

    /// Kürzeste mögliche Flanke (für die Meldung)
    static func minimumHeight(angle: Double, radius: Double, thickness: Double, outer: Bool) -> Double {
        beforeLeg(angle: angle, radius: radius, thickness: thickness, outer: outer) + 0.01
    }
}

// MARK: - Gewählte Kante

/// Angetippte Außenkante eines flachen Blechbereichs, beim Antippen vermessen (Weltkoordinaten des gezeigten Körpers).
struct SheetKantEdge: Codable, Hashable {
    var body: Int
    var edge: Int
    /// Enden und Mitte der Kante (auf der Blechfläche)
    var a: SIMD3<Double>
    var b: SIMD3<Double>
    var mid: SIMD3<Double>
    /// In der Fläche, senkrecht zur Kante, ins Material
    var inward: SIMD3<Double>
    /// Außennormale der angetippten Blechfläche
    var normal: SIMD3<Double>
    /// Dickenrichtung des Blechs (SolidCraft: Seite „top“); Kanten ohne flip gehen dorthin
    var thickness: SIMD3<Double>
    var lines: [[SIMD3<Double>]] = []
}

/// Eine berechnete Kantung: Biegelinie (Mitte der Biegezone), feste Seite, Zugabe.
struct SheetKantFold {
    var edge: SheetKantEdge
    var from: SIMD3<Double>
    var to: SIMD3<Double>
    var offset: Double
    var allowance: Double
}

// MARK: - Treiber

enum SheetKantenDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetKanten
    static let title = "Kanten"
    static let icon = "arrow.turn.right.up"
    static var explanation: String? {
        "Außenkante eines flachen Blechteils antippen und die Flankenlänge eingeben: an der gestrichelten Linie wird "
            + "das vorhandene Blech hochgekantet (der Zuschnitt bleibt gleich). Dicke, Biegeradius und K-Faktor kommen "
            + "aus der Blechregel. Mehrere Kanten zugleich gehen, wenn die Ecken im Zuschnitt ausgeklinkt sind."
    }
    static var repeatable: Bool { true }

    static let inputID = "edges"
    static let edgesKey = "kanten"

    static let modes = [CommandChoice(id: "edge", title: "An Außenkante"), CommandChoice(id: "line", title: "Skizzenlinie")]
    static let measures = [CommandChoice(id: "outer", title: "Außenmaß"), CommandChoice(id: "inner", title: "Innenmaß")]
    static let directions = [CommandChoice(id: "up", title: "Nach oben"), CommandChoice(id: "down", title: "Nach unten")]
    static let quickAngles = [CommandChoice(id: "45", title: "45°"), CommandChoice(id: "90", title: "90°"),
                              CommandChoice(id: "135", title: "135°")]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let pre = Preselection(model)
        let input = PickInput(id: inputID, title: "Außenkante", accepts: [.edges], multiple: true, items: [],
                              hint: "Außenkante eines flachen Blechteils antippen (mehrere möglich).", isOptional: true)
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("height", 40)
        cmd.putNumber("angle", 90)
        cmd.choices["mode"] = "edge"
        cmd.choices["measure"] = "outer"
        cmd.choices["direction"] = "up"
        cmd.choices["position"] = "centerline"
        // Vorauswahl: gewählte Kanten eines Blechkörpers
        var list: [SheetKantEdge] = []
        for edge in pre.edges where model.isSheetBody(edge.body) {
            if let measured = measure(edge, cmd, model) { list.append(measured) }
        }
        store(list, cmd)
        if list.isEmpty, let region = pre.regions.first {
            // Gewählte Skizze: Biegelinie aus der Skizze
            cmd.choices["mode"] = "line"
            cmd.choices["lineSketch"] = String(region.sketch)
        }
        model.resetSelection()
        return cmd
    }

    // MARK: Gewählte Kanten

    @MainActor static func list(_ cmd: ModelCommand) -> [SheetKantEdge] {
        guard let text = cmd.values[edgesKey], let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([SheetKantEdge].self, from: data) else { return [] }
        return list
    }

    @MainActor static func store(_ list: [SheetKantEdge], _ cmd: ModelCommand) {
        if list.isEmpty {
            cmd.values[edgesKey] = nil
        } else if let data = try? JSONEncoder().encode(list) {
            cmd.values[edgesKey] = String(decoding: data, as: UTF8.self)
        }
        CommandPicks.setItems(list.map { Pick.edge(EdgeRef(body: $0.body, edge: $0.edge)) }, cmd, inputID)
    }

    /// Auswahlfeld mit „×“ geleert: Liste mit leeren
    @MainActor static func reconcile(_ cmd: ModelCommand) -> [SheetKantEdge] {
        let list = Self.list(cmd)
        if !list.isEmpty, cmd.items(inputID).isEmpty {
            cmd.values[edgesKey] = nil
            return []
        }
        return list
    }

    /// Angetippte Kante vermessen: Fläche des Blechs an der Kante, Richtung ins Material, Dickenrichtung.
    /// Gerechnet am gezeigten Körper (bei offener Vorschau deren Form – die Kantennummer gehört zu ihr).
    @MainActor static func measure(_ edge: EdgeRef, _ cmd: ModelCommand, _ model: ModelStore) -> SheetKantEdge? {
        let shown = model.shownBodies
        guard shown.indices.contains(edge.body) else { return nil }
        let lines = model.edgePolylines(edge)
        guard let mid = SheetEdgePicks.midpoint(edge, model: model) else { return nil }
        let topology = ModelStore.sheetTopology(shown[edge.body].shape)
        var best: (edge: SheetModelEdge, distance: Double)?
        for candidate in topology.edges {
            let distance = SheetEdgePicks.segmentDistance(mid, candidate.start, candidate.end)
            if distance < (best?.distance ?? .infinity) { best = (candidate, distance) }
        }
        guard let found = best?.edge, best?.distance ?? .infinity < 0.5 else { return nil }
        let along = found.end - found.start
        guard simd_length(along) > 1e-6 else { return nil }
        let direction = simd_normalize(along)
        // Blechfläche an der Kante: die größte ebene Nachbarfläche, die die Kante enthält (Stirnflächen dünner Körper
        // stehen nicht in der Liste)
        let faces = topology.faces.filter {
            found.faces.contains($0.face) && simd_length($0.normal) > 1e-9
                && abs(simd_dot(simd_normalize($0.normal), direction)) < 1e-3
        }
        guard let face = faces.max(by: { $0.area < $1.area }) else { return nil }
        let normal = simd_normalize(face.normal)
        var inward = simd_normalize(simd_cross(normal, direction))
        if !inside(found.mid + inward * 0.1, face: FaceRef(body: edge.body, face: face.face), normal: normal, model) {
            if inside(found.mid - inward * 0.1, face: FaceRef(body: edge.body, face: face.face), normal: normal, model) {
                inward = -inward
            } else if simd_dot(face.point - found.mid, inward) < 0 {
                inward = -inward
            }
        }
        let thickness = thicknessDirection(edge.body, normal: normal, point: found.mid, model) ?? normal
        return SheetKantEdge(body: edge.body, edge: edge.edge, a: found.start, b: found.end, mid: found.mid,
                             inward: inward, normal: normal, thickness: thickness,
                             lines: lines.isEmpty ? [[found.start, found.end]] : lines)
    }

    /// Liegt der Punkt in einem Netzdreieck der Fläche (in ihrer Ebene)?
    @MainActor private static func inside(_ point: SIMD3<Double>, face: FaceRef, normal: SIMD3<Double>,
                                          _ model: ModelStore) -> Bool {
        let triangles = model.mesh.trianglePoints(of: face)
        guard triangles.count >= 3 else { return false }
        for k in stride(from: 0, to: triangles.count - 2, by: 3) {
            let p0 = SIMD3<Double>(triangles[k]), p1 = SIMD3<Double>(triangles[k + 1]), p2 = SIMD3<Double>(triangles[k + 2])
            let q = point - normal * simd_dot(point - p0, normal)
            let c0 = simd_dot(simd_cross(p1 - p0, q - p0), normal)
            let c1 = simd_dot(simd_cross(p2 - p1, q - p1), normal)
            let c2 = simd_dot(simd_cross(p0 - p2, q - p2), normal)
            if (c0 >= 0 && c1 >= 0 && c2 >= 0) || (c0 <= 0 && c1 <= 0 && c2 <= 0) { return true }
        }
        return false
    }

    /// Dickenrichtung des Blechs an einer Fläche (Normale `normal`, Punkt `point`): SolidCraft `model.faces` nennt je
    /// Blechfläche ihre Seite (`sheet:<Körper>:<Feld>:top|bottom`); „top“ zeigt in die Dickenrichtung. nil = unbekannt.
    @MainActor static func thicknessDirection(_ body: Int, normal: SIMD3<Double>, point: SIMD3<Double>,
                                              _ model: ModelStore) -> SIMD3<Double>? {
        guard let session = try? model.sheetSession(body) else { return nil }
        let kernel = session.kernel
        let command = SheetCommand("model.faces", ["body": .string(session.name)])
        guard let json = try? SheetWorker.run({ try kernel.execute(command) }) else { return nil }
        let faces = json["faces"]?.asArray ?? json.asArray ?? []
        var best: (direction: SIMD3<Double>, distance: Double)?
        for face in faces {
            guard let name = face["sheet_face"]?.asString, let plane = face["plane_normal"]?.asPoint3,
                  let at = face["point"]?.asPoint3, simd_length(plane) > 1e-9 else { continue }
            let n = simd_normalize(plane)
            guard abs(simd_dot(n, normal)) > 0.999 else { continue }
            let top = name.hasSuffix(":top")
            guard top || name.hasSuffix(":bottom") else { continue }
            let distance = abs(simd_dot(at - point, normal))
            if distance < (best?.distance ?? .infinity) { best = (top ? n : -n, distance) }
        }
        return best?.direction
    }

    // MARK: Antippen

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil else { return false }
        let model = ws.model
        if cmd.option("mode", default: "edge") == "line" {
            // Bereich einer Skizze: diese Skizze für die Biegelinie
            if let region = tap.region {
                cmd.choices["lineSketch"] = String(region.sketch)
                SheetLines.setSelected([], cmd)
                ws.refreshCommandPreview()
                ws.objectWillChange.send()
            } else if !tap.isEmpty {
                model.message = "Kanten: Biegelinie unten im Panel aus einer Skizze wählen."
            }
            return true
        }
        guard let edge = tap.edge else {
            if let face = tap.face, !model.isSheetBody(face.body) {
                SheetConvertQuestion.ask(face.body, cmd, model)
            } else if !tap.isEmpty {
                model.message = "Kanten: eine Außenkante des Blechteils antippen, nicht die Fläche."
            }
            return true
        }
        guard model.isSheetBody(edge.body) else {
            SheetConvertQuestion.ask(edge.body, cmd, model)
            return true
        }
        SheetConvertQuestion.clear(cmd)
        var list = reconcile(cmd)
        let lines = model.edgePolylines(edge)
        // Schon gewählt: wieder abwählen
        if let index = list.firstIndex(where: { SheetEdgePicks.distance($0.mid, to: lines) < 0.05 }) {
            list.remove(at: index)
            store(list, cmd)
            ws.refreshCommandPreview()
            ws.objectWillChange.send()
            return true
        }
        guard let measured = measure(edge, cmd, model) else {
            model.message = "Kanten: eine gerade Außenkante auf der Blechfläche antippen (nicht die Kante der Blechdicke)."
            return true
        }
        if let first = list.first, first.body != measured.body {
            list = []
        }
        list.append(measured)
        store(list, cmd)
        ws.refreshCommandPreview()
        ws.objectWillChange.send()
        return true
    }

    // MARK: Rechnen

    /// Blechregel des Körpers, wie sie in seinem Rezept steht (auch abgeleitete Regeln), sonst aus dem Dokument.
    @MainActor static func rule(of body: Int, _ model: ModelStore) -> SheetRule {
        if let info = model.sheetInfo(body) {
            if let step = info.steps.last(where: {
                $0.command.command == "sheet.manage_rules" && $0.command.params["name"]?.asString == info.rule
            }), let rule = SheetRule(command: step.command) {
                return rule
            }
            if let rule = model.sheetDocument.rule(named: info.rule) { return rule }
        }
        return model.sheetDocument.activeRule
    }

    @MainActor static func radius(_ cmd: ModelCommand, _ rule: SheetRule) -> Double {
        cmd.optionalNumber("radius") ?? rule.effectiveBendRadius
    }

    /// Seite, zu der die Flanke steht: „nach oben“ = zur Welt-Z hin (senkrechte Bleche: Dickenrichtung)
    @MainActor static func legSide(_ thickness: SIMD3<Double>, _ cmd: ModelCommand) -> SIMD3<Double> {
        let z = thickness.z
        let up = abs(z) < 0.1 || z > 0 ? thickness : -thickness
        return cmd.option("direction", default: "up") == "up" ? up : -up
    }

    /// Biegelinien der gewählten Kanten (nur Kanten des ersten Körpers); Fehlertext bei zu kurzer Flanke.
    @MainActor static func folds(_ cmd: ModelCommand, _ model: ModelStore) -> (folds: [SheetKantFold], error: String?) {
        let picks = list(cmd)
        guard let body = picks.first?.body else { return ([], nil) }
        let rule = Self.rule(of: body, model)
        let r = radius(cmd, rule)
        let angle = cmd.number("angle", default: 90)
        let height = cmd.number("height", default: 40)
        let outer = cmd.option("measure", default: "outer") == "outer"
        guard let offset = SheetBendMath.lineOffset(height: height, angle: angle, radius: r, thickness: rule.thickness,
                                                    kFactor: rule.kFactor, outer: outer) else {
            let minimum = SheetBendMath.minimumHeight(angle: angle, radius: r, thickness: rule.thickness, outer: outer)
            return ([], "Die Flanke ist kürzer als die Biegung – mindestens \(SheetFormat.length(minimum)).")
        }
        let allowance = SheetBendMath.allowance(angle: angle, radius: r, thickness: rule.thickness, kFactor: rule.kFactor)
        let folds = picks.filter { $0.body == body }.map { pick in
            SheetKantFold(edge: pick, from: pick.a + pick.inward * offset, to: pick.b + pick.inward * offset,
                          offset: offset, allowance: allowance)
        }
        return (folds, nil)
    }

    /// Ecken ohne Freischnitt: zwei gewählte Kanten derselben Fläche, deren Linien sich rechtwinklig an einem Ende
    /// treffen, ohne dass der Zuschnitt dort bis hinter beide Biegezonen ausgeklinkt ist. SolidCraft kann dann die
    /// zweite Kantung nicht rechnen (die Linie liefe durch die erste Biegung; ein nachträglicher Ausschnitt ändert die
    /// Kontur des Zuschnitts nicht). Rückgabe: Meldung mit der nötigen Ausklinkung, nil = in Ordnung.
    static func cornerProblem(_ folds: [SheetKantFold]) -> String? {
        for i in folds.indices {
            for j in folds.indices where j > i {
                let p = folds[i].edge, q = folds[j].edge
                // Gleiche Blechfläche, Kanten nicht parallel
                guard abs(simd_dot(p.normal, q.normal)) > 0.999, abs(simd_dot(p.a - q.a, p.normal)) < 0.01,
                      abs(simd_dot(p.inward, q.inward)) < 0.99 else { continue }
                // Schnittpunkt der beiden Kantenlinien (Ecke)
                let dirP = simd_normalize(p.b - p.a)
                let denominator = simd_dot(dirP, q.inward)
                guard abs(denominator) > 1e-6 else { continue }
                let corner = p.a + dirP * (simd_dot(q.a - p.a, q.inward) / denominator)
                // Wie tief ist die Ecke ausgeklinkt? Abstand der Kantenenden zur Ecke
                let needP = folds[j].offset + folds[j].allowance / 2
                let needQ = folds[i].offset + folds[i].allowance / 2
                let gapP = min(simd_distance(corner, p.a), simd_distance(corner, p.b))
                let gapQ = min(simd_distance(corner, q.a), simd_distance(corner, q.b))
                // Ecke weit weg von beiden Kanten: kein gemeinsamer Eckpunkt
                guard gapP < needP + 1, gapQ < needQ + 1 else { continue }
                guard gapP < needP - 1e-3 || gapQ < needQ - 1e-3 else { continue }
                return "Kante \(i + 1) und \(j + 1) treffen sich an einer Ecke ohne Freischnitt. Den Zuschnitt dort "
                    + "mindestens \(SheetFormat.length(needQ)) × \(SheetFormat.length(needP)) ausklinken (in der Skizze "
                    + "des Blechteils) – oder „Kasten aus Maßen“ bzw. „Lasche“ verwenden."
            }
        }
        return nil
    }

    /// Rezeptschritte: je Kante ein sheet.fold (Biegemitte auf der Linie, feste Seite innen).
    @MainActor static func steps(_ cmd: ModelCommand, _ model: ModelStore) -> (body: Int, steps: [SheetStep])? {
        let computed = folds(cmd, model)
        guard let body = computed.folds.first?.edge.body else { return nil }
        let angle = cmd.number("angle", default: 90)
        let radius = cmd.optionalNumber("radius")
        var steps: [SheetStep] = []
        for fold in computed.folds {
            let pick = fold.edge
            // Punkt auf der Seite, die stehen bleibt: knapp hinter der Biegezone, auf der angetippten Fläche
            let fixed = pick.mid + pick.inward * (fold.offset + fold.allowance / 2 + 0.5)
            let flip = simd_dot(legSide(pick.thickness, cmd), pick.thickness) < 0
            steps.append(SheetStep("Kanten", .fold(from: fold.from, to: fold.to, angle: angle, radius: radius,
                                                   position: "centerline", fixed: fixed, flip: flip)))
        }
        guard !steps.isEmpty else { return nil }
        return (body, steps)
    }

    /// Biegelinie aus einer Skizzenlinie (wie „Falten“), Richtung wie bei den Kanten.
    @MainActor static func lineStep(_ cmd: ModelCommand, _ model: ModelStore) -> (body: Int?, step: SheetStep?, error: String?) {
        guard let sketch = SheetLines.sketch(cmd, model), let entity = SheetLines.selected(cmd).first,
              let line = SheetLines.lines(model, sketch: sketch).first(where: { $0.entity == entity }),
              let a = line.world.first, let b = line.world.last else { return (nil, nil, nil) }
        guard !line.isPolyline else { return (nil, nil, "Biegelinie: eine einzelne Linie wählen.") }
        let plane = model.sketches[sketch].plane
        let target: Int?
        if let source = plane.sourceBody, model.isSheetBody(source) {
            target = source
        } else {
            target = SheetUI.targetSheetBody(model)
        }
        guard let body = target else { return (nil, nil, "Kein Blechkörper im Projekt.") }
        let normal = simd_normalize(plane.normal)
        let thickness = thicknessDirection(body, normal: normal, point: (a + b) / 2, model) ?? normal
        let flip = simd_dot(legSide(thickness, cmd), thickness) < 0
        let command = SheetCommand.fold(from: a, to: b, angle: cmd.number("angle", default: 90),
                                        radius: cmd.optionalNumber("radius"),
                                        position: cmd.option("position", default: "centerline"), fixed: nil, flip: flip)
        return (body, SheetStep("Kanten", command), nil)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let angle = cmd.number("angle", default: 90)
        guard angle > 0, angle < 180 else {
            model.dropPreview()
            return "Der Winkel muss zwischen 0° und 180° liegen."
        }
        let body: Int
        let steps: [SheetStep]
        if cmd.option("mode", default: "edge") == "line" {
            let found = lineStep(cmd, model)
            if let error = found.error {
                model.dropPreview()
                return error
            }
            guard let target = found.body, let step = found.step else {
                model.dropPreview()
                return nil
            }
            body = target
            steps = [step]
        } else {
            _ = reconcile(cmd)
            let computed = folds(cmd, model)
            if let error = computed.error ?? cornerProblem(computed.folds) {
                model.dropPreview()
                return error
            }
            guard let found = Self.steps(cmd, model) else {
                model.dropPreview()
                return nil
            }
            body = found.body
            steps = found.steps
        }
        guard model.isSheetBody(body) else {
            model.dropPreview()
            return "Kanten: Kante eines Blechteils antippen."
        }
        // Entfaltet: die Anzeige liegt flach, SolidCraft nicht (Kontrolle Punkt 11)
        guard !SheetUnfoldedGuard.isUnfolded(body, model) else {
            model.dropPreview()
            return SheetUnfoldedGuard.message
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        if model.sheetRun(preview: true, { try model.sheetAppendPlan(steps, to: body) }) { return nil }
        return germanFailure(SheetPick.failure(model, "An dieser Linie lässt sich nicht kanten."))
    }

    /// Häufige Meldungen von SolidCraft beim Kanten auf Deutsch (Original in Klammern bleibt für die Fehlersuche).
    static func germanFailure(_ text: String) -> String {
        if text.contains("reaches a corner of the sheet's outline") {
            return "Die Biegezone reicht an eine Ecke des Zuschnitts – Flankenlänge ändern oder die Ecke tiefer "
                + "ausklinken. (\(text))"
        }
        if text.contains("a fold through a flange's bend") {
            return "Die Biegelinie liefe durch eine vorhandene Biegung – Ecke im Zuschnitt ausklinken oder andere Kante "
                + "wählen. (\(text))"
        }
        if text.contains("must cross the sheet with material on both sides") {
            return "Die Flanke ist länger als das Blech an dieser Stelle. (\(text))"
        }
        if text.contains("must lie on a flat face") {
            return "Die Biegelinie liegt nicht auf einer flachen Blechfläche. (\(text))"
        }
        return text
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.commit(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    // MARK: Pfeil (Flankenlänge)

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard cmd.option("mode", default: "edge") == "edge", let pick = list(cmd).first else { return [] }
        let side = legSide(pick.thickness, cmd)
        return [DragHandle(kind: .command("height"), axisOrigin: SIMD3<Float>(pick.mid), direction: SIMD3<Float>(side),
                           value: cmd.number("height", default: 40), color: Workspace.handleBlue)]
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = kind, key == "height" else { return }
        cmd.putNumber(key, max(0.1, value))
        cmd.error = refresh(cmd, ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "height" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetKantenRows(cmd: cmd, workspace: ws, model: ws.model, state: SheetCommandState.of(cmd)))
    }

    // MARK: Linien im Ansichtsfenster

    /// Gewählte Kanten (Auswahlfarbe) und die Biegelinien gestrichelt (SheetUIOverlay).
    @MainActor static func overlay(_ cmd: ModelCommand, _ model: ModelStore, perPoint: Double) -> [LineGroup] {
        guard cmd.option("mode", default: "edge") == "edge" else { return [] }
        var groups: [LineGroup] = []
        let picked = list(cmd).flatMap(\.lines).map { $0.map { SIMD3<Float>($0) } }.filter { $0.count >= 2 }
        if !picked.isEmpty {
            groups.append(LineGroup(polylines: picked, color: SheetUIOverlay.pickColor, width: 4, onTop: true))
        }
        let dash = Float(max(perPoint, 1e-6) * 7)
        var dashes: [[SIMD3<Float>]] = []
        for fold in folds(cmd, model).folds {
            // Knapp über der angetippten Fläche, damit die Linie nicht im Blech verschwindet
            let lift = fold.edge.normal * 0.02
            dashes += SheetUIOverlay.dashed([SIMD3<Float>(fold.from + lift), SIMD3<Float>(fold.to + lift)], dash: dash)
        }
        if !dashes.isEmpty {
            groups.append(LineGroup(polylines: dashes, color: SheetUIOverlay.openColor, width: 3, onTop: true))
        }
        return groups
    }
}

// MARK: - Panel

private struct SheetKantenRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var state: SheetCommandState

    var body: some View {
        let mode = cmd.option("mode", default: "edge")
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetToolPreview(sketch: .kanten)
            SheetConvertQuestionRow(workspace: workspace, model: model, state: state)
            SheetUnfoldedRow(workspace: workspace, model: model, target: unfoldedTarget)
            CommandSegmentRow(title: "Biegelinie", options: SheetKantenDriver.modes, selected: mode) { id in
                cmd.choices["mode"] = id
                CommandCache.refreshNow(cmd, workspace)
                workspace.objectWillChange.send()
            }
            if mode == "line" {
                SheetLinePicker(title: "Skizze", cmd: cmd, workspace: workspace, model: model, single: true)
                SheetMenuRow(title: "Position der Biegelinie", options: SheetFoldDriver.positions,
                             selected: cmd.option("position", default: "centerline")) { id in
                    cmd.choices["position"] = id
                    CommandCache.refreshNow(cmd, workspace)
                }
            } else {
                edgeRows
            }
            CommandValueRow(title: "Winkel", key: "angle", command: cmd, unit: "°", value: cmd.number("angle", default: 90)) {
                cmd.putNumber("angle", min(179, max(1, $0)))
                CommandCache.refreshNow(cmd, workspace)
            }
            let angle = cmd.number("angle", default: 90)
            CommandSegmentRow(title: "Schnellwahl", options: SheetKantenDriver.quickAngles,
                              selected: SheetKantenDriver.quickAngles.first(where: {
                                  abs((Double($0.id) ?? 0) - angle) < 1e-6
                              })?.id ?? "") { id in
                cmd.putNumber("angle", Double(id) ?? 90)
                CommandCache.refreshNow(cmd, workspace)
            }
            CommandOptionRow(title: "Richtung", cmd: cmd, key: "direction", options: SheetKantenDriver.directions,
                             fallback: "up", workspace: workspace)
            SheetCommandOptionalRow(title: "Biegeradius", cmd: cmd, key: "radius", workspace: workspace)
            SheetInfoRow(title: "Blechregel", text: ruleText, color: .secondary)
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }

    @ViewBuilder private var edgeRows: some View {
        let picks = SheetKantenDriver.list(cmd)
        if picks.isEmpty {
            PaletteHint(text: "Außenkante des Blechteils antippen – mehrere Kanten zugleich gehen auch.")
        } else {
            HStack(spacing: PaletteStyle.spacing) {
                SheetInfoRow(title: "Kanten", text: picks.count == 1 ? "1 Kante" : "\(picks.count) Kanten")
                PrimaryWideButton(title: "Keine", systemImage: "xmark", isPrimary: false, showsTitle: false) {
                    SheetKantenDriver.store([], cmd)
                    CommandCache.refreshNow(cmd, workspace)
                    workspace.objectWillChange.send()
                }
                .frame(width: PaletteStyle.touch + 8)
                .accessibilityLabel("Kanten abwählen")
            }
        }
        CommandValueRow(title: "Flankenlänge", key: "height", command: cmd, value: cmd.number("height", default: 40)) {
            cmd.putNumber("height", max(0.01, $0))
            CommandCache.refreshNow(cmd, workspace)
        }
        CommandOptionRow(title: "Maß", cmd: cmd, key: "measure", options: SheetKantenDriver.measures, fallback: "outer",
                         workspace: workspace)
        if let text = lineText {
            SheetInfoRow(title: "Biegelinie", text: text)
        }
    }

    /// Gemeinter Körper für den Hinweis „entfaltet“: gewählte Kante bzw. Körper der Biegelinie
    private var unfoldedTarget: Int? {
        if let body = SheetKantenDriver.list(cmd).first?.body { return body }
        guard cmd.option("mode", default: "edge") == "line", let sketch = SheetLines.sketch(cmd, model) else { return nil }
        if let source = model.sketches[sketch].plane.sourceBody, model.isSheetBody(source) { return source }
        return SheetUI.targetSheetBody(model)
    }

    /// Lage der Biegelinie im flachen Blech (Abstand der Biegemitte zur Kante) und Biegezugabe
    private var lineText: String? {
        guard let fold = SheetKantenDriver.folds(cmd, model).folds.first else { return nil }
        return "\(SheetFormat.length(fold.offset)) von der Kante (Biegemitte) · Zugabe \(SheetFormat.length(fold.allowance))"
    }

    private var ruleText: String {
        let body = SheetKantenDriver.list(cmd).first?.body ?? SheetUI.targetSheetBody(model)
        let rule = body.map { SheetKantenDriver.rule(of: $0, model) } ?? model.sheetDocument.activeRule
        let radius = SheetKantenDriver.radius(cmd, rule)
        return "Dicke \(SheetFormat.length(rule.thickness)) · Radius \(SheetFormat.length(radius)) · K "
            + rule.kFactor.formatted(.number.precision(.fractionLength(0...3)))
    }
}

// MARK: - Eigenschaften (rechtes Panel)

extension ModelStore {
    /// Zeilen für das Eigenschaften-Panel eines Blechkörpers: Dicke/Regel, Außenmaße des gekanteten Teils und das
    /// Zuschnittmaß (Hüllrechteck der Abwicklung aus dem Flachmuster). Leer bei anderen Körpern.
    func sheetPropertyRows(_ body: Int) -> [(label: String, value: String)] {
        guard let info = sheetInfo(body) else { return [] }
        let unit = LengthUnit.current
        var rows: [(label: String, value: String)] = []
        let rule = SheetKantenDriver.rule(of: body, self)
        rows.append(("Blech", "\(unit.format(rule.thickness)) · R \(unit.format(rule.effectiveBendRadius)) · \(info.rule)"))
        if !info.isUnfolded, let box = mesh.bounds(ofBody: body) {
            let size = SIMD3<Double>(box.max - box.min)
            rows.append(("Außenmaß gekantet", "\(unit.number(size.x)) × \(unit.number(size.y)) × \(unit.format(size.z))"))
        }
        if let size = SheetPropertyCache.flatSize(body, info, self) {
            rows.append(("Zuschnitt", "\(unit.number(size.x)) × \(unit.format(size.y))"))
        }
        return rows
    }
}

/// Zuschnittmaß je Rezept gemerkt (das Flachmuster braucht eine Wiedergabe in SolidCraft).
@MainActor
enum SheetPropertyCache {
    /// nil = Flachmuster ging nicht (auch merken, sonst bei jedem Neuaufbau eine neue Wiedergabe)
    private static var sizes: [Int: SIMD2<Double>?] = [:]

    static func flatSize(_ body: Int, _ info: SheetBodyInfo, _ model: ModelStore) -> SIMD2<Double>? {
        guard model.sheetAvailable else { return nil }
        let key = ModelStore.sheetCacheKey(info)
        if let size = sizes[key] { return size }
        if sizes.count > 64 { sizes.removeAll() }
        guard let pattern = try? model.flatPattern(of: body) else {
            sizes[key] = .some(nil)
            return nil
        }
        let bounds = pattern.bounds
        let size = bounds.max - bounds.min
        sizes[key] = .some(size)
        return size
    }
}
