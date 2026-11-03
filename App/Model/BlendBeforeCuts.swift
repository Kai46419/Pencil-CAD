import Foundation
import simd

// Rundung vor Schnitt (Kai: Text „Kai“ als Tasche, das „i“ schneidet die Körperkante an, danach Abrunden dieser
// Kante): Die Tasche zerteilt die Kante in Stücke. Direkt verrundet blieben dort, wo das „i“ die Kante
// unterbricht, kantige Reste und verdrehte Übergänge stehen. Wie in Fusion 360, wenn man die Rundung in der
// Zeitleiste vor den Schnitt zieht, gilt deshalb: Die Rundung hat Vorrang.
//
// Ablauf beim Abrunden bzw. Fasen (setEdgeValue):
// 1. Rückwärts durch den Verlauf, solange die Schritte nur abziehen bzw. neue Körper anhängen (Extrudieren/Drehen
//    „Abziehen“ oder „Neuer Körper“, Grundkörper, Boolesch „Abziehen“ mit behaltenen Werkzeugen, Unterdrücktes):
//    Liegen die gewählten Kantenstücke im Stand davor auf einer (längeren) Kante – geometrisch: alle Punkte jedes
//    Stücks auf ihr, gleiche Richtung ins Material –, ist das die ursprüngliche Kante.
// 2. Die Rundung wird als eigenes Feature direkt vor dem Schnitt eingefügt, der die Kante zerteilt hat, und der
//    Verlauf ab dort neu gerechnet: Die Rundung läuft über die ganze Kante, die Tasche schneidet danach wieder
//    hinein. Der Eintrag steht sichtbar vor dem Schnitt in der Zeitleiste; gespeichert wird nur die gewohnte
//    Feature-Liste (keine neuen Felder, abwärtskompatibel), Ändern des Radius bzw. Nachbau laufen wie immer.
// 3. Geht das nicht (Kante gab es früher nicht, fester Stand dazwischen, Rundung oder ein späterer Schritt
//    schlägt so fehl): bisheriger Weg direkt am Körper, aber mit allen Teilstücken derselben geraden Kante
//    zwischen denselben zwei Flächen zugleich (completedEdgeChain).

/// Vorschau einer vor Schnitte eingefügten Rundung: die neue Feature-Liste und die Körper nach jedem neu
/// gerechneten Feature (werden erst beim Übernehmen in den Zwischenstand-Speicher geschrieben).
struct OrderedBlendPreview {
    var features: [Feature]
    var states: [UUID: [SceneBody]]
}

struct BlendPlacementKey: Equatable {
    var edges: [EdgeRef]
    var shape: ObjectIdentifier
    var featureIDs: [UUID]
}

/// Wo im Verlauf die gewählten Kanten noch ganz waren.
struct BlendPlan {
    /// Einfügeposition in der Feature-Liste (vor dem Schnitt, der die Kante zerteilt hat)
    var position: Int
    /// Körper (Index im Stand davor; Schnitte und neue Körper ändern ihn nicht)
    var body: Int
    /// Kantennummern der ursprünglichen Kante(n) im Stand davor
    var edges: [Int]
    var signatures: [EdgeSignature]
    /// Körper im Stand davor
    var shape: PCKShape
    /// Gemerkte Versuche je Wert: gelungene (sofort wieder gezeigt) und fehlgeschlagene (nicht noch einmal gerechnet)
    var succeeded: [OrderedAttemptKey: OrderedAttempt] = [:]
    var failed: Set<OrderedAttemptKey> = []
}

/// Werte eines Versuchs „Rundung vor Schnitt“.
struct OrderedAttemptKey: Hashable {
    var operation: EdgeOperation
    var value: Double
    var second: Double?
    var end: Double?
}

/// Gelungener Versuch „Rundung vor Schnitt“ (Vorschau samt umgestellter Liste).
struct OrderedAttempt {
    var bodies: [SceneBody]
    var features: [Feature]
    var states: [UUID: [SceneBody]]
    /// Tatsächlich verwendeter Wert
    var amount: Double
}

/// Ineinanderlaufende Rundungen (Kai: zweite variable Rundung an einer Kante, die an eine schon verrundete Kante
/// grenzt; Rundungen mehrerer Kanten, die sich in einer Ecke überschneiden): Geometrie der gemeinsamen Rundung,
/// gemerkt je Kantenauswahl.
struct BlendMergeGeometry {
    /// Index der angrenzenden früheren Rundung (die letzte oder eine bis blendSearchDepth Schritte davor)
    var index: Int
    /// Körper vor der vorigen Rundung
    var shape: PCKShape
    /// Kanten der vorigen Rundung im Körper davor
    var previousEdges: [Int]
    /// Neue Kanten im Körper davor (die gewählten Stücke liegen auf ihnen)
    var newEdges: [Int]
    var signatures: [EdgeSignature]
}

struct BlendMergeMemo {
    var key: BlendPlacementKey
    var geometry: BlendMergeGeometry?
    /// Nachbau mit einer früheren Rundung (previewMergedBlend): gelungene und fehlgeschlagene Werte
    var succeeded: [OrderedAttemptKey: OrderedAttempt] = [:]
    var failed: Set<OrderedAttemptKey> = []
}

/// Gemerkte Suche (plan nil = keine längere frühere Kante, bisheriger Weg).
struct BlendPlacement {
    var key: BlendPlacementKey
    var plan: BlendPlan?
}

/// Kanten eines Körpers als Linienzüge (aus dem Anzeigenetz, Nummern wie filleting(edges:)).
private struct EdgeTrace {
    var segments: [Int: [(SIMD3<Double>, SIMD3<Double>)]] = [:]

    init(_ shape: PCKShape) {
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        for (i, ref) in mesh.edgeRefs.enumerated() where ref.edge > 0 && i * 2 + 1 < mesh.edges.count {
            let a = SIMD3<Double>(mesh.edges[i * 2])
            let b = SIMD3<Double>(mesh.edges[i * 2 + 1])
            segments[ref.edge, default: []].append((a, b))
        }
    }

    /// Punkte entlang einer Kante (Enden aller Teilstrecken).
    func samples(_ edge: Int) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = []
        for segment in segments[edge] ?? [] {
            points.append(segment.0)
            points.append(segment.1)
        }
        return points
    }

    static func distance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let ab: SIMD3<Double> = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-18 else { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        let foot: SIMD3<Double> = a + ab * t
        return simd_distance(p, foot)
    }

    /// Größter Abstand der Punkte zur Kante (bricht ab, sobald limit überschritten ist).
    func deviation(of points: [SIMD3<Double>], from edge: Int, limit: Double) -> Double {
        guard let list = segments[edge], !list.isEmpty else { return .infinity }
        var worst = 0.0
        for point in points {
            var nearest = Double.infinity
            for segment in list {
                nearest = min(nearest, Self.distance(point, segment.0, segment.1))
                if nearest <= 1e-9 { break }
            }
            worst = max(worst, nearest)
            if worst > limit { return worst }
        }
        return worst
    }
}

extension ModelStore {
    /// Abstand, bis zu dem ein Kantenstück auf einer früheren Kante liegt (mm; Netz mit 0,05 mm Sehnenfehler)
    private static let blendTraceTolerance = 0.08
    /// So viele Schritte sucht die Rundung höchstens rückwärts
    private static let blendSearchDepth = 12

    /// Ruhezeit, nach der „Rundung vor Schnitt“ (Nachbau auf dem Main-Thread) versucht wird: beim Ziehen am Pfeil
    /// bzw. schnellen Eintippen rechnet so nur die schnelle direkte Vorschau im Hintergrund
    private static let orderedDelay = 0.15

    /// setEdgeValue: Rundung bzw. Fase vor die Schnitte stellen, die die gewählte Kante zerteilt haben, und als
    /// Vorschau zeigen. true = gemerkter, gelungener Versuch wird gezeigt. false = (noch) nicht: bisheriger Weg; ein
    /// neuer Versuch läuft entprellt nach orderedDelay Ruhe und ersetzt dann die direkte Vorschau, wenn er gelingt.
    /// Fehlschläge werden gemerkt und nicht noch einmal gerechnet.
    func previewBlendBeforeCuts(value: Double) -> Bool {
        guard value > 0, let body = selectedEdges.first?.body, bodies.indices.contains(body),
              let plan = blendPlan(body: body) else { return false }
        let key = currentOrderedKey(value: value)
        if let known = plan.succeeded[key] {
            showOrderedBlend(known, plan: plan, body: body, key: key)
            return true
        }
        if plan.failed.contains(key) { return false }
        // Hängt gerade eine Rundung im Hintergrund (Zeitlimit überschritten), nicht noch auf dem Main-Thread rechnen
        guard !blendJobs.overdue else { return false }
        blendJobs.orderedToken += 1
        let token = blendJobs.orderedToken
        let generation = blendJobs.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.orderedDelay) { [weak self] in
            guard let self, self.blendJobs.orderedToken == token, self.blendJobs.generation == generation else { return }
            self.runOrderedBlend(key)
        }
        return false
    }

    private func currentOrderedKey(value: Double) -> OrderedAttemptKey {
        let operation = edgeOperation
        return OrderedAttemptKey(operation: operation, value: value,
                                 second: operation == .chamfer ? edgeSecondValue : nil,
                                 end: operation == .fillet ? edgeEndValue : nil)
    }

    /// Entprellter Versuch „Rundung vor Schnitt“ (Main-Thread, Nachbau ab der Einfügestelle). Ergebnis bzw.
    /// Fehlschlag wird gemerkt.
    private func runOrderedBlend(_ key: OrderedAttemptKey) {
        guard let body = selectedEdges.first?.body, bodies.indices.contains(body), let plan = blendPlan(body: body),
              edgeOperation == key.operation, currentOrderedKey(value: edgeValue) == key else { return }
        let operation = key.operation
        let value = key.value
        // Keine automatische Suche nach einem kleineren Wert: OCCT kann bei solchen zusätzlichen
        // Rundungsversuchen abstürzen. Der verlangte Wert gelingt oder bleibt ohne Änderung.
        guard let attempt = orderedBlend(plan, operation: operation, value: value,
                                         second: key.second, end: key.end) else {
            featureRecorder.blendPlacement?.plan?.failed.insert(key)
            return
        }
        let success = OrderedAttempt(bodies: attempt.bodies, features: attempt.features, states: attempt.states,
                                     amount: value)
        if (featureRecorder.blendPlacement?.plan?.succeeded.count ?? 0) >= 4 {
            featureRecorder.blendPlacement?.plan?.succeeded = [:]
        }
        featureRecorder.blendPlacement?.plan?.succeeded[key] = success
        // Die Rundung vor dem Schnitt hat Vorrang: direkte Vorschau aus dem Hintergrund verwerfen
        supersedeBlendJobs()
        showOrderedBlend(success, plan: plan, body: body, key: key)
        blendJobs.finished?()
    }

    private func showOrderedBlend(_ attempt: OrderedAttempt, plan: BlendPlan, body: Int, key: OrderedAttemptKey) {
        let operation = key.operation
        previewHiddenSketch = bodies[body].sketchID
        let name = operation == .fillet && key.end != nil ? "Variabel abrunden" : operation.rawValue
        showPreview(attempt.bodies, name: name)
        // Nach showPreview (das die Aufzeichnung leert): beim Übernehmen gilt die umgestellte Liste
        featureRecorder.orderedPreview = OrderedBlendPreview(features: attempt.features, states: attempt.states)
        let cuts = features.count - plan.position
        let first = features[plan.position].name
        let place = cuts == 1 ? "vor „\(first)“" : "vor „\(first)“ und \(cuts - 1) weitere Schritte"
        var note = "\(operation.rawValue) \(place) eingefügt: über die ganze Kante, der Schnitt schneidet danach hinein."
        if attempt.amount < key.value - 1e-9 {
            note = "\(operation.rawValue): größter möglicher Wert hier \(attempt.amount.formatted()) mm – " + note
        }
        message = note
    }

    /// Verlauf mit der Rundung an plan.position neu rechnen (ohne den Zwischenstand-Speicher zu ändern).
    /// nil, wenn die Rundung oder ein danach folgender, vorher gelungener Schritt fehlschlägt.
    private func orderedBlend(_ plan: BlendPlan, operation: EdgeOperation, value: Double, second: Double?,
                              end: Double?) -> (bodies: [SceneBody], features: [Feature], states: [UUID: [SceneBody]])? {
        guard plan.position < features.count else { return nil }
        var feature = Self.blendFeature(operation, value: value, second: second, end: end)
        feature.data.target = plan.body
        feature.data.edges = plan.signatures
        var list = features
        let failedBefore = list.map(\.failed)
        list.insert(feature, at: plan.position)
        var states: [UUID: [SceneBody]] = [:]
        guard let run = runFeatures(&list, from: plan.position, sketches: sketches, values: variableValues,
                                    collect: { id, state in states[id] = state }) else { return nil }
        guard !list[plan.position].failed else { return nil }
        for index in (plan.position + 1)..<list.count where list[index].failed && !failedBefore[index - 1] {
            return nil
        }
        guard run.bodies.count == bodies.count else { return nil }
        return (carryingBodyDetails(run.bodies), list, states)
    }

    /// Gemerkte bzw. neue Suche für die aktuelle Kantenauswahl.
    private func blendPlan(body: Int) -> BlendPlan? {
        let shape = bodies[body].shape
        let key = BlendPlacementKey(edges: selectedEdges, shape: ObjectIdentifier(shape),
                                    featureIDs: features.map(\.id))
        if let known = featureRecorder.blendPlacement, known.key == key { return known.plan }
        let plan = findBlendPlan(body: body, shape: shape)
        featureRecorder.blendPlacement = BlendPlacement(key: key, plan: plan)
        return plan
    }

    /// Darf eine Rundung im Verlauf vor diesen Schritt rücken? Nur vor Schritte, die Material abziehen oder neue
    /// Körper hinten anhängen – die Nummern der vorhandenen Körper bleiben dabei gleich.
    private static func blendMayPrecede(_ feature: Feature) -> Bool {
        if feature.isSuppressed { return true }
        switch feature.kind {
        case .extrude, .revolve:
            let mode = ExtrudeMode(rawValue: feature.data.mode ?? "") ?? .newBody
            return mode == .cut || mode == .newBody
        case .primitive:
            return true
        case .boolean:
            return feature.data.mode == BooleanKind.subtract.rawValue && feature.data.keepTools == true
        default:
            return false
        }
    }

    /// Körper vor dem Feature index (Zwischenstand-Speicher oder neu gerechnet).
    private func featureState(before index: Int) -> [SceneBody]? {
        guard index > 0 else { return [] }
        if let cached = featureRecorder.cache[features[index - 1].id] { return cached }
        var copy = features
        return runFeatures(&copy, from: index, until: index, sketches: sketches, values: variableValues)?.bodies
    }

    /// Ursprüngliche Kante der gewählten Stücke vor den Schnitten am Ende des Verlaufs (siehe oben).
    private func findBlendPlan(body: Int, shape: PCKShape) -> BlendPlan? {
        let list = features
        guard !list.isEmpty, PCKShape.kernelAvailable else { return nil }
        // Nur vor Schnitte bzw. neue Körper (z. B. nicht, wenn zuletzt abgerundet wurde): dann gar nicht erst das
        // Netz durchsuchen
        guard Self.blendMayPrecede(list[list.count - 1]) else { return nil }
        // Die Körper müssen der Stand nach dem letzten Feature sein
        if let last = featureRecorder.cache[list[list.count - 1].id],
           !(last.indices.contains(body) && last[body].shape === shape) { return nil }
        let pieces = selectedEdges.filter { $0.body == body }.map(\.edge)
        guard !pieces.isEmpty else { return nil }
        let trace = EdgeTrace(shape)
        var samples: [[SIMD3<Double>]] = []
        var directions: [SIMD3<Double>?] = []
        var pieceLength = 0.0
        for piece in pieces {
            let points = trace.samples(piece)
            guard !points.isEmpty else { return nil }
            samples.append(points)
            directions.append(Self.edgeSignature(shape, edge: piece, body: body)?.direction)
            pieceLength += shape.length(ofEdge: piece)
        }
        var best: BlendPlan?
        var bestLength = pieceLength
        var position = list.count
        var steps = 0
        var previousShape: PCKShape = shape
        while position > 0, steps < Self.blendSearchDepth {
            guard Self.blendMayPrecede(list[position - 1]) else { break }
            guard let earlier = featureState(before: position - 1), earlier.indices.contains(body) else { break }
            position -= 1
            steps += 1
            let earlierShape = earlier[body].shape
            // Schritt hat diesen Körper nicht verändert: nichts Neues
            if earlierShape === previousShape { continue }
            previousShape = earlierShape
            guard let match = Self.originalEdges(samples, directions: directions, in: earlierShape) else { break }
            let length = match.reduce(0.0) { $0 + earlierShape.length(ofEdge: $1) }
            guard length > bestLength + 0.01 else { continue }
            var signatures: [EdgeSignature] = []
            for edge in match {
                guard let signature = Self.edgeSignature(earlierShape, edge: edge, body: body) else { return best }
                signatures.append(signature)
            }
            best = BlendPlan(position: position, body: body, edges: match, signatures: signatures, shape: earlierShape)
            bestLength = length
        }
        return best
    }

    /// Je Kantenstück die Kante des früheren Körpers, auf der alle seine Punkte liegen (gleiche Richtung ins
    /// Material). nil, wenn ein Stück dort auf keiner Kante liegt (z. B. erst durch den Schnitt entstanden).
    private static func originalEdges(_ samples: [[SIMD3<Double>]], directions: [SIMD3<Double>?],
                                      in shape: PCKShape) -> [Int]? {
        let trace = EdgeTrace(shape)
        let tolerance = blendTraceTolerance
        var chosen: [Int] = []
        for (k, points) in samples.enumerated() {
            var best: (edge: Int, deviation: Double)?
            for edge in trace.segments.keys {
                let deviation = trace.deviation(of: points, from: edge, limit: tolerance)
                guard deviation <= tolerance, deviation < (best?.deviation ?? .infinity) else { continue }
                if let direction = directions[k],
                   let other = edgeSignature(shape, edge: edge, body: 0)?.direction,
                   simd_dot(direction, other) < 0.8 { continue }
                best = (edge, deviation)
            }
            guard let best else { return nil }
            if !chosen.contains(best.edge) { chosen.append(best.edge) }
        }
        return chosen.isEmpty ? nil : chosen
    }

    // MARK: Ineinanderlaufende Rundungen

    /// Grenzt die gewählte Kante an Kanten einer früheren Rundung (derselbe Körper; die letzte oder bis zu
    /// blendSearchDepth Schritte davor), wird beides in EINEM Abrunden gerechnet – wie in Fusion, wenn man Kanten
    /// zum vorhandenen Fillet-Feature hinzufügt („the selection set updates“), bzw. wie ein Fillet mit mehreren
    /// Kantensätzen („selection sets“) verschiedener Radien: OCCT rechnet alle Kanten einer Ecke gemeinsam
    /// (Rolling-Ball-Ecke, der Standard-Eckentyp in Fusion und Shapr3D), statt eine Rundung auf die schon
    /// gerundete Fläche zu setzen (das lief am Tangentenbogen der ersten Rundung weiter: Artefakte, Abbrüche).
    /// Liefert die zusammengefasste Rundung (ersetzt die frühere), den Körper davor und alle Kanten.
    func blendMerge(body: Int, value: Double, end: Double?) -> (feature: Feature, index: Int, shape: PCKShape,
                                                                   edges: [Int], radii: [Double]?)? {
        guard edgeOperation == .fillet, value.isFinite, value > 0,
              let geometry = blendMergeGeometry(body: body) else { return nil }
        let previous = features[geometry.index]
        guard let radius = previous.value("radius"), radius.isFinite, radius > 0 else { return nil }
        switch (previous.value("end"), end) {
        case (nil, nil):
            break
        case let (a?, b?) where abs(a - b) < 1e-6 && abs(radius - value) < 1e-6:
            break
        default:
            return nil
        }
        let oldKeys = previous.data.edgeRadiusKeys ?? Array(repeating: "radius", count: geometry.previousEdges.count)
        guard oldKeys.count == geometry.previousEdges.count else { return nil }
        var feature = previous
        feature.id = UUID()
        feature.failed = false
        feature.problem = nil
        feature.data.edges = (previous.data.edges ?? []) + geometry.signatures
        var keys = oldKeys
        if let same = feature.parameters.first(where: { abs($0.value - value) < 1e-6 && $0.key.hasPrefix("radius") }) {
            keys += Array(repeating: same.key, count: geometry.newEdges.count)
        } else {
            var number = 2
            while feature.parameters.contains(where: { $0.key == "radius\(number)" }) { number += 1 }
            let key = "radius\(number)"
            feature.parameters.append(.length(key, "Zusatzradius \(number - 1)", value))
            keys += Array(repeating: key, count: geometry.newEdges.count)
        }
        let values = keys.compactMap { feature.value($0) }
        guard values.count == keys.count else { return nil }
        feature.data.edgeRadiusKeys = Set(keys).count > 1 ? keys : nil
        featureRecorder.preBlendCandidate = (feature.id, body, geometry.shape)
        return (feature, geometry.index, geometry.shape, geometry.previousEdges + geometry.newEdges,
                feature.data.edgeRadiusKeys == nil ? nil : values)
    }

    /// Gemerkte bzw. neue Suche (je Kantenauswahl, Körper und Verlauf).
    private func blendMergeGeometry(body: Int) -> BlendMergeGeometry? {
        let shape = bodies[body].shape
        let key = BlendPlacementKey(edges: selectedEdges, shape: ObjectIdentifier(shape),
                                    featureIDs: features.map(\.id))
        if let known = featureRecorder.blendMerge, known.key == key { return known.geometry }
        let geometry = findBlendMerge(body: body, shape: shape)
        featureRecorder.blendMerge = BlendMergeMemo(key: key, geometry: geometry)
        return geometry
    }

    private func findBlendMerge(body: Int, shape: PCKShape) -> BlendMergeGeometry? {
        let list = features
        guard PCKShape.kernelAvailable, !list.isEmpty else { return nil }
        // Die Körper müssen der Stand nach dem letzten Feature sein
        if let after = featureRecorder.cache[list[list.count - 1].id],
           !(after.indices.contains(body) && after[body].shape === shape) { return nil }
        let pieces = selectedEdges.filter { $0.body == body }.map(\.edge)
        guard !pieces.isEmpty else { return nil }
        let trace = EdgeTrace(shape)
        var samples: [[SIMD3<Double>]] = []
        var directions: [SIMD3<Double>?] = []
        for piece in pieces {
            let points = trace.samples(piece)
            guard !points.isEmpty else { return nil }
            samples.append(points)
            directions.append(Self.edgeSignature(shape, edge: piece, body: body)?.direction)
        }
        // Rückwärts durch den Verlauf: die jüngste Rundung dieses Körpers, an deren Kanten die Auswahl grenzt.
        // Schritte dazwischen (andere Rundungen, Schnitte …) sind erlaubt, solange die gewählten Stücke vor der
        // Rundung schon auf einer Kante lagen (originalEdges); sonst lohnt weiter zurück nichts.
        var index = list.count - 1
        var steps = 0
        while index >= 0, steps < Self.blendSearchDepth {
            let previous = list[index]
            let current = index
            index -= 1
            steps += 1
            // Ein Snapshot speichert einen festen Körperstand. Ein Nachbau vor ihm
            // würde die neue Rundung beim Abspielen wieder überschreiben.
            if previous.kind == .snapshot { return nil }
            guard previous.kind == .fillet, !previous.isSuppressed, !previous.failed,
                  let signatures = previous.data.edges, let first = signatures.first,
                  (previous.data.target ?? first.body) == body else { continue }
            let earlier: PCKShape
            if current == list.count - 1, let saved = featureRecorder.preBlendShape,
               saved.featureID == previous.id, saved.body == body {
                earlier = saved.shape
            } else {
                guard let before = featureState(before: current), before.indices.contains(body) else { return nil }
                earlier = before[body].shape
            }
            guard let previousEdges = try? Self.matchEdges(signatures, in: earlier), !previousEdges.isEmpty else { continue }
            // Wo lagen die gewählten Stücke vor dieser Rundung? (Die Rundung kürzt die Nachbarkante nur.)
            // Gar nicht (erst danach entstanden) bzw. Teil dieser Rundung selbst: keine Zusammenfassung
            guard let newEdges = Self.originalEdges(samples, directions: directions, in: earlier),
                  !newEdges.contains(where: { previousEdges.contains($0) }) else { return nil }
            // Grenzen sie an eine Kante dieser Rundung (gemeinsamer Eckpunkt)?
            let earlierTrace = EdgeTrace(earlier)
            let previousPoints = previousEdges.flatMap { earlierTrace.samples($0) }
            let touches = newEdges.contains { edge in
                earlierTrace.samples(edge).contains { point in
                    previousPoints.contains { simd_distance($0, point) < 1e-3 }
                }
            }
            guard touches else { continue }
            var newSignatures: [EdgeSignature] = []
            for edge in newEdges {
                guard let signature = Self.edgeSignature(earlier, edge: edge, body: body) else { return nil }
                newSignatures.append(signature)
            }
            return BlendMergeGeometry(index: current, shape: earlier, previousEdges: previousEdges, newEdges: newEdges,
                                      signatures: newSignatures)
        }
        return nil
    }

    // MARK: Zusammenfassen mit einer früheren Rundung (nicht der letzten): Nachbau ab dort

    /// setEdgeValue: Grenzt die Auswahl an eine frühere Rundung, die nicht das letzte Feature ist, wird sie dort
    /// als weiterer Kantensatz eingetragen und der Verlauf ab dieser Rundung neu gerechnet.
    /// true = diese Anfrage wird hier bearbeitet; eine direkte Teilrundung ist dann kein Ersatz.
    func previewMergedBlend(body: Int, value: Double) -> Bool {
        guard edgeOperation == .fillet, edgePartialRange == nil, value > 0, bodies.indices.contains(body) else { return false }
        let key = currentOrderedKey(value: value)
        guard let merge = blendMerge(body: body, value: value, end: key.end),
              merge.index < features.count - 1 else { return false }
        if let known = featureRecorder.blendMerge?.succeeded[key] {
            showMergedBlend(known, index: merge.index)
            return true
        }
        if featureRecorder.blendMerge?.failed.contains(key) ?? false {
            dropPreview()
            message = "Gemeinsame Rundung an dieser Ecke mit diesem Radius nicht möglich."
            return true
        }
        guard !blendJobs.overdue else {
            dropPreview()
            message = Self.blendTooHeavyMessage
            return true
        }
        blendJobs.orderedToken += 1
        let token = blendJobs.orderedToken
        let generation = blendJobs.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.orderedDelay) { [weak self] in
            guard let self, self.blendJobs.orderedToken == token, self.blendJobs.generation == generation else { return }
            self.runMergedBlend(body: body, key: key)
        }
        message = "Gemeinsame Rundung wird berechnet …"
        return true
    }

    /// Entprellter Nachbau: features[merge.index] durch die zusammengefasste Rundung ersetzen, ab dort neu rechnen.
    private func runMergedBlend(body: Int, key: OrderedAttemptKey) {
        guard bodies.indices.contains(body), edgeOperation == .fillet, currentOrderedKey(value: edgeValue) == key,
              let merge = blendMerge(body: body, value: key.value, end: key.end),
              features.indices.contains(merge.index) else { return }
        var list = features
        let failedBefore = list.map(\.failed)
        list[merge.index] = merge.feature
        var states: [UUID: [SceneBody]] = [:]
        var outcome: OrderedAttempt?
        if let run = runFeatures(&list, from: merge.index, sketches: sketches, values: variableValues,
                                 collect: { id, state in states[id] = state }),
           !list[merge.index].failed, run.bodies.count == bodies.count,
           !list.indices.contains(where: { $0 > merge.index && list[$0].failed && !failedBefore[$0] }) {
            outcome = OrderedAttempt(bodies: carryingBodyDetails(run.bodies), features: list, states: states,
                                     amount: key.value)
        }
        guard let outcome else {
            featureRecorder.blendMerge?.failed.insert(key)
            dropPreview()
            message = "Gemeinsame Rundung an dieser Ecke mit diesem Radius nicht möglich."
            return
        }
        if (featureRecorder.blendMerge?.succeeded.count ?? 0) >= 4 { featureRecorder.blendMerge?.succeeded = [:] }
        featureRecorder.blendMerge?.succeeded[key] = outcome
        // Die gemeinsame Rundung hat Vorrang: direkte Vorschau aus dem Hintergrund verwerfen
        supersedeBlendJobs()
        showMergedBlend(outcome, index: merge.index)
        blendJobs.finished?()
    }

    private func showMergedBlend(_ attempt: OrderedAttempt, index: Int) {
        guard let body = selectedEdges.first?.body, bodies.indices.contains(body),
              attempt.features.indices.contains(index) else { return }
        previewHiddenSketch = bodies[body].sketchID
        showPreview(attempt.bodies, name: attempt.features[index].name)
        // Nach showPreview (das die Aufzeichnung leert): beim Übernehmen gilt die geänderte Liste
        featureRecorder.orderedPreview = OrderedBlendPreview(features: attempt.features, states: attempt.states)
        let later = features.count - 1 - index
        message = "Zu „\(features[index].name)“ (Schritt \(index + 1)) als weiterer Kantensatz hinzugefügt, "
            + "\(later) spätere\(later == 1 ? "r Schritt" : " Schritte") neu gerechnet – die Rundungen laufen in der Ecke sauber ineinander."
    }

    // MARK: Rückfall: alle Teilstücke einer geraden Kante

    /// Gewählte Kanten samt den übrigen Teilstücken derselben geraden Kante: gerade, auf derselben Linie und
    /// zwischen denselben zwei Flächen (eine Tasche hat die Kante unterbrochen). So wird die Kante ganz verrundet
    /// statt nur stückweise.
    func completedEdgeChain(_ selected: [EdgeRef], body: Int) -> [EdgeRef] {
        guard bodies.indices.contains(body), PCKShape.kernelAvailable else { return selected }
        let shape = bodies[body].shape
        let own = selected.filter { $0.body == body }
        guard !own.isEmpty else { return selected }
        // Kante → ihre Flächen
        var facesOfEdge: [Int: [Int]] = [:]
        let faceCount = shape.faceCount
        guard faceCount > 0, faceCount < 5000 else { return selected }
        for face in 1...faceCount {
            for number in shape.edgeNumbers(ofFace: face).map(\.intValue) {
                facesOfEdge[number, default: []].append(face)
            }
        }
        func line(_ edge: Int) -> (a: SIMD3<Double>, b: SIMD3<Double>)? {
            guard let g = shape.geometry(ofEdge: edge)?.map(\.doubleValue), g.count >= 8, g[0] == 0 else { return nil }
            return (SIMD3<Double>(g[2], g[3], g[4]), SIMD3<Double>(g[5], g[6], g[7]))
        }
        var result = selected
        for ref in own {
            guard let base = line(ref.edge), simd_distance(base.a, base.b) > 1e-6,
                  let faces = facesOfEdge[ref.edge], faces.count == 2 else { continue }
            let axis = simd_normalize(base.b - base.a)
            let pair = Set(faces)
            for (edge, others) in facesOfEdge where edge != ref.edge && Set(others) == pair {
                guard !result.contains(EdgeRef(body: body, edge: edge)), let other = line(edge) else { continue }
                // Auf derselben Geraden?
                let offA = simd_length(simd_cross(other.a - base.a, axis))
                let offB = simd_length(simd_cross(other.b - base.a, axis))
                guard offA < 1e-4, offB < 1e-4 else { continue }
                result.append(EdgeRef(body: body, edge: edge))
            }
        }
        return result
    }
}
