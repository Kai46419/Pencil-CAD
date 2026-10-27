import Foundation
import simd

// Abrunden/Fasen im Hintergrund (Kai: „variable Abrundung – jetzt ist mir das Programm eingefroren“).
//
// Ursache: setEdgeValue rief BRepFilletAPI_MakeFillet synchron auf dem Main-Thread auf, bei jedem Wert (Pfeil-Frame,
// Eintippen, „Variabel“ ein, Endradius) – und EdgeBlendCommand.refresh rechnete beim Ändern des Endradius sogar
// zweimal. Läuft eine variable Rundung in eine schon verrundete Nachbarkante (Eckübergang auf eine B-Spline-
// Rundungsfläche), rechnet OCCT dort Minuten oder kehrt nie zurück; OCCT 7.7 kann eine Rundung nicht abbrechen
// (BRepFilletAPI_MakeFillet::Build ignoriert Message_ProgressRange).
//
// Jetzt:
// - Gemerkt: Ergebnisse und Fehlschläge je Körper, Kanten, Werten und Verlauf – derselbe Wert rechnet nie zweimal.
// - Hintergrund: eine serielle Warteschlange, an einer unabhängigen Kopie des Körpers (PCKShape.independentCopy;
//   Vernetzen im Vordergrund schreibt sonst in dieselben OCCT-Flächen/Kanten). Es rechnet immer höchstens eine
//   Rundung; neue Werte warten (nur der neueste), alte Ergebnisse werden verworfen (generation).
// - Zeitlimit 8 s: Meldung „zu aufwendig“, Vorschau verworfen, Werte als Fehlschlag gemerkt. Der hängende Aufruf läuft
//   weiter, bis OCCT zurückkehrt; bis dahin startet nichts Neues (nicht parallel stapeln), die App bleibt bedienbar.
// - Ineinanderlaufende Rundungen (BlendBeforeCuts.swift blendMerge): mit der vorigen Rundung in EINEM Abrunden.
// - Variable Rundung: Radien ≥ 0,01 mm, Anfang = Ende → gleichbleibende Rundung, Radius größer als die angrenzende
//   Fläche breit ist → gleich abgelehnt (ohne OCCT).

/// Ergebnis einer Rundung bzw. Fase aus dem Hintergrund.
struct BlendJobResult {
    /// Neuer Körper; nil = nicht möglich
    var shape: PCKShape?
    /// Tatsächlich verwendeter Wert (kleiner als gewünscht, wenn nur der größte mögliche Wert ging)
    var amount: Double
    /// Gefundener größter Wert (gleichbleibende Rundung bzw. Fase)
    var limit: Double?
    /// Mit der vorigen Rundung zusammengefasst
    var merged = false
    /// Zeitlimit überschritten
    var timedOut = false
}

/// Eingaben für den Hintergrund: nur Kopien und Zahlen, nichts aus dem Vordergrund.
struct BlendJobInput {
    var operation: EdgeOperation
    /// Unabhängige Kopie des Körpers
    var shape: PCKShape
    var edges: [NSNumber]
    var value: Double
    var second: Double?
    var end: Double?
    /// Bekannter größter Wert (nil = unbekannt)
    var knownLimit: Double?
    /// Gemeinsam mit der vorigen Rundung: Körper vor ihr (Kopie) und alle Kanten
    var mergeShape: PCKShape?
    var mergeEdges: [NSNumber] = []
}

struct BlendJobKey: Equatable {
    var edges: [EdgeRef]
    var operation: EdgeOperation
    var value: Double
    var second: Double?
    var end: Double?
    var featureIDs: [UUID]
}

/// Eine Anfrage (Vorschau für einen Wert).
struct BlendJobRequest {
    var key: BlendJobKey
    var generation: Int
    var body: Int
    /// Körper beim Start (nur zum Prüfen beim Zurückkommen; gerechnet wird an input.shape)
    var source: PCKShape
    var selection: [EdgeRef]
    var blendEdges: [EdgeRef]
    var input: BlendJobInput
    /// Zusammengefasste Rundung (ersetzt features[mergeIndex])
    var mergeFeature: Feature?
    var mergeIndex: Int?
}

/// Zustand der Hintergrund-Rundung (ModelStore.blendJobs, nicht veröffentlicht).
final class BlendJobs {
    /// Zählt jede neue Anfrage; ältere Ergebnisse werden verworfen
    var generation = 0
    /// Laufende Anfrage (auch nach dem Zeitlimit, bis OCCT zurückkehrt)
    var current: BlendJobRequest?
    var jobNumber = 0
    /// Die laufende Anfrage hat das Zeitlimit überschritten (ihr Ergebnis wird ignoriert)
    var overdue = false
    /// Nächste Anfrage (nur die neueste); startet, sobald die laufende zurück ist
    var queued: BlendJobRequest?
    /// Ergebnisse je Anfrage (auch Fehlschläge), die neuesten hinten
    var memo: [(key: BlendJobKey, source: PCKShape, result: BlendJobResult)] = []
    /// Breite der angrenzenden Flächen (variable Rundung), gemerkt je Körper und Kanten
    var width: (source: PCKShape, edges: [Int], value: Double?)?
    /// Entprellen „Rundung vor Schnitt“ (BlendBeforeCuts.swift)
    var orderedToken = 0
    /// Nach jedem angekommenen Ergebnis (offenes Abrunden-/Fasen-Panel aktualisieren)
    var finished: (() -> Void)?
    let queue = DispatchQueue(label: "PencilCAD.blend", qos: .userInitiated)

    var running: Bool { current != nil }

    static let timeLimit = 8.0
    static let memoLimit = 24
}

/// Rechnen im Hintergrund (nur Kernel-Aufrufe an Kopien, kein Zugriff auf den ModelStore).
enum BlendKernel {
    static func run(_ input: BlendJobInput) -> BlendJobResult {
        let value = input.value
        if input.operation == .fillet, let mergeShape = input.mergeShape, !input.mergeEdges.isEmpty {
            let merged: PCKShape?
            if let end = input.end {
                merged = mergeShape.filleting(edges: input.mergeEdges, radius: value, endRadius: end)
            } else {
                merged = mergeShape.filleting(edges: input.mergeEdges, radius: value)
            }
            if let merged { return BlendJobResult(shape: merged, amount: value, limit: nil, merged: true) }
        }
        let shape = input.shape
        let numbers = input.edges
        if input.operation == .fillet, let end = input.end {
            return BlendJobResult(shape: shape.filleting(edges: numbers, radius: value, endRadius: end), amount: value,
                                  limit: nil)
        }
        if input.operation == .chamfer, let second = input.second {
            return BlendJobResult(shape: shape.chamfering(edges: numbers, distance: value, distance2: second),
                                  amount: value, limit: nil)
        }
        let chamfer = input.operation == .chamfer
        func blend(_ amount: Double) -> PCKShape? {
            chamfer ? shape.chamfering(edges: numbers, distance: amount) : shape.filleting(edges: numbers, radius: amount)
        }
        // Zu groß: nicht einfach nichts zeigen, sondern den größten möglichen Wert (höchstens 8 Versuche)
        if let limit = input.knownLimit, value > limit {
            return BlendJobResult(shape: limit > 0 ? blend(limit) : nil, amount: limit, limit: limit)
        }
        if let result = blend(value) {
            return BlendJobResult(shape: result, amount: value, limit: input.knownLimit)
        }
        let found = shape.maximumBlend(edges: numbers, upTo: value, chamfer: chamfer)
        let limit = (found * 100).rounded(.down) / 100
        return BlendJobResult(shape: limit > 0 ? blend(limit) : nil, amount: limit, limit: limit)
    }
}

/// Abstand Punkt–Strecke.
private func blendSegmentDistance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let ab: SIMD3<Double> = b - a
    let lengthSquared = simd_length_squared(ab)
    guard lengthSquared > 1e-18 else { return simd_distance(p, a) }
    let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
    let foot: SIMD3<Double> = a + ab * t
    return simd_distance(p, foot)
}

extension ModelStore {
    static let blendTooHeavyMessage = "Rundung zu aufwendig bzw. nicht möglich – Radius verkleinern."

    /// setEdgeValue: neue Anfrage – noch laufende bzw. wartende Ergebnisse gelten nicht mehr.
    func beginBlendRequest() {
        blendJobs.generation += 1
        blendJobs.queued = nil
        blendJobs.orderedToken += 1
        if isBlendComputing { isBlendComputing = false }
    }

    /// Ein anderes Ergebnis (Rundung vor Schnitt) hat Vorrang: Hintergrund-Ergebnis verwerfen.
    func supersedeBlendJobs() {
        blendJobs.generation += 1
        blendJobs.queued = nil
        if isBlendComputing { isBlendComputing = false }
    }

    /// Auswahl aufgehoben bzw. Vorschau abgebrochen: nichts mehr zeigen, was noch rechnet.
    func cancelBlendJobs() {
        supersedeBlendJobs()
        blendJobs.orderedToken += 1
    }

    /// Rundung bzw. Fase der gewählten Kanten rechnen (gemerkt sofort, sonst im Hintergrund).
    func requestBlend(body: Int, value requested: Double, blendEdges: [EdgeRef]) {
        let operation = edgeOperation
        let second: Double? = operation == .chamfer ? edgeSecondValue : nil
        var end: Double? = operation == .fillet ? edgeEndValue : nil
        var value = requested
        if let given = end {
            // Variable Rundung: Radien ab 0,01 mm; Anfang = Ende ist eine gleichbleibende Rundung
            value = max(0.01, value)
            let clamped = max(0.01, given)
            end = abs(clamped - value) < 1e-6 ? nil : clamped
        }
        let shape = bodies[body].shape
        let key = BlendJobKey(edges: blendEdges, operation: operation, value: value, second: second, end: end,
                              featureIDs: features.map(\.id))
        let numbers = blendEdges.filter { $0.body == body }.map { NSNumber(value: $0.edge) }
        let merge = operation == .fillet ? blendMerge(body: body, value: value, end: end) : nil
        let knownLimit: Double? = {
            guard end == nil, second == nil, let limit = edgeLimit,
                  limit.key == EdgeLimitKey(edges: blendEdges, operation: operation, shape: ObjectIdentifier(shape))
            else { return nil }
            return limit.value
        }()
        let input = BlendJobInput(operation: operation, shape: shape, edges: numbers, value: value, second: second,
                                  end: end, knownLimit: knownLimit, mergeShape: merge?.shape,
                                  mergeEdges: (merge?.edges ?? []).map { NSNumber(value: $0) })
        let request = BlendJobRequest(key: key, generation: blendJobs.generation, body: body, source: shape,
                                      selection: selectedEdges, blendEdges: blendEdges, input: input,
                                      mergeFeature: merge?.feature, mergeIndex: merge?.index)
        // Schon gerechnet (auch Fehlschlag bzw. Zeitlimit): sofort
        if let known = blendJobs.memo.last(where: { $0.key == key && $0.source === shape }) {
            applyBlendResult(known.result, request: request)
            return
        }
        // Variable Rundung breiter als die angrenzende Fläche: OCCT gar nicht erst fragen (hängt dort oft)
        if let end, merge == nil, let width = adjacentFaceWidth(shape, edges: numbers.map(\.intValue)),
           max(value, end) > width * 1.02 + 0.01 {
            message = "Variable Rundung: \(max(value, end).formatted()) mm ist breiter als die angrenzende Fläche "
                + "(ca. \(((width * 10).rounded(.down) / 10).formatted()) mm) – Radius verkleinern."
            dropPreview()
            blendJobs.finished?()
            return
        }
        // Läuft schon dieselbe Rechnung: übernehmen statt noch einmal
        if let current = blendJobs.current, current.key == key, current.source === shape {
            if blendJobs.overdue {
                message = Self.blendTooHeavyMessage
                dropPreview()
                return
            }
            blendJobs.current?.generation = blendJobs.generation
            isBlendComputing = true
            return
        }
        isBlendComputing = true
        if blendJobs.running {
            // Nicht parallel stapeln: wartet, bis die laufende Rundung zurück ist (nur die neueste)
            blendJobs.queued = request
            if blendJobs.overdue {
                message = "Die vorige Rundung rechnet noch (zu aufwendig) – der neue Wert folgt, sobald sie fertig ist."
            }
            return
        }
        startBlendJob(request)
    }

    private func startBlendJob(_ request: BlendJobRequest) {
        let jobs = blendJobs
        jobs.current = request
        jobs.overdue = false
        jobs.jobNumber += 1
        let number = jobs.jobNumber
        isBlendComputing = true
        // Hänger-Marke (HangGuard.swift): Vorschau-Feature, das nie im gespeicherten Verlauf steht – nach einem Absturz
        // öffnet das Projekt normal (das Feature wurde nie übernommen)
        let marker = request.mergeFeature ?? Self.blendFeature(request.input.operation, value: request.input.value,
                                                               second: request.input.second, end: request.input.end)
        HangGuard.willRun(marker, in: folder)
        // Im Hintergrund nur an unabhängigen Kopien rechnen (die Kopie kostet Millisekunden; erst hier, damit beim
        // Ziehen wartende Anfragen nicht jedes Mal kopieren; scheitert sie, am Original)
        var input = request.input
        input.shape = input.shape.independentCopy() ?? input.shape
        if let mergeShape = input.mergeShape { input.mergeShape = mergeShape.independentCopy() ?? mergeShape }
        let box = UncheckedBox(input)
        jobs.queue.async {
            let result = BlendKernel.run(box.value)
            let out = UncheckedBox(result)
            Task { @MainActor [weak self] in
                self?.blendJobReturned(out.value, number: number)
            }
        }
        // Erst nach einer Weile melden (kurze Rechnungen ohne Flackern)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.blendJobs.jobNumber == number, let current = self.blendJobs.current,
                  !self.blendJobs.overdue, current.generation == self.blendJobs.generation else { return }
            self.message = "\(current.input.operation == .fillet ? "Rundung" : "Fase") wird berechnet …"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BlendJobs.timeLimit) { [weak self] in
            self?.blendJobTimedOut(number)
        }
    }

    private func blendJobTimedOut(_ number: Int) {
        let jobs = blendJobs
        guard jobs.jobNumber == number, let current = jobs.current, !jobs.overdue else { return }
        jobs.overdue = true
        // Dieselben Werte nicht noch einmal starten
        rememberBlend(current, BlendJobResult(shape: nil, amount: current.input.value, limit: nil, timedOut: true))
        guard isCurrentBlend(current) else { return }
        message = Self.blendTooHeavyMessage
        dropPreview()
        isBlendComputing = jobs.queued != nil
        jobs.finished?()
    }

    private func blendJobReturned(_ result: BlendJobResult, number: Int) {
        let jobs = blendJobs
        guard jobs.jobNumber == number, let request = jobs.current else { return }
        HangGuard.didRun(in: folder)
        let wasOverdue = jobs.overdue
        jobs.current = nil
        jobs.overdue = false
        // Nach dem Zeitlimit: Ergebnis ignorieren (gemerkt ist es schon als Fehlschlag)
        if !wasOverdue { rememberBlend(request, result) }
        if let next = jobs.queued {
            jobs.queued = nil
            if isCurrentBlend(next) {
                startBlendJob(next)
            } else {
                isBlendComputing = false
            }
        } else {
            isBlendComputing = false
        }
        if !wasOverdue, isCurrentBlend(request) { applyBlendResult(result, request: request) }
        jobs.finished?()
    }

    private func rememberBlend(_ request: BlendJobRequest, _ result: BlendJobResult) {
        var memo = blendJobs.memo
        memo.removeAll { $0.key == request.key && $0.source === request.source }
        memo.append((key: request.key, source: request.source, result: result))
        if memo.count > BlendJobs.memoLimit { memo.removeFirst(memo.count - BlendJobs.memoLimit) }
        blendJobs.memo = memo
        if let limit = result.limit, request.key.end == nil, request.key.second == nil {
            edgeLimit = (EdgeLimitKey(edges: request.blendEdges, operation: request.key.operation,
                                      shape: ObjectIdentifier(request.source)), limit)
        }
    }

    /// Gilt die Anfrage noch (keine neuere, gleicher Körper, gleiche Auswahl)?
    private func isCurrentBlend(_ request: BlendJobRequest) -> Bool {
        request.generation == blendJobs.generation && bodies.indices.contains(request.body)
            && bodies[request.body].shape === request.source && selectedEdges == request.selection
            && edgeOperation == request.key.operation
    }

    /// Ergebnis als Vorschau zeigen bzw. melden, warum es nicht geht.
    private func applyBlendResult(_ result: BlendJobResult, request: BlendJobRequest) {
        let body = request.body
        let input = request.input
        let operation = input.operation
        guard let shape = result.shape else {
            if result.timedOut {
                message = Self.blendTooHeavyMessage
            } else if let end = input.end {
                message = "Rundung \(input.value.formatted()) → \(end.formatted()) mm an dieser Kante nicht möglich."
            } else if let second = input.second {
                message = "Fase \(input.value.formatted()) × \(second.formatted()) mm an dieser Kante nicht möglich."
            } else {
                message = "\(operation.rawValue) an dieser Kante nicht möglich."
            }
            dropPreview()
            return
        }
        var preview = bodies
        preview[body] = preview[body].with(shape)
        previewHiddenSketch = bodies[body].sketchID
        let name = operation == .fillet && input.end != nil ? "Variabel abrunden" : operation.rawValue
        showPreview(preview, name: name)
        if result.merged, let feature = request.mergeFeature, let index = request.mergeIndex,
           features.indices.contains(index) {
            // Beim Übernehmen ersetzt die gemeinsame Rundung die vorige (nach showPreview, das die Aufzeichnung leert)
            var list = features
            let previousName = list[index].name
            list[index] = feature
            featureRecorder.orderedPreview = OrderedBlendPreview(features: list, states: [feature.id: preview])
            message = "Mit „\(previousName)“ zu einer Rundung zusammengefasst – die Ecke läuft sauber ineinander."
            return
        }
        message = result.amount < input.value - 1e-9
            ? "\(operation.rawValue): größter möglicher Wert hier \(result.amount.formatted()) mm." : nil
        noteBlend(operation, value: result.amount, second: input.second, end: input.end, edges: request.blendEdges)
    }

    /// Grobe Breite der schmalsten an die Kanten grenzenden Fläche (größter Abstand ihrer Netzpunkte zur Kante).
    /// nil = unbekannt. Gemerkt je Körper und Kanten.
    func adjacentFaceWidth(_ shape: PCKShape, edges: [Int]) -> Double? {
        if let known = blendJobs.width, known.source === shape, known.edges == edges { return known.value }
        let value = measureAdjacentFaceWidth(shape, edges: edges)
        blendJobs.width = (shape, edges, value)
        return value
    }

    private func measureAdjacentFaceWidth(_ shape: PCKShape, edges: [Int]) -> Double? {
        let faceCount = shape.faceCount
        guard !edges.isEmpty, faceCount > 0, faceCount < 3000 else { return nil }
        let wanted = Set(edges)
        var facesOfEdge: [Int: Set<Int>] = [:]
        for face in 1...faceCount {
            for number in shape.edgeNumbers(ofFace: face).map(\.intValue) where wanted.contains(number) {
                facesOfEdge[number, default: []].insert(face)
            }
        }
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        var segments: [Int: [(SIMD3<Double>, SIMD3<Double>)]] = [:]
        for (i, ref) in mesh.edgeRefs.enumerated() where wanted.contains(ref.edge) && i * 2 + 1 < mesh.edges.count {
            segments[ref.edge, default: []].append((SIMD3<Double>(mesh.edges[i * 2]), SIMD3<Double>(mesh.edges[i * 2 + 1])))
        }
        var narrowest: Double?
        for edge in edges {
            guard let list = segments[edge], !list.isEmpty, let faces = facesOfEdge[edge] else { continue }
            for face in faces {
                let points = mesh.trianglePoints(of: FaceRef(body: 0, face: face))
                guard !points.isEmpty else { continue }
                let step = max(1, points.count / 1500)
                var widest = 0.0
                var k = 0
                while k < points.count {
                    let p = SIMD3<Double>(points[k])
                    var nearest = Double.infinity
                    for segment in list { nearest = min(nearest, blendSegmentDistance(p, segment.0, segment.1)) }
                    widest = max(widest, nearest)
                    k += step
                }
                if widest > 1e-6 { narrowest = min(narrowest ?? .infinity, widest) }
            }
        }
        return narrowest
    }
}
