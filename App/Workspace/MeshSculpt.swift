import SwiftUI
import UIKit
import simd

// Ändern › Netz bearbeiten: Pinsel mit dem Stift auf einem Körper (Anheben, Absenken, Glätten, Abflachen).
// Der Pinsel arbeitet auf einer verschweißten Netzkopie des Körpers; während des Strichs zeigt der Viewport dieses
// Netz direkt (ohne Kernel). Kurz nach dem Absetzen wird daraus im Hintergrund wieder ein Volumenkörper
// (MeshSolid, MeshRepair.swift) – ein Schritt zum Rückgängigmachen je Strich bzw. je schneller Strichfolge.

enum SculptMode: String, CaseIterable, Identifiable {
    case raise = "Anheben"
    case lower = "Absenken"
    case smooth = "Glätten"
    case flatten = "Abflachen"
    /// Build 73: Rundung bzw. Bohrung antippen und als echte Fläche nachbauen (MeshRounds.swift)
    case recognize = "Rundung/Loch"

    var id: Self { self }
}

/// Kapsel für Ergebnisse aus Hintergrundaufgaben (Kernelkörper sind nicht als Sendable markiert).
final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Eine Stiftposition des Strichs: Sehstrahl und Druck (1 = normal).
struct SculptSample {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    var pressure: Float
}

/// Arbeitsnetz eines Körpers für den Pinsel (Punkte verschweißt, Nachbarn je Punkt).
struct SculptMesh {
    let body: Int
    /// Körper, aus dem das Netz stammt bzw. zuletzt übernommen wurde
    var shape: PCKShape
    var color: SIMD3<Float>
    var positions: [SIMD3<Float>]
    private(set) var triangles: [SIMD3<UInt32>]
    /// Nachbarpunkte je Punkt (Nachbarn von i: neighbors[neighborStart[i] ..< neighborStart[i + 1]])
    private var neighborStart: [Int] = []
    private var neighbors: [UInt32] = []
    /// Dreiecke je Punkt (gleich aufgebaut)
    private var triangleStart: [Int] = []
    private var pointTriangles: [UInt32] = []

    var triangleCount: Int { triangles.count }

    /// Netz des Körpers aus der angezeigten Triangulierung (Flächenränder verschweißt).
    init?(body: Int, shape: PCKShape, color: SIMD3<Float>, from mesh: Mesh) {
        var lookup: [SIMD3<Int64>: UInt32] = [:]
        var points: [SIMD3<Float>] = []
        var list: [SIMD3<UInt32>] = []
        for (t, ref) in mesh.triangleFaces.enumerated() where ref.body == body {
            guard t * 3 + 2 < mesh.indices.count else { break }
            var corners = SIMD3<UInt32>(0, 0, 0)
            for k in 0..<3 {
                let p = mesh.vertices[Int(mesh.indices[t * 3 + k])].position
                let scaled: SIMD3<Float> = (p * 10_000).rounded(.toNearestOrAwayFromZero)
                let key = SIMD3<Int64>(Int64(scaled.x), Int64(scaled.y), Int64(scaled.z))
                if let existing = lookup[key] {
                    corners[k] = existing
                } else {
                    let new = UInt32(points.count)
                    points.append(p)
                    lookup[key] = new
                    corners[k] = new
                }
            }
            guard corners.x != corners.y, corners.y != corners.z, corners.x != corners.z else { continue }
            list.append(corners)
        }
        guard list.count >= 4 else { return nil }
        self.body = body
        self.shape = shape
        self.color = color
        positions = points
        triangles = list
        rebuildTopology()
    }

    init(body: Int, shape: PCKShape, color: SIMD3<Float>, indexed: IndexedMesh) {
        self.body = body
        self.shape = shape
        self.color = color
        positions = indexed.positions.map { SIMD3<Float>($0) }
        triangles = indexed.triangles
        rebuildTopology()
    }

    /// Netz in doppelter Genauigkeit (für Kernel und Reparatur).
    var indexed: IndexedMesh {
        IndexedMesh(positions: positions.map { SIMD3<Double>($0) }, triangles: triangles)
    }

    private mutating func rebuildTopology() {
        var lists = [[UInt32]](repeating: [], count: positions.count)
        var owners = [[UInt32]](repeating: [], count: positions.count)
        for (index, t) in triangles.enumerated() {
            let corners: [UInt32] = [t.x, t.y, t.z]
            for j in 0..<3 {
                let a = corners[j], b = corners[(j + 1) % 3]
                if !lists[Int(a)].contains(b) { lists[Int(a)].append(b) }
                if !lists[Int(b)].contains(a) { lists[Int(b)].append(a) }
                owners[Int(a)].append(UInt32(index))
            }
        }
        neighborStart = [0]
        neighbors = []
        neighbors.reserveCapacity(positions.count * 6)
        for list in lists {
            neighbors += list
            neighborStart.append(neighbors.count)
        }
        triangleStart = [0]
        pointTriangles = []
        pointTriangles.reserveCapacity(triangles.count * 3)
        for list in owners {
            pointTriangles += list
            triangleStart.append(pointTriangles.count)
        }
    }

    // MARK: Treffen

    /// Nächster Schnittpunkt eines Strahls mit dem Netz und die Normale des getroffenen Dreiecks.
    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        var best: (t: Float, triangle: Int)?
        for (index, tri) in triangles.enumerated() {
            let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
            let e1 = b - a, e2 = c - a
            let p = simd_cross(direction, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1e-12 { continue }
            let inv = 1 / det
            let s = origin - a
            let u = simd_dot(s, p) * inv
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(direction, q) * inv
            if v < 0 || u + v > 1 { continue }
            let distance = simd_dot(e2, q) * inv
            if distance > 0, distance < (best?.t ?? .infinity) {
                best = (distance, index)
            }
        }
        guard let best else { return nil }
        let tri = triangles[best.triangle]
        let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
        let cross = simd_cross(b - a, c - a)
        let normal: SIMD3<Float> = simd_length(cross) > 0 ? simd_normalize(cross) : -direction
        return (origin + best.t * direction, normal)
    }

    // MARK: Pinsel

    /// Flächengewichtete Normale eines Punkts.
    private func normal(at index: Int) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        for k in triangleStart[index]..<triangleStart[index + 1] {
            let tri = triangles[Int(pointTriangles[k])]
            let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
            sum += simd_cross(b - a, c - a)
        }
        return sum
    }

    /// Ein Pinseltupfer um center (weicher Abfall bis radius). amount: Stärke × Druck.
    mutating func dab(at center: SIMD3<Float>, radius: Float, amount: Float, mode: SculptMode) {
        guard radius > 0 else { return }
        let radiusSquared = radius * radius
        var affected: [Int] = []
        var weights: [Float] = []
        for (index, p) in positions.enumerated() {
            let d2 = simd_distance_squared(p, center)
            guard d2 < radiusSquared else { continue }
            let x: Float = 1 - d2 / radiusSquared
            affected.append(index)
            weights.append(x * x)
        }
        guard !affected.isEmpty else { return }
        // Gemittelte Normale und Mitte des Bereichs
        var averageNormal = SIMD3<Float>(repeating: 0)
        var centroid = SIMD3<Float>(repeating: 0)
        var weightSum: Float = 0
        for (k, index) in affected.enumerated() {
            averageNormal += normal(at: index) * weights[k]
            centroid += positions[index] * weights[k]
            weightSum += weights[k]
        }
        guard simd_length(averageNormal) > 0, weightSum > 0 else { return }
        let n = simd_normalize(averageNormal)
        centroid /= weightSum
        switch mode {
        case .raise, .lower:
            let sign: Float = mode == .raise ? 1 : -1
            let step: Float = sign * amount * radius * 0.06
            for (k, index) in affected.enumerated() {
                positions[index] += n * (step * weights[k])
            }
        case .smooth:
            // Erst alle Ziele berechnen, dann setzen (Nachbarn lesen noch die alten Punkte)
            var targets: [SIMD3<Float>] = []
            targets.reserveCapacity(affected.count)
            for (k, index) in affected.enumerated() {
                let start = neighborStart[index], end = neighborStart[index + 1]
                guard end > start else {
                    targets.append(positions[index])
                    continue
                }
                var sum = SIMD3<Float>(repeating: 0)
                for m in start..<end { sum += positions[Int(neighbors[m])] }
                let average: SIMD3<Float> = sum / Float(end - start)
                let share: Float = min(1, amount * weights[k])
                targets.append(positions[index] + (average - positions[index]) * share)
            }
            for (k, index) in affected.enumerated() { positions[index] = targets[k] }
        case .flatten:
            for (k, index) in affected.enumerated() {
                let distance: Float = simd_dot(positions[index] - centroid, n)
                let share: Float = min(1, amount * weights[k] * 0.5)
                positions[index] -= n * (distance * share)
            }
        case .recognize:
            break
        }
    }

    // MARK: Anzeige

    /// Angezeigtes Netz: die übrigen Körper (base) und dieses Netz mit weichen Normalen.
    func display(base: Mesh) -> Mesh {
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: positions.count)
        for tri in triangles {
            let a = positions[Int(tri.x)], b = positions[Int(tri.y)], c = positions[Int(tri.z)]
            let n = simd_cross(b - a, c - a)
            normals[Int(tri.x)] += n
            normals[Int(tri.y)] += n
            normals[Int(tri.z)] += n
        }
        var part = Mesh()
        part.vertices.reserveCapacity(positions.count)
        for (index, p) in positions.enumerated() {
            let sum = normals[index]
            let n: SIMD3<Float> = simd_length(sum) > 0 ? simd_normalize(sum) : SIMD3<Float>(0, 0, 1)
            part.vertices.append(Vertex(position: p, normal: n, color: color))
        }
        part.indices.reserveCapacity(triangles.count * 3)
        for tri in triangles {
            part.indices.append(tri.x)
            part.indices.append(tri.y)
            part.indices.append(tri.z)
        }
        part.triangleFaces = [FaceRef](repeating: FaceRef(body: body, face: 1), count: triangles.count)
        var result = base
        result.append(part)
        return result
    }

    /// Szenennetz ohne die Dreiecke und Kanten eines Körpers.
    static func mesh(_ mesh: Mesh, without body: Int) -> Mesh {
        var result = Mesh()
        result.vertices = mesh.vertices
        for (t, ref) in mesh.triangleFaces.enumerated() where ref.body != body {
            guard t * 3 + 2 < mesh.indices.count else { break }
            result.indices.append(mesh.indices[t * 3])
            result.indices.append(mesh.indices[t * 3 + 1])
            result.indices.append(mesh.indices[t * 3 + 2])
            result.triangleFaces.append(ref)
        }
        for (i, ref) in mesh.edgeRefs.enumerated() where ref.body != body {
            guard i * 2 + 1 < mesh.edges.count else { break }
            result.edges.append(mesh.edges[i * 2])
            result.edges.append(mesh.edges[i * 2 + 1])
            result.edgeRefs.append(ref)
        }
        return result
    }
}

/// Zustand des Werkzeugs „Netz bearbeiten“.
@MainActor
final class MeshSculpt: ObservableObject {
    @Published var mode: SculptMode = .raise
    /// Pinselradius in mm
    @Published var radius: Double = 5
    /// Stärke 0…1 (Stiftdruck verstärkt zusätzlich)
    @Published var strength: Double = 0.5
    /// „Dreiecke reduzieren“: Ziel in Prozent der jetzigen Zahl
    @Published var reducePercent: Double = 50
    /// Umwandeln bzw. Reduzieren läuft im Hintergrund
    @Published private(set) var isBusy = false
    /// Gewählter Körper
    @Published private(set) var body: Int?
    @Published private(set) var triangleCount = 0
    /// Größter sinnvoller Radius (halbe Körpergröße)
    @Published private(set) var maxRadius: Double = 50
    /// Build 70: offene Kanten (Ränder, an denen nur ein Dreieck hängt) rot im Viewport zeigen
    @Published var showsOpenEdges = true
    /// Build 73: angetippte Rundung bzw. Bohrung und gewünschter Radius
    @Published private(set) var round: MeshRound?
    @Published var roundRadius: Double = 1
    /// Build 74: erster Tipp (Körper, Punkt) – der nächste Tipp auf demselben Körper legt das andere Ende fest
    private var firstTap: (body: Int, point: SIMD3<Double>)?
    /// Zwischenspeicher der offenen Kanten (je Körperstand neu)
    private var openEdgeCache: (key: String, lines: [[SIMD3<Float>]])?

    /// Pinselkreis (Weltpunkte) für den Viewport
    private(set) var brushCircle: [SIMD3<Float>] = []
    /// Stift des laufenden Strichs
    private(set) var strokeTouch: UITouch?

    private var working: SculptMesh?
    /// Szenennetz ohne den bearbeiteten Körper (für die Anzeige)
    private var base: Mesh?
    private var lastDab: SIMD3<Float>?
    private var strokeChanged = false
    private var lastPush: CFTimeInterval = 0
    /// Änderungsstand des Arbeitsnetzes und zuletzt als Körper übernommener Stand
    private var generation = 0
    private var savedGeneration = 0
    private var pendingSave: Task<Void, Never>?

    /// Pause nach dem letzten Strich, bevor umgewandelt wird (schnelle Striche werden ein Schritt)
    private static let saveDelay: UInt64 = 700_000_000

    // MARK: Körper

    /// Werkzeug gestartet: Körper der bisherigen Auswahl übernehmen.
    func activate(model: ModelStore, body chosen: Int?) {
        brushCircle = []
        strokeTouch = nil
        if pendingSave != nil { saveNow(model: model) }
        if let working, !isValid(working, model: model), !isBusy {
            self.working = nil
            body = nil
        }
        if let chosen { _ = choose(chosen, model: model) }
    }

    private func isValid(_ mesh: SculptMesh, model: ModelStore) -> Bool {
        model.bodies.indices.contains(mesh.body) && model.bodies[mesh.body].shape === mesh.shape
    }

    /// Körper zum Bearbeiten wählen; false, wenn das nicht geht (Meldung steht dann in model.message).
    @discardableResult
    func choose(_ index: Int, model: ModelStore) -> Bool {
        guard model.bodies.indices.contains(index) else { return false }
        if let working, working.body == index, isValid(working, model: model) { return true }
        guard !isBusy else {
            model.message = "Das Netz wird noch umgewandelt – gleich noch einmal versuchen."
            return false
        }
        if pendingSave != nil {
            saveNow(model: model)
            return false
        }
        let scene = model.bodies[index]
        guard var mesh = SculptMesh(body: index, shape: scene.shape, color: scene.renderColor, from: model.mesh) else {
            model.message = scene.isHidden ? "Der Körper ist ausgeblendet." : "Dieser Körper hat kein bearbeitbares Netz."
            return false
        }
        let changedBody = body != index
        let size: Double = mesh.indexed.size
        maxRadius = max(1, (size / 2).rounded())
        if changedBody {
            let suggested: Double = max(0.5, (size * 0.08 * 2).rounded() / 2)
            radius = min(suggested, maxRadius)
        }
        // Grobe Netze (z. B. ein Würfel aus 12 Dreiecken) gleich verfeinern, damit der Pinsel greift; übernommen
        // wird das erst mit dem ersten Strich
        let fineLimit = 20_000
        if mesh.triangleCount < fineLimit {
            let refined = MeshRepair.refine(mesh.indexed, maxEdge: radius / 2, limit: fineLimit)
            if refined.triangles.count > mesh.triangleCount {
                mesh = SculptMesh(body: index, shape: scene.shape, color: scene.renderColor, indexed: refined)
            }
        }
        working = mesh
        base = nil
        body = index
        generation = 0
        savedGeneration = 0
        triangleCount = mesh.triangleCount
        if mesh.triangleCount > MeshSolid.maxTriangles {
            model.message = "\(scene.name): \(mesh.triangleCount) Dreiecke – Umwandeln dauert lange, besser erst „Dreiecke reduzieren“."
        } else {
            model.message = "\(scene.name): \(mesh.triangleCount) Dreiecke · mit dem Stift darauf malen (wird dabei zum Netzkörper)"
        }
        return true
    }

    // MARK: Strich

    /// Stift setzt auf: true, wenn er auf dem Körper sitzt (dann gehört der Strich dem Pinsel).
    func beginStroke(_ touch: UITouch, origin: SIMD3<Float>, direction: SIMD3<Float>, model: ModelStore) -> Bool {
        guard strokeTouch == nil, !isBusy else { return false }
        if mode == .recognize {
            // Build 73: Stift tippt eine Rundung bzw. Bohrung an (kein Pinselstrich)
            guard let found = model.pick(origin: origin, direction: direction) else { return false }
            recognize(body: found.face.body, at: SIMD3<Double>(found.point), model: model)
            return true
        }
        if let working, !isValid(working, model: model) {
            // Rückgängig o. Ä.: Netz neu vom Körper holen
            self.working = nil
        }
        var hit = working?.pick(origin: origin, direction: direction)
        if hit == nil {
            // Anderer Körper unter dem Stift: wechseln, wenn nichts mehr umzuwandeln ist
            guard pendingSave == nil, generation == savedGeneration,
                  let found = model.pick(origin: origin, direction: direction),
                  choose(found.face.body, model: model) else { return false }
            hit = working?.pick(origin: origin, direction: direction)
        }
        guard let hit else { return false }
        pendingSave?.cancel()
        pendingSave = nil
        strokeTouch = touch
        lastDab = hit.point
        strokeChanged = false
        brushCircle = Self.circle(center: hit.point, normal: hit.normal, radius: Float(radius))
        return true
    }

    func moveStroke(_ samples: [SculptSample], model: ModelStore) {
        guard strokeTouch != nil, var mesh = working else { return }
        // Ohne zweiten Verweis kopiert das Ändern der Punkte nicht jedes Mal das ganze Feld
        working = nil
        let brush = Float(radius)
        let spacing: Float = max(brush * 0.25, 1e-3)
        let strengthValue = Float(strength)
        for sample in samples {
            guard let hit = mesh.pick(origin: sample.origin, direction: sample.direction) else { continue }
            let from = lastDab ?? hit.point
            let distance = simd_distance(from, hit.point)
            if !strokeChanged || distance >= spacing {
                let steps = max(1, min(16, Int(distance / spacing)))
                let amount: Float = strengthValue * sample.pressure
                for step in 1...steps {
                    let t = Float(step) / Float(steps)
                    let center: SIMD3<Float> = from + (hit.point - from) * t
                    mesh.dab(at: center, radius: brush, amount: amount, mode: mode)
                }
                lastDab = hit.point
                strokeChanged = true
            }
            brushCircle = Self.circle(center: hit.point, normal: hit.normal, radius: brush)
        }
        working = mesh
        pushPreview(model: model, force: false)
    }

    /// Stift abgesetzt (bzw. Strich abgebrochen).
    func endStroke(model: ModelStore) {
        guard strokeTouch != nil else { return }
        strokeTouch = nil
        lastDab = nil
        guard strokeChanged else { return }
        strokeChanged = false
        generation += 1
        pushPreview(model: model, force: true)
        scheduleSave(model: model)
    }

    /// Stift schwebt: Pinselkreis zeigen (nil = ausblenden).
    func hover(origin: SIMD3<Float>?, direction: SIMD3<Float>?, model: ModelStore) {
        guard strokeTouch == nil else { return }
        // Build 77: im Modus „Rundung/Loch“ wird nicht gemalt – kein Pinselkreis
        guard mode != .recognize else {
            brushCircle = []
            return
        }
        guard let origin, let direction else {
            brushCircle = []
            return
        }
        if let working, let hit = working.pick(origin: origin, direction: direction) {
            brushCircle = Self.circle(center: hit.point, normal: hit.normal, radius: Float(radius))
        } else if let hit = model.pick(origin: origin, direction: direction) {
            brushCircle = Self.circle(center: hit.point, normal: -direction, radius: Float(radius))
        } else {
            brushCircle = []
        }
    }

    private func pushPreview(model: ModelStore, force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastPush > 1.0 / 30 else { return }
        lastPush = now
        guard let working else { return }
        // Auch aus dem schon angezeigten Pinselnetz richtig: dessen Dreiecke gehören zum selben Körper
        let rest = base ?? SculptMesh.mesh(model.mesh, without: working.body)
        base = rest
        model.showSculptMesh(working.display(base: rest))
    }

    static func circle(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
        guard simd_length(normal) > 0 else { return [] }
        let n = simd_normalize(normal)
        let helper: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let u = simd_normalize(simd_cross(n, helper))
        let v = simd_cross(n, u)
        var points: [SIMD3<Float>] = []
        for k in 0...48 {
            let angle = Float(k) / 48 * 2 * .pi
            let offset: SIMD3<Float> = u * (cos(angle) * radius) + v * (sin(angle) * radius)
            points.append(center + offset + n * (radius * 0.02))
        }
        return points
    }

    // MARK: Übernehmen

    private func scheduleSave(model: ModelStore) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MeshSculpt.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow(model: model)
        }
    }

    /// Arbeitsnetz im Hintergrund in einen Körper umwandeln und als Schritt „Netz bearbeiten“ übernehmen.
    private func saveNow(model: ModelStore) {
        pendingSave?.cancel()
        pendingSave = nil
        guard !isBusy, strokeTouch == nil, let working, generation > savedGeneration else { return }
        guard isValid(working, model: model) else {
            discard(model: model, note: "Der Körper wurde inzwischen geändert – Pinselstriche verworfen.")
            return
        }
        let snapshot: IndexedMesh = working.indexed
        let target = generation
        let expected = working.shape
        let index = working.body
        isBusy = true
        model.message = "Netz wird in einen Körper umgewandelt …"
        Task {
            // B8 (Build 41): OCCT auf dem großen Stapel (KernelThread, 32 MB) statt Task.detached (512 KB)
            let box = await KernelThread.value("PencilCAD.sculpt") { () -> UncheckedBox<(IndexedMesh, PCKShape?)> in
                var mesh = snapshot
                // Beim Formen zusammengefallene Dreiecke entfernen, sonst bleibt der Körper offen
                _ = MeshRepair.removeDegenerate(&mesh)
                return UncheckedBox((mesh, MeshSolid.shape(from: mesh)))
            }
            self.finishSave(box.value.1, mesh: box.value.0, generation: target, expected: expected, body: index,
                            model: model)
        }
    }

    private func finishSave(_ shape: PCKShape?, mesh: IndexedMesh, generation target: Int, expected: PCKShape,
                            body index: Int, model: ModelStore) {
        isBusy = false
        guard model.bodies.indices.contains(index), model.bodies[index].shape === expected else {
            discard(model: model, note: "Der Körper wurde inzwischen geändert – Pinselstriche verworfen.")
            return
        }
        guard let shape else {
            discard(model: model, note: "Das Netz ließ sich nicht in einen Körper umwandeln – Pinselstriche verworfen.")
            return
        }
        var list = model.bodies
        list[index] = list[index].with(shape)
        model.commit(list, name: "Netz bearbeiten")
        savedGeneration = target
        base = nil
        if var current = working, current.body == index {
            current.shape = shape
            // Netz geändert (entfernte Dreiecke) und seitdem nicht weiter gemalt: bereinigtes Netz übernehmen
            if generation == target, mesh.triangles.count != current.triangleCount {
                current = SculptMesh(body: index, shape: shape, color: current.color, indexed: mesh)
            }
            working = current
            triangleCount = current.triangleCount
        }
        if !shape.isClosedSolid {
            model.message = "Netz ist nicht geschlossen – als Fläche übernommen (Bohren und Vereinigen gehen erst geschlossen)."
        }
        if generation > target {
            // Inzwischen weiter gemalt
            pushPreview(model: model, force: true)
            scheduleSave(model: model)
        }
    }

    /// Ungespeicherte Pinselstriche verwerfen und wieder die echten Körper zeigen.
    private func discard(model: ModelStore, note: String) {
        working = nil
        base = nil
        body = nil
        generation = 0
        savedGeneration = 0
        model.endSculptMesh()
        model.message = note
    }

    // MARK: Rundung bzw. Bohrung erkennen (Build 73)

    /// Stelle auf einem Körper angetippt: Rundung bzw. Bohrung dort suchen (im Hintergrund).
    /// Zweiter Tipp (Build 74): Rundung von der ersten bis zur zweiten angetippten Seite. Klappt das nicht, gilt
    /// der zweite Tipp als neuer erster.
    func recognize(body index: Int, at point: SIMD3<Double>, model: ModelStore) {
        guard !isBusy, model.bodies.indices.contains(index) else { return }
        let previous: SIMD3<Double>? = firstTap.flatMap { $0.body == index ? $0.point : nil }
        let scene = model.bodies[index]
        guard let mesh = SculptMesh(body: index, shape: scene.shape, color: scene.renderColor, from: model.mesh)?.indexed else {
            model.message = "Dieser Körper hat kein Netz."
            return
        }
        isBusy = true
        round = nil
        model.message = "Rundung bzw. Bohrung wird gesucht …"
        Task {
            let result: (MeshRound?, Bool) = await Task.detached(priority: .userInitiated) {
                if let previous, let ranged = MeshRounds.detect(in: mesh, body: index, at: previous, to: point) {
                    return (ranged, true)
                }
                return (MeshRounds.detect(in: mesh, body: index, at: point), false)
            }.value
            self.isBusy = false
            let (found, ranged) = result
            // Nach einem Bereich beginnt der nächste Tipp neu, sonst ist dieser Tipp der Anfang
            self.firstTap = ranged ? nil : (index, point)
            guard let found else {
                model.message = "Hier allein keine Rundung erkannt – jetzt die LETZTE Seite der Rundung antippen (erste Seite ist gemerkt)."
                return
            }
            self.round = found
            self.roundRadius = (found.radius * 100).rounded() / 100
            model.message = ranged
                ? found.title + " (von erster bis letzter Seite) – Radius einstellen und „Übernehmen“"
                : found.title + " erkannt – „Übernehmen“, oder zum Eingrenzen noch die letzte Seite antippen"
        }
    }

    /// Erkannte Form mit roundRadius als echte Fläche in den Körper übernehmen (ein Rückgängig-Schritt).
    func applyRound(model: ModelStore) {
        guard !isBusy, let round, model.bodies.indices.contains(round.body) else { return }
        let index = round.body
        let expected = model.bodies[index].shape
        let target = roundRadius
        isBusy = true
        model.message = "Wird nachgebaut …"
        Task {
            let box = await KernelThread.value("PencilCAD.meshRound") { () -> UncheckedBox<(PCKShape?, String)> in
                let result = MeshRounds.apply(round, to: expected, radius: target)
                return UncheckedBox((result.shape, result.note))
            }
            self.isBusy = false
            let (shape, note) = box.value
            guard model.bodies.indices.contains(index), model.bodies[index].shape === expected else {
                model.message = "Der Körper wurde inzwischen geändert."
                return
            }
            guard let shape else {
                model.message = note
                return
            }
            var list = model.bodies
            list[index] = list[index].with(shape)
            model.commit(list, name: round.isFillet ? "Rundung nachbauen" : "Bohrung nachbauen")
            self.round = nil
            self.firstTap = nil
            self.working = nil
            self.base = nil
            self.body = nil
            self.triangleCount = 0
            model.message = note
        }
    }

    func clearRound() {
        round = nil
        firstTap = nil
    }

    // MARK: Offene Kanten (Build 70)

    /// Randkanten des Arbeitsnetzes als Strecken (Weltpunkte). Leer, wenn das Netz geschlossen ist.
    func openEdgeLines() -> [[SIMD3<Float>]] {
        guard let working else { return [] }
        let key = "\(working.body)-\(ObjectIdentifier(working.shape).hashValue)-\(generation)-\(working.triangleCount)"
        if let cache = openEdgeCache, cache.key == key { return cache.lines }
        var count: [SIMD2<UInt32>: Int] = [:]
        count.reserveCapacity(working.triangles.count * 3 / 2 + 1)
        for t in working.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                count[SIMD2<UInt32>(min(a, b), max(a, b)), default: 0] += 1
            }
        }
        var lines: [[SIMD3<Float>]] = []
        for (edge, n) in count where n == 1 {
            let a = Int(edge.x), b = Int(edge.y)
            guard working.positions.indices.contains(a), working.positions.indices.contains(b) else { continue }
            lines.append([working.positions[a], working.positions[b]])
        }
        openEdgeCache = (key, lines)
        return lines
    }

    /// Anzahl offener Kanten (0 = geschlossenes Netz).
    var openEdgeCount: Int { openEdgeLines().count }

    /// Ganze Reparatur noch einmal: Punkte verschweißen, kaputte und doppelte Dreiecke entfernen, Normalen
    /// ausrichten und auch große Löcher (bis 5000 Kanten) schließen.
    func repairAgain(model: ModelStore) {
        rebuild(model: model, name: "Netz reparieren") { mesh in
            var soup: [SIMD3<Double>] = []
            soup.reserveCapacity(mesh.triangles.count * 3)
            for t in mesh.triangles {
                for k in [t.x, t.y, t.z] where Int(k) < mesh.positions.count { soup.append(mesh.positions[Int(k)]) }
            }
            let repaired = MeshRepair.repair(soup: soup)
            var result = repaired.mesh
            var report = repaired.report
            let holes = MeshRepair.fillHoles(&result, maxEdges: 5000)
            report.closedHoles += holes.closed
            report.openHoles = holes.open
            _ = MeshRepair.orient(&result)
            let summary = report.summary
            return (result, summary.isEmpty ? "Netz repariert – nichts zu tun" : "Netz repariert: " + summary)
        }
    }

    // MARK: Netz verfeinern, reduzieren, Löcher schließen

    /// Dichteres Netz für feine Pinselarbeit: Kanten länger als ein Drittel des Radius werden geteilt.
    func refine(model: ModelStore) {
        let maxEdge = max(radius / 3, 0.05)
        rebuild(model: model, name: "Netz verfeinern") { mesh in
            let refined = MeshRepair.refine(mesh, maxEdge: maxEdge, limit: MeshSolid.maxTriangles)
            let note = refined.triangles.count == mesh.triangles.count
                ? "Netz ist schon fein genug (bzw. an der Grenze von \(MeshSolid.maxTriangles) Dreiecken)."
                : "Verfeinert: \(mesh.triangles.count) → \(refined.triangles.count) Dreiecke"
            return (refined, note)
        }
    }

    /// Dreiecke auf reducePercent % reduzieren.
    func reduce(model: ModelStore) {
        let percent = min(max(reducePercent, 5), 95)
        rebuild(model: model, name: "Dreiecke reduzieren") { mesh in
            let target = max(8, Int(Double(mesh.triangles.count) * percent / 100))
            let reduced = MeshRepair.simplify(mesh, target: target)
            return (reduced, "Reduziert: \(mesh.triangles.count) → \(reduced.triangles.count) Dreiecke")
        }
    }

    /// Offene Randschleifen schließen.
    func closeHoles(model: ModelStore) {
        rebuild(model: model, name: "Löcher schließen") { mesh in
            var result = mesh
            _ = MeshRepair.removeDegenerate(&result)
            let holes = MeshRepair.fillHoles(&result, maxEdges: 5000)
            _ = MeshRepair.orient(&result)
            var parts: [String] = []
            parts.append(holes.closed == 1 ? "1 Loch geschlossen" : "\(holes.closed) Löcher geschlossen")
            if holes.open > 0 { parts.append("\(holes.open) ließen sich nicht schließen") }
            return (result, parts.joined(separator: ", "))
        }
    }

    /// Build 71: Bohrungen und Zapfen im Netz erkennen und durch echte Zylinder ersetzen (MeshFeatures.swift).
    /// Danach ist der Körper kein reines Dreiecksnetz mehr: zum Weitermalen neu antippen.
    func trueCylinders(model: ModelStore) {
        rebuild(model: model, name: "Zylinder erkennen", { mesh in (mesh, "") }, shapeChange: { shape, mesh in
            let smoothed = MeshFeatures.trueCylinders(shape, mesh: mesh)
            let total = smoothed.holes + smoothed.bosses
            guard total > 0 else { return (shape, "Keine ganz umlaufende Bohrung bzw. kein Zapfen erkannt") }
            var parts: [String] = []
            if smoothed.holes > 0 { parts.append(smoothed.holes == 1 ? "1 Bohrung" : "\(smoothed.holes) Bohrungen") }
            if smoothed.bosses > 0 { parts.append(smoothed.bosses == 1 ? "1 Zapfen" : "\(smoothed.bosses) Zapfen") }
            return (smoothed.shape, parts.joined(separator: " und ") + " als echte Zylinder")
        })
    }

    /// Netz des gewählten Körpers im Hintergrund umbauen, umwandeln und als ein Schritt übernehmen.
    /// shapeChange (Build 71) bearbeitet danach noch den Körper; das Arbeitsnetz passt dann nicht mehr dazu.
    private func rebuild(model: ModelStore, name: String,
                         _ change: @escaping @Sendable (IndexedMesh) -> (IndexedMesh, String),
                         shapeChange: (@Sendable (PCKShape, IndexedMesh) -> (PCKShape, String))? = nil) {
        guard !isBusy else { return }
        guard let working, isValid(working, model: model) else {
            model.message = "Erst einen Körper antippen."
            return
        }
        pendingSave?.cancel()
        pendingSave = nil
        let source: IndexedMesh = working.indexed
        let expected = working.shape
        let index = working.body
        let color = working.color
        isBusy = true
        model.message = "\(name) …"
        Task {
            // B8 (Build 41): OCCT auf dem großen Stapel (KernelThread, 32 MB) statt Task.detached (512 KB)
            let box = await KernelThread.value("PencilCAD.sculpt.rebuild") { () -> UncheckedBox<(IndexedMesh, String, PCKShape?)> in
                let (mesh, note) = change(source)
                guard let solid = MeshSolid.shape(from: mesh) else { return UncheckedBox((mesh, note, nil)) }
                guard let shapeChange else { return UncheckedBox((mesh, note, solid)) }
                let (changed, extra) = shapeChange(solid, mesh)
                return UncheckedBox((mesh, note.isEmpty ? extra : note + " · " + extra, changed))
            }
            self.isBusy = false
            let (mesh, note, shape) = box.value
            guard model.bodies.indices.contains(index), model.bodies[index].shape === expected else {
                self.discard(model: model, note: "Der Körper wurde inzwischen geändert.")
                return
            }
            guard let shape else {
                model.message = "\(name): Umwandeln in einen Körper fehlgeschlagen."
                return
            }
            var list = model.bodies
            list[index] = list[index].with(shape)
            model.commit(list, name: name)
            if shapeChange != nil {
                // Körper hat jetzt echte Flächen: Arbeitsnetz verwerfen, beim nächsten Antippen neu aufbauen
                self.working = nil
                self.base = nil
                self.body = nil
                self.triangleCount = 0
                model.message = note
                return
            }
            let updated = SculptMesh(body: index, shape: shape, color: color, indexed: mesh)
            self.working = updated
            self.base = nil
            self.generation = 0
            self.savedGeneration = 0
            self.triangleCount = updated.triangleCount
            model.message = shape.isClosedSolid ? note : note + " · Netz noch offen"
        }
    }
}

// MARK: - Viewport

extension ViewportView {
    /// Netz bearbeiten: Stift setzt auf einem Körper auf → Pinselstrich (true = Berührung gehört dem Pinsel).
    func sculptBegan(_ touch: UITouch) -> Bool {
        guard let workspace, workspace.tool == .meshSculpt, !workspace.sketch.isActive, let renderer,
              let ray = renderer.camera.ray(through: touch.location(in: self), viewSize: bounds.size) else { return false }
        guard workspace.sculpt.beginStroke(touch, origin: ray.origin, direction: ray.direction,
                                           model: workspace.model) else { return false }
        refresh()
        return true
    }

    func sculptMoved(_ touches: Set<UITouch>, event: UIEvent?) -> Bool {
        guard let workspace, let touch = workspace.sculpt.strokeTouch, touches.contains(touch),
              let renderer else { return false }
        // Zwischenpunkte des Stifts (bis 240 je Sekunde) für einen gleichmäßigen Strich
        let points: [UITouch] = event?.coalescedTouches(for: touch) ?? [touch]
        var samples: [SculptSample] = []
        for point in points {
            guard let ray = renderer.camera.ray(through: point.location(in: self), viewSize: bounds.size) else { continue }
            samples.append(SculptSample(origin: ray.origin, direction: ray.direction, pressure: ViewportView.sculptPressure(point)))
        }
        workspace.sculpt.moveStroke(samples, model: workspace.model)
        refresh()
        return true
    }

    func sculptEnded(_ touches: Set<UITouch>) -> Bool {
        guard let workspace, let touch = workspace.sculpt.strokeTouch, touches.contains(touch) else { return false }
        workspace.sculpt.endStroke(model: workspace.model)
        refresh()
        return true
    }

    func sculptHover(at location: CGPoint?) {
        guard let workspace, workspace.tool == .meshSculpt, let renderer else { return }
        let ray = location.flatMap { renderer.camera.ray(through: $0, viewSize: bounds.size) }
        workspace.sculpt.hover(origin: ray?.origin, direction: ray?.direction, model: workspace.model)
        refresh()
    }

    func addSculptOverlay(to groups: inout [LineGroup]) {
        guard let workspace else { return }
        // Build 70: offene Kanten rot (oben auf, damit man sie auch hinter dem Netz findet)
        if let round = workspace.sculpt.round {
            let lines: [[SIMD3<Float>]] = round.outline.map { line in line.map { SIMD3<Float>($0) } }
            groups.append(LineGroup(polylines: lines, color: SIMD3<Float>(0.1, 0.7, 0.3), width: 3, onTop: true))
        }
        if workspace.sculpt.showsOpenEdges {
            let open = workspace.sculpt.openEdgeLines()
            if !open.isEmpty {
                groups.append(LineGroup(polylines: open, color: SIMD3<Float>(0.92, 0.12, 0.12), width: 3, onTop: true))
            }
        }
        guard !workspace.sculpt.brushCircle.isEmpty else { return }
        groups.append(LineGroup(polylines: [workspace.sculpt.brushCircle], color: SIMD3<Float>(0.98, 0.45, 0.05),
                                width: 2, onTop: true))
    }

    /// Stiftdruck: 1 = normaler Druck; fester drücken verstärkt (Finger ohne Druck: 1).
    private static func sculptPressure(_ touch: UITouch) -> Float {
        guard touch.maximumPossibleForce > 0 else { return 1 }
        let force = Float(touch.force)
        return min(max(force, 0.25), 2.5)
    }
}

// MARK: - Karte

/// Karte unten: Pinselart, Radius, Stärke, Netz verfeinern/reduzieren, Löcher schließen.
struct MeshSculptCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sculpt: MeshSculpt

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label("Netz bearbeiten", systemImage: "paintbrush.pointed")
                        .font(.callout.weight(.semibold))
                    Picker("Pinsel", selection: $sculpt.mode) {
                        ForEach(SculptMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)
                    .hoverTip("Pinsel", "Anheben und Absenken schieben das Netz entlang der gemittelten Normale, Glätten mittelt mit den Nachbarpunkten, Abflachen zieht zur Ebene unter dem Pinsel.")
                    if sculpt.isBusy {
                        ProgressView()
                    }
                }
                if sculpt.mode == .recognize {
                    // Build 73: Rundung bzw. Bohrung nachbauen
                    HStack(spacing: 10) {
                        Text(sculpt.round?.title ?? "Rundung oder Bohrung antippen")
                            .font(.callout)
                        if let round = sculpt.round {
                            NumberField(title: round.isFillet ? "Radius" : "Durchmesser",
                                        value: round.isFillet ? sculpt.roundRadius : 2 * sculpt.roundRadius) { value in
                                guard value > 0 else { return }
                                sculpt.roundRadius = round.isFillet ? value : value / 2
                            }
                            Button("Übernehmen", systemImage: "checkmark") { sculpt.applyRound(model: model) }
                                .buttonStyle(.borderedProminent)
                                .disabled(sculpt.isBusy)
                                .hoverTip("Übernehmen", "Ersetzt die vielen Streifen durch eine echte Rundung bzw. einen echten Zylinder mit diesem Maß.")
                            Button("Verwerfen", systemImage: "xmark") { sculpt.clearRound() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text("Radius")
                    Slider(value: $sculpt.radius, in: 0.2...max(sculpt.maxRadius, 1))
                        .frame(width: 150)
                    Text(LengthUnit.current.format(sculpt.radius))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                    Text("Stärke")
                    Slider(value: $sculpt.strength, in: 0.05...1)
                        .frame(width: 120)
                        .hoverTip("Stärke", "Fester mit dem Stift drücken verstärkt den Pinsel zusätzlich.")
                    Text("\(Int((sculpt.strength * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button("Verfeinern", systemImage: "square.grid.3x3") { sculpt.refine(model: model) }
                        .hoverTip("Verfeinern", "Teilt lange Dreiecke, damit der Pinsel auch große ebene Flächen formen kann (Kanten länger als ein Drittel des Radius).")
                    Button("Reduzieren", systemImage: "triangle") { sculpt.reduce(model: model) }
                        .hoverTip("Dreiecke reduzieren", "Fasst Dreiecke zusammen, wo das Netz kaum gekrümmt ist (Ziel in Prozent der jetzigen Zahl).")
                    Stepper("auf \(Int(sculpt.reducePercent)) %", value: $sculpt.reducePercent, in: 10...90, step: 10)
                        .fixedSize()
                    Button("Löcher schließen", systemImage: "circle.dashed") { sculpt.closeHoles(model: model) }
                        .hoverTip("Löcher schließen", "Schließt offene Ränder des Netzes mit neuen Dreiecken, damit ein Volumenkörper entsteht.")
                    Button("Reparieren", systemImage: "wrench.and.screwdriver") { sculpt.repairAgain(model: model) }
                    Button("Zylinder", systemImage: "cylinder") { sculpt.trueCylinders(model: model) }
                        .hoverTip("Zylinder erkennen", "Ganz umlaufende Bohrungen und Zapfen werden echte Zylinderflächen statt vieler schmaler Dreiecke – danach lassen sie sich antippen, abrunden und fasen.")
                        .hoverTip("Netz reparieren", "Ganze Reparatur noch einmal: Punkte verschweißen, kaputte und doppelte Dreiecke entfernen, Normalen ausrichten, auch große Löcher schließen.")
                    Toggle("Offene Kanten", isOn: $sculpt.showsOpenEdges)
                        .toggleStyle(.button)
                        .hoverTip("Offene Kanten", "Zeigt Ränder des Netzes rot, an denen nur ein Dreieck hängt – dort ist das Netz nicht geschlossen.")
                }
                .buttonStyle(.bordered)
                .disabled(sculpt.body == nil || sculpt.isBusy)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    private var status: String {
        guard let index = sculpt.body, model.bodies.indices.contains(index) else {
            return "Körper antippen oder mit dem Stift darauf malen – fester drücken verstärkt."
        }
        let open = sculpt.openEdgeCount
        let closedText = open == 0 ? "geschlossen" : "\(open) offene Kanten (rot)"
        return "\(model.bodies[index].name): \(sculpt.triangleCount) Dreiecke, \(closedText) · jeder Strich ist ein Schritt zum Rückgängigmachen"
    }
}
