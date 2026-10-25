import Foundation
import Security
import simd
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: Plan

/// Ein Schritt, den die KI plant. Maße in mm, Winkel in Grad. Körper: 0 = Ergebnis des vorigen Schritts
/// (bzw. gewählter Körper), n = Körper n aus der Szenenliste; neue Körper bekommen die folgenden Nummern.
struct AIStep: Codable, Equatable {
    var op: String
    var body: Int?
    var target: Int?
    var x: Double?
    var y: Double?
    var z: Double?
    var width: Double?
    var depth: Double?
    var height: Double?
    var diameter: Double?
    var value: Double?
    var edges: String?
    var face: String?
    var axis: String?
    var degrees: Double?
    var countX: Int?
    var spacingX: Double?
    var countY: Int?
    var spacingY: Double?

    static let operations = ["quader", "zylinder", "kugel", "kegel", "abrunden", "fase", "bohrung", "verschieben",
                             "drehen", "muster", "vereinigen", "abziehen", "schale", "loeschen"]

    /// Kurzbeschreibung für die Schrittliste.
    var label: String {
        func mm(_ value: Double?) -> String { (value ?? 0).formatted(.number.precision(.fractionLength(0...2))) }
        let on = body.map { $0 > 0 ? " an Körper \($0)" : "" } ?? ""
        switch op {
        case "quader": return "Quader \(mm(width)) × \(mm(depth)) × \(mm(height)) mm"
        case "zylinder": return "Zylinder Ø \(mm(diameter)) × \(mm(height)) mm"
        case "kugel": return "Kugel Ø \(mm(diameter)) mm"
        case "kegel": return "Kegel Ø \(mm(diameter)) × \(mm(height)) mm"
        case "abrunden": return "Abrunden R \(mm(value)) mm, Kanten \(edges ?? "alle")\(on)"
        case "fase": return "Fase \(mm(value)) mm, Kanten \(edges ?? "alle")\(on)"
        case "bohrung":
            let through = (height ?? 0) > 0 ? "\(mm(height)) mm tief" : "durchgehend"
            return "Bohrung Ø \(mm(diameter)) mm, \(through), Fläche \(face ?? "oben")\(on)"
        case "verschieben": return "Verschieben um \(mm(x)) / \(mm(y)) / \(mm(z)) mm\(on)"
        case "drehen": return "Drehen um \(axis ?? "z") \(Int((degrees ?? 0).rounded()))°\(on)"
        case "muster":
            return "Muster \(countX ?? 1) × \(countY ?? 1), Abstand \(mm(spacingX)) / \(mm(spacingY)) mm\(on)"
        case "vereinigen": return "Vereinigen mit Körper \(target ?? 0)\(on)"
        case "abziehen": return "Körper \(target ?? 0) abziehen\(on)"
        case "schale": return "Schale \(mm(value)) mm, offen \(face ?? "oben")\(on)"
        case "loeschen": return "Löschen\(on)"
        default: return op
        }
    }
}

struct AIPlan: Codable, Equatable {
    var summary: String
    var steps: [AIStep]
    /// Rückfrage, wenn der Auftrag ohne Angaben nicht sinnvoll umsetzbar ist
    var question: String?
}

struct AIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: Assistent

/// KI-Anbindung: Auftrag in Worten → Plan (Apple on-device oder Claude) → Vorschau → Übernehmen oder Verwerfen.
@MainActor
final class AIAssistant: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "Automatisch"
        case local = "Nur Apple (auf dem Gerät)"
        case claude = "Nur Claude"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case idle
        case working(String)
        case ready(AIPlan, String)
        case question(String)
        case failed(String)
    }

    @Published var input = ""
    @Published var isOpen = false
    @Published private(set) var state: State = .idle
    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "ai.mode") }
    }
    @Published private(set) var hasKey = false

    /// Wird nach einer neuen Vorschau aufgerufen (Ansicht einpassen)
    var onPreview: (() -> Void)?

    private let model: ModelStore
    private var task: Task<Void, Never>?

    init(model: ModelStore) {
        self.model = model
        mode = UserDefaults.standard.string(forKey: "ai.mode").flatMap(Mode.init(rawValue:)) ?? .auto
        hasKey = Keychain.read() != nil
    }

    static var localAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return LocalPlanner.isAvailable }
        #endif
        return false
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    // MARK: Schlüssel

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete()
        } else {
            Keychain.save(trimmed)
        }
        hasKey = Keychain.read() != nil
    }

    func deleteKey() {
        Keychain.delete()
        hasKey = false
    }

    // MARK: Ablauf

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        guard PCKShape.kernelAvailable else {
            state = .failed("Die KI-Anbindung braucht OpenCASCADE (siehe README).")
            return
        }
        if case .ready = state { model.cancelPreview() }
        task?.cancel()
        task = Task { await run(text) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .ready = state { model.cancelPreview() }
        state = .idle
    }

    func accept() {
        guard case .ready = state else { return }
        model.commitPreview()
        state = .idle
        input = ""
    }

    func discard() {
        guard case .ready = state else { return }
        model.cancelPreview()
        state = .idle
    }

    private func run(_ text: String) async {
        let context = sceneContext()
        let prompt = "Szene:\n\(context)\n\nAuftrag: \(text)"
        let local = Self.localAvailable
        var order: [String] = []
        switch mode {
        case .local:
            order = ["apple"]
        case .claude:
            order = ["claude"]
        case .auto:
            if local && Self.isSimple(text) { order.append("apple") }
            if hasKey { order.append("claude") }
            if order.isEmpty && local { order.append("apple") }
        }
        guard !order.isEmpty else {
            state = .failed(local ? "Kein API-Schlüssel für Claude hinterlegt (Zahnrad)."
                : "Apple Intelligence ist hier nicht verfügbar und kein Claude-Schlüssel hinterlegt (Zahnrad).")
            return
        }
        var lastError = "Unbekannter Fehler."
        for source in order {
            let name = source == "apple" ? "Apple (auf dem Gerät)" : "Claude"
            state = .working(name)
            do {
                let plan = source == "apple" ? try await planLocally(prompt) : try await ClaudeClient.plan(prompt)
                if Task.isCancelled { return }
                if plan.steps.isEmpty {
                    if let question = plan.question, !question.isEmpty {
                        state = .question(question)
                        return
                    }
                    throw AIError("Die KI hat keine Schritte geplant.")
                }
                var executor = AIPlanExecutor(bodies: model.bodies, current: model.selectedBody)
                let result = try executor.run(plan.steps)
                let title = plan.summary.isEmpty ? "KI" : "KI: \(plan.summary.prefix(40))"
                model.showPlanPreview(result, name: title)
                state = .ready(plan, name)
                onPreview?()
                return
            } catch {
                if Task.isCancelled { return }
                lastError = "\(name): \(error.localizedDescription)"
            }
        }
        state = .failed(lastError)
    }

    private func planLocally(_ prompt: String) async throws -> AIPlan {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await LocalPlanner.plan(prompt: prompt)
        }
        #endif
        throw AIError("Apple Intelligence ist auf diesem Gerät nicht verfügbar.")
    }

    /// Einfacher Auftrag: höchstens zwei Operationen, kurz → zuerst lokal.
    static func isSimple(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["quader", "würfel", "wuerfel", "zylinder", "kugel", "kegel", "rund", "fase", "schräg",
                        "bohr", "loch", "versch", "dreh", "muster", "reihe", "vereinig", "abzieh", "schale", "lösch"]
        let hits = keywords.filter { lower.contains($0) }.count
        return hits <= 2 && text.count <= 140
    }

    /// Körperliste mit Maßen für die KI.
    private func sceneContext() -> String {
        guard !model.bodies.isEmpty else { return "(leer, noch keine Körper)" }
        func mm(_ value: Float) -> String { Double(value).formatted(.number.precision(.fractionLength(0...1))) }
        var lines: [String] = []
        for (index, body) in model.bodies.enumerated() {
            let mesh = Mesh(body.shape.triangulate(deflection: 0.1), body: index)
            var line = "Körper \(index + 1): \(body.name)"
            if let b = mesh.bounds {
                let size = b.max - b.min
                line += ", Größe \(mm(size.x)) × \(mm(size.y)) × \(mm(size.z)) mm, von (\(mm(b.min.x)), \(mm(b.min.y)), \(mm(b.min.z)))"
                line += " bis (\(mm(b.max.x)), \(mm(b.max.y)), \(mm(b.max.z)))"
            }
            if body.isHidden { line += ", ausgeblendet" }
            lines.append(line)
        }
        if let selected = model.selectedBody {
            lines.append("Gewählt: Körper \(selected + 1)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Anweisungen für beide Modelle (Apple und Claude).
enum AIPrompt {
    static let instructions = """
    Du bist der Modellier-Assistent der iPad-CAD-App PencilCAD. Du setzt Aufträge auf Deutsch in eine Liste \
    von Schritten um. Einheiten: Millimeter und Grad. Koordinaten: X nach rechts, Y nach hinten, Z nach oben; \
    vorne = −Y, hinten = +Y, links = −X, rechts = +X, oben = +Z, unten = −Z.

    Operationen (Feld op):
    - quader: width (X), depth (Y), height (Z); x, y = Mitte der Grundfläche, z = Unterseite (Standard 0).
    - zylinder: diameter, height; x, y, z = Mitte der Grundfläche; axis "x", "y" oder "z" (Standard z).
    - kugel: diameter; x, y, z = tiefster Punkt.
    - kegel: diameter (unten), height, value = Durchmesser oben (Standard 0).
    - abrunden: value = Radius, edges = Kantenauswahl.
    - fase: value = Fasenbreite, edges = Kantenauswahl.
    - bohrung: diameter, height = Tiefe (0 = durchgehend), face = Fläche (oben, unten, vorne, hinten, links, \
    rechts); ohne x/y/z in der Flächenmitte, sonst an diesen Koordinaten.
    - verschieben: x, y, z = Versatz.
    - drehen: axis "x", "y" oder "z", degrees; um die Körpermitte.
    - muster: countX, spacingX, countY, spacingY; legt Kopien als Raster an.
    - vereinigen / abziehen: body = Hauptkörper, target = Körper, der hinzugefügt bzw. abgezogen wird.
    - schale: face = offene Fläche, value = Wandstärke.
    - loeschen: entfernt body.

    Körper (body, target): 0 = Ergebnis des vorigen Schritts bzw. der gewählte Körper, n = Körper n aus der \
    Szenenliste. Neu erzeugte Körper bekommen die nächsten freien Nummern.
    Kantenauswahl (edges): alle, oben, unten, vorne, hinten, links, rechts, senkrecht, waagerecht. Mit \
    Bindestrich verknüpft = Schnittmenge ("oben-vorne" = die Kante oben vorne), mit Komma = mehrere \
    ("oben-vorne,oben-hinten"). "An einer Seite abgeschrägt" heißt eine Kante, z. B. "oben-vorne".
    Fehlen Maße, wähle sinnvolle Werte (z. B. Fase 1 bis 2 mm bei kleinen Teilen). Nur wenn der Auftrag \
    ohne Rückfrage gar nicht umsetzbar ist: keine Schritte und eine kurze Frage in question.
    summary: ein kurzer deutscher Satz, was entsteht.
    """
}

// MARK: Ausführen

/// Führt einen Plan auf einer Kopie der Körper aus; das Ergebnis wird als Vorschau gezeigt.
struct AIPlanExecutor {
    private(set) var bodies: [SceneBody]
    /// Stabile Nummer je Körper (1 … n wie in der Szenenliste, neue Körper fortlaufend)
    private var ids: [Int]
    private var nextID: Int
    private var current: Int?

    init(bodies: [SceneBody], current index: Int?) {
        self.bodies = bodies
        ids = Array(stride(from: 1, through: bodies.count, by: 1))
        nextID = bodies.count + 1
        current = index.flatMap { bodies.indices.contains($0) ? $0 + 1 : nil } ?? (bodies.isEmpty ? nil : bodies.count)
    }

    mutating func run(_ steps: [AIStep]) throws -> [SceneBody] {
        for (number, step) in steps.enumerated() {
            do {
                try apply(step)
            } catch {
                throw AIError("Schritt \(number + 1) (\(step.label)): \(error.localizedDescription)")
            }
        }
        return bodies
    }

    private func index(_ reference: Int?) throws -> Int {
        let id: Int? = if let reference, reference > 0 { reference } else { current }
        guard let id, let index = ids.firstIndex(of: id) else {
            throw AIError(id == nil ? "Kein Körper vorhanden." : "Körper \(id!) gibt es nicht.")
        }
        return index
    }

    private mutating func add(_ shape: PCKShape?, name: String) throws {
        guard let shape else { throw AIError("Maße ungültig.") }
        let color = SceneBody.palette[bodies.count % SceneBody.palette.count]
        bodies.append(SceneBody(shape: shape, name: "\(name) \(bodies.count + 1)", color: color))
        ids.append(nextID)
        current = nextID
        nextID += 1
    }

    private mutating func replace(_ index: Int, with shape: PCKShape?, failure: String) throws {
        guard let shape else { throw AIError(failure) }
        bodies[index] = bodies[index].with(shape)
        current = ids[index]
    }

    private mutating func remove(_ index: Int) {
        let id = ids[index]
        bodies.remove(at: index)
        ids.remove(at: index)
        if current == id { current = ids.last }
    }

    private static func axisVector(_ name: String?) -> SIMD3<Double> {
        switch name?.lowercased() {
        case "x": [1, 0, 0]
        case "y": [0, 1, 0]
        default: [0, 0, 1]
        }
    }

    private mutating func apply(_ s: AIStep) throws {
        let base = SIMD3<Double>(s.x ?? 0, s.y ?? 0, s.z ?? 0)
        switch s.op {
        case "quader":
            let w = s.width ?? 10, d = s.depth ?? w, h = s.height ?? w
            guard w > 0, d > 0, h > 0 else { throw AIError("Maße müssen größer als 0 sein.") }
            try add(PCKShape.box(width: w, depth: d, height: h).translated(by: base), name: "Quader")
        case "zylinder":
            let d = s.diameter ?? 10, h = s.height ?? d
            try add(PCKShape.cylinder(base: base, axis: Self.axisVector(s.axis), radius: d / 2, height: h), name: "Zylinder")
        case "kugel":
            let d = s.diameter ?? 10
            try add(PCKShape.sphere(center: base + [0, 0, d / 2], radius: d / 2), name: "Kugel")
        case "kegel":
            let d = s.diameter ?? 10, h = s.height ?? d
            try add(PCKShape.cone(base: base, axis: [0, 0, 1], bottomRadius: d / 2, topRadius: max(0, (s.value ?? 0) / 2),
                                  height: h), name: "Kegel")
        case "abrunden", "fase":
            let i = try index(s.body)
            let value = s.value ?? 1
            guard value > 0 else { throw AIError("Wert muss größer als 0 sein.") }
            let edges = try Self.edges(s.edges ?? "alle", of: bodies[i].shape).map { NSNumber(value: $0) }
            guard !edges.isEmpty else { throw AIError("Keine passende Kante gefunden (\(s.edges ?? "alle")).") }
            let shape = bodies[i].shape
            let result = s.op == "fase" ? shape.chamfering(edges: edges, distance: value) : shape.filleting(edges: edges, radius: value)
            try replace(i, with: result, failure: "\(value.formatted()) mm ist an diesen Kanten zu groß.")
        case "bohrung":
            let i = try index(s.body)
            let shape = bodies[i].shape
            let (_, center, normal, diagonal) = try Self.face(s.face ?? "oben", of: shape)
            var point = center
            let given = [s.x, s.y, s.z]
            for k in 0..<3 where abs(normal[k]) < 0.5 {
                if let v = given[k] { point[k] = v }
            }
            let d = s.diameter ?? 5
            let depth = (s.height ?? 0) > 0 ? s.height! + 0.5 : diagonal * 2 + 1
            let tool = PCKShape.cylinder(base: point + normal * 0.5, axis: -normal, radius: d / 2, height: depth)
            guard let tool else { throw AIError("Bohrung ungültig.") }
            try replace(i, with: shape.cutting(tool), failure: "Bohrung nicht möglich.")
        case "verschieben":
            let i = try index(s.body)
            try replace(i, with: bodies[i].shape.translated(by: base), failure: "Verschieben nicht möglich.")
        case "drehen":
            let i = try index(s.body)
            let shape = bodies[i].shape
            guard let b = Mesh(shape.triangulate(deflection: 0.1), body: 0).bounds else { throw AIError("Körper leer.") }
            let center = SIMD3<Double>((b.min + b.max) / 2)
            let result = shape.rotated(origin: center, axis: Self.axisVector(s.axis), angle: (s.degrees ?? 0) * .pi / 180)
            try replace(i, with: result, failure: "Drehen nicht möglich.")
        case "muster":
            let i = try index(s.body)
            let nx = max(1, s.countX ?? 1), ny = max(1, s.countY ?? 1)
            guard nx * ny >= 2 else { throw AIError("Anzahl mindestens 2.") }
            let source = bodies[i]
            var number = 1
            for row in 0..<ny {
                for column in 0..<nx where row > 0 || column > 0 {
                    let offset = SIMD3<Double>((s.spacingX ?? 20) * Double(column), (s.spacingY ?? 20) * Double(row), 0)
                    guard let copy = source.shape.translated(by: offset) else { throw AIError("Muster nicht möglich.") }
                    number += 1
                    var body = source.with(copy)
                    body.name += " (\(number))"
                    bodies.append(body)
                    ids.append(nextID)
                    nextID += 1
                }
            }
        case "vereinigen", "abziehen":
            let i = try index(s.body)
            guard let target = s.target, target > 0 else { throw AIError("Zweiter Körper fehlt.") }
            let j = try index(target)
            guard i != j else { throw AIError("Ein Körper kann nicht mit sich selbst verknüpft werden.") }
            let other = bodies[j].shape
            let result = s.op == "abziehen" ? bodies[i].shape.cutting(other) : bodies[i].shape.fusing(other)
            try replace(i, with: result, failure: s.op == "abziehen" ? "Abziehen fehlgeschlagen." : "Vereinigen fehlgeschlagen.")
            let keep = ids[i]
            remove(j)
            current = keep
        case "schale":
            let i = try index(s.body)
            let shape = bodies[i].shape
            let face = try Self.faceNumber(s.face ?? "oben", of: shape)
            try replace(i, with: shape.shelling(removingFace: face, thickness: s.value ?? 1),
                        failure: "Schale mit dieser Wandstärke nicht möglich.")
        case "loeschen":
            remove(try index(s.body))
        default:
            throw AIError("Unbekannte Operation „\(s.op)“.")
        }
    }

    // MARK: Kanten und Flächen nach Lage

    private static let sides: [String: SIMD3<Double>] = [
        "oben": [0, 0, 1], "unten": [0, 0, -1], "vorne": [0, -1, 0], "hinten": [0, 1, 0],
        "links": [-1, 0, 0], "rechts": [1, 0, 0],
    ]

    /// Kantennummern zu einer Auswahl wie "oben-vorne,unten" (Bindestrich = und, Komma = oder).
    static func edges(_ selector: String, of shape: PCKShape) throws -> [Int] {
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        guard let bounds = mesh.bounds else { return [] }
        let lo = SIMD3<Double>(bounds.min), hi = SIMD3<Double>(bounds.max)
        let tolerance = max(0.05, simd_length(hi - lo) * 0.005)
        var points: [Int: [SIMD3<Double>]] = [:]
        for (i, ref) in mesh.edgeRefs.enumerated() where ref.edge > 0 {
            points[ref.edge, default: []] += [SIMD3<Double>(mesh.edges[i * 2]), SIMD3<Double>(mesh.edges[i * 2 + 1])]
        }
        func matches(_ term: String, _ list: [SIMD3<Double>]) throws -> Bool {
            switch term {
            case "alle": return true
            case "senkrecht", "waagerecht":
                let span = (list.map(\.z).max() ?? 0) - (list.map(\.z).min() ?? 0)
                return term == "senkrecht" ? span > tolerance * 4 : span <= tolerance
            default:
                guard let side = sides[term] else { throw AIError("Kantenauswahl „\(term)“ unbekannt.") }
                let k = side.x != 0 ? 0 : side.y != 0 ? 1 : 2
                let limit = side[k] > 0 ? hi[k] - tolerance : lo[k] + tolerance
                return list.allSatisfy { side[k] > 0 ? $0[k] >= limit : $0[k] <= limit }
            }
        }
        var result = Set<Int>()
        for alternative in selector.lowercased().split(separator: ",") {
            let terms = alternative.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).map(String.init)
            guard !terms.isEmpty else { continue }
            for (edge, list) in points {
                if try terms.allSatisfy({ try matches($0, list) }) { result.insert(edge) }
            }
        }
        return result.sorted()
    }

    /// Ebene Fläche, deren Normale zur Seite zeigt und die am weitesten außen liegt.
    static func faceNumber(_ side: String, of shape: PCKShape) throws -> Int {
        try face(side, of: shape).face
    }

    static func face(_ side: String, of shape: PCKShape) throws -> (face: Int, center: SIMD3<Double>, normal: SIMD3<Double>, diagonal: Double) {
        guard let direction = sides[side.lowercased()] else { throw AIError("Fläche „\(side)“ unbekannt.") }
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        guard let bounds = mesh.bounds else { throw AIError("Körper leer.") }
        let diagonal = Double(simd_length(bounds.max - bounds.min))
        var best: (face: Int, center: SIMD3<Double>, along: Double)?
        for face in Set(mesh.triangleFaces.map(\.face)) {
            guard let values = shape.plane(ofFace: face)?.map(\.doubleValue), values.count == 6,
                  abs(simd_dot(simd_normalize(SIMD3(values[3], values[4], values[5])), direction)) > 0.98,
                  let centroid = mesh.centroid(of: FaceRef(body: 0, face: face)) else { continue }
            let center = SIMD3<Double>(centroid)
            let along = simd_dot(center, direction)
            if along > (best?.along ?? -.infinity) { best = (face, center, along) }
        }
        guard let best else { throw AIError("Keine ebene Fläche \(side) gefunden.") }
        return (best.face, best.center, direction, diagonal)
    }
}

// MARK: Claude

/// Claude über die Messages-API (eigener Schlüssel), Antwort als JSON nach Schema.
enum ClaudeClient {
    static func plan(_ prompt: String) async throws -> AIPlan {
        guard let key = Keychain.read() else { throw AIError("Kein API-Schlüssel hinterlegt.") }
        do {
            return try await request(prompt, key: key, fallbacks: true)
        } catch let error as APIFailure where error.status == 400 && error.message.lowercased().contains("fallback") {
            return try await request(prompt, key: key, fallbacks: false)
        }
    }

    private struct APIFailure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? {
            switch status {
            case 401: "API-Schlüssel ungültig."
            case 429: "Zu viele Anfragen, bitte kurz warten."
            case 529: "Claude ist gerade überlastet, bitte gleich nochmal."
            default: "Fehler \(status): \(message)"
            }
        }
    }

    private static func request(_ prompt: String, key: String, fallbacks: Bool) async throws -> AIPlan {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 16000,
            "system": AIPrompt.instructions,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ] as [String: Any],
            "messages": [["role": "user", "content": prompt]],
        ]
        if fallbacks {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw APIFailure(status: status, message: message ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        switch json?["stop_reason"] as? String {
        case "refusal": throw AIError("Claude hat den Auftrag abgelehnt.")
        case "max_tokens": throw AIError("Antwort zu lang, bitte den Auftrag aufteilen.")
        default: break
        }
        let blocks = json?["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw AIError("Leere Antwort von Claude.")
        }
        do {
            return try JSONDecoder().decode(AIPlan.self, from: Data(text.utf8))
        } catch {
            throw AIError("Antwort von Claude nicht lesbar.")
        }
    }

    private static var schema: [String: Any] {
        func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
        func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
        func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["op"],
            "properties": [
                "op": ["type": "string", "enum": AIStep.operations] as [String: Any],
                "body": integer("0 = voriger Schritt bzw. gewählter Körper, n = Körper n"),
                "target": integer("Zweiter Körper bei vereinigen/abziehen"),
                "x": number("mm"), "y": number("mm"), "z": number("mm"),
                "width": number("Breite X in mm"), "depth": number("Tiefe Y in mm"), "height": number("Höhe Z bzw. Tiefe in mm"),
                "diameter": number("Durchmesser in mm"),
                "value": number("Radius, Fasenbreite, Wandstärke oder oberer Kegeldurchmesser in mm"),
                "edges": string("Kantenauswahl, z. B. alle, oben, oben-vorne, senkrecht"),
                "face": string("oben, unten, vorne, hinten, links oder rechts"),
                "axis": string("x, y oder z"),
                "degrees": number("Grad"),
                "countX": integer("Anzahl in X"), "spacingX": number("Abstand in X, mm"),
                "countY": integer("Anzahl in Y"), "spacingY": number("Abstand in Y, mm"),
            ] as [String: Any],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "steps"],
            "properties": [
                "summary": string("Ein kurzer deutscher Satz, was entsteht"),
                "steps": ["type": "array", "items": step] as [String: Any],
                "question": string("Nur wenn ohne Rückfrage nicht umsetzbar"),
            ] as [String: Any],
        ]
    }
}

// MARK: Apple (auf dem Gerät)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct LocalPlan {
    @Guide(description: "Ein kurzer deutscher Satz, was entsteht")
    var summary: String
    @Guide(description: "Schritte in der Reihenfolge der Ausführung")
    var steps: [LocalStep]
}

@available(iOS 26.0, *)
@Generable
struct LocalStep {
    @Guide(description: "Operation", .anyOf(["quader", "zylinder", "kugel", "kegel", "abrunden", "fase", "bohrung",
                                              "verschieben", "drehen", "muster", "vereinigen", "abziehen", "schale",
                                              "loeschen"]))
    var op: String
    @Guide(description: "0 = voriger Schritt bzw. gewählter Körper, n = Körper n")
    var body: Int?
    @Guide(description: "Zweiter Körper bei vereinigen oder abziehen")
    var target: Int?
    @Guide(description: "X in mm")
    var x: Double?
    @Guide(description: "Y in mm")
    var y: Double?
    @Guide(description: "Z in mm")
    var z: Double?
    @Guide(description: "Breite X in mm")
    var width: Double?
    @Guide(description: "Tiefe Y in mm")
    var depth: Double?
    @Guide(description: "Höhe Z in mm, bei Bohrung die Tiefe (0 = durchgehend)")
    var height: Double?
    @Guide(description: "Durchmesser in mm")
    var diameter: Double?
    @Guide(description: "Radius, Fasenbreite oder Wandstärke in mm")
    var value: Double?
    @Guide(description: "Kantenauswahl: alle, oben, unten, vorne, hinten, links, rechts, senkrecht; mit Bindestrich kombiniert, z. B. oben-vorne")
    var edges: String?
    @Guide(description: "Fläche: oben, unten, vorne, hinten, links oder rechts")
    var face: String?
    @Guide(description: "Achse: x, y oder z")
    var axis: String?
    @Guide(description: "Winkel in Grad")
    var degrees: Double?
    @Guide(description: "Anzahl in X")
    var countX: Int?
    @Guide(description: "Abstand in X in mm")
    var spacingX: Double?
    @Guide(description: "Anzahl in Y")
    var countY: Int?
    @Guide(description: "Abstand in Y in mm")
    var spacingY: Double?
}

@available(iOS 26.0, *)
enum LocalPlanner {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    @MainActor
    static func plan(prompt: String) async throws -> AIPlan {
        let session = LanguageModelSession(instructions: AIPrompt.instructions)
        let response = try await session.respond(to: prompt, generating: LocalPlan.self)
        let plan = response.content
        let steps = plan.steps.map { s in
            AIStep(op: s.op, body: s.body, target: s.target, x: s.x, y: s.y, z: s.z, width: s.width, depth: s.depth,
                   height: s.height, diameter: s.diameter, value: s.value, edges: s.edges, face: s.face, axis: s.axis,
                   degrees: s.degrees, countX: s.countX, spacingX: s.spacingX, countY: s.countY, spacingY: s.spacingY)
        }
        return AIPlan(summary: plan.summary, steps: steps, question: nil)
    }
}
#endif

// MARK: Schlüsselbund

/// API-Schlüssel für Claude im Schlüsselbund (nie in den Projektdateien).
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PencilCAD",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
