import Foundation
import simd

enum ExtrudeMode: String, CaseIterable, Identifiable {
    case newBody = "Neuer Körper"
    case union = "Vereinigen"
    case cut = "Abziehen"

    var id: Self { self }
}

enum EdgeOperation: String, Identifiable {
    case fillet = "Runden"
    case chamfer = "Fase"

    var id: Self { self }
}

/// Hält die Körper der Szene, Auswahl, Undo/Redo und das automatische Speichern.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var mesh: Mesh = .empty
    @Published private(set) var revision = 0
    @Published private(set) var selection: FaceRef?
    @Published private(set) var selectionIndices: [UInt32] = []
    @Published private(set) var selectionRevision = 0
    @Published var message: String?

    private var bodies: [PCKShape] = []
    private var history: [[PCKShape]] = []
    private var future: [[PCKShape]] = []

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var isEmpty: Bool { bodies.isEmpty }

    private static var autosaveURL: URL {
        URL.documentsDirectory.appending(path: "Autosave.step")
    }

    init() {
        if PCKShape.stepAvailable,
           let restored = PCKShape.readSTEP(path: Self.autosaveURL.path(percentEncoded: false)) {
            bodies = restored
        } else {
            bodies = [PCKShape.box(width: 60, depth: 40, height: 20)]
        }
        remesh()
    }

    // MARK: Szene

    func newBlock() {
        commit(bodies + [PCKShape.box(width: 60, depth: 40, height: 20)])
    }

    func clear() {
        commit([])
    }

    func deleteSelectedBody() {
        guard let selection, bodies.indices.contains(selection.body) else { return }
        var result = bodies
        result.remove(at: selection.body)
        commit(result)
    }

    // MARK: Auswahl

    func select(_ face: FaceRef?) {
        selection = face
        selectionIndices = face.map { mesh.triangleIndices(of: $0) } ?? []
        selectionRevision += 1
    }

    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (face: FaceRef, point: SIMD3<Float>)? {
        mesh.pick(origin: origin, direction: direction)
    }

    /// Skizzenebene auf einer planaren Fläche; nil bei gekrümmten Flächen.
    func plane(of face: FaceRef) -> SketchPlane? {
        guard bodies.indices.contains(face.body),
              let values = bodies[face.body].plane(ofFace: face.face)?.map(\.doubleValue),
              values.count == 6 else { return nil }
        return SketchPlane(point: SIMD3(values[0], values[1], values[2]),
                           normal: SIMD3(values[3], values[4], values[5]), isOnFace: true, sourceBody: face.body)
    }

    // MARK: Modellieren

    func extrude(_ profile: SketchProfile, on plane: SketchPlane, distance: Double, mode: ExtrudeMode) {
        switch mode {
        case .newBody:
            guard let solid = profile.solid(on: plane, from: 0, to: distance) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            commit(bodies + [solid])
        case .union:
            guard requireKernel() else { return }
            guard let solid = profile.solid(on: plane, from: 0, to: distance) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            // Mit dem Körper der Skizzenfläche vereinigen, sonst mit dem zuletzt erzeugten.
            let target = plane.sourceBody.flatMap { bodies.indices.contains($0) ? $0 : nil } ?? bodies.indices.last
            guard let target else {
                commit([solid])
                return
            }
            guard let fused = bodies[target].fusing(solid) else {
                message = "Vereinigen fehlgeschlagen."
                return
            }
            var result = bodies
            result[target] = fused
            commit(result)
        case .cut:
            // Auf einer Fläche geht „Abziehen“ ins Material (gegen die Normale), auf der Bodenebene nach oben.
            // Das Werkzeug beginnt minimal außerhalb, damit keine hauchdünnen Restflächen bleiben.
            let into: Double = plane.isOnFace ? -1 : 1
            guard let tool = profile.solid(on: plane, from: -into * 0.01, to: into * distance) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            cutAll(with: tool, failure: "Abziehen fehlgeschlagen.")
        }
    }

    func applyEdgeOperation(_ operation: EdgeOperation, value: Double) {
        guard requireKernel() else { return }
        guard let selection, bodies.indices.contains(selection.body) else {
            message = "Erst eine Fläche antippen. Deren Kanten werden bearbeitet."
            return
        }
        let body = bodies[selection.body]
        let result: PCKShape? = switch operation {
        case .fillet: body.filletingEdges(ofFace: selection.face, radius: value)
        case .chamfer: body.chamferingEdges(ofFace: selection.face, distance: value)
        }
        guard let result else {
            message = "\(operation.rawValue) fehlgeschlagen (Wert zu groß?)."
            return
        }
        var newBodies = bodies
        newBodies[selection.body] = result
        commit(newBodies)
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(bodies)
        bodies = previous
        afterChange()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(bodies)
        bodies = next
        afterChange()
    }

    // MARK: Dateien

    func stlData() -> Data {
        mesh.binarySTL()
    }

    func stepData() -> Data? {
        guard PCKShape.stepAvailable else {
            message = "STEP braucht OpenCASCADE (siehe README)."
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        guard PCKShape.writeSTEP(bodies, path: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url) else {
            message = "STEP-Export fehlgeschlagen."
            return nil
        }
        return data
    }

    func importSTEP(from url: URL) {
        guard PCKShape.stepAvailable else {
            message = "STEP braucht OpenCASCADE (siehe README)."
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let shapes = PCKShape.readSTEP(path: url.path(percentEncoded: false)) else {
            message = "STEP-Datei konnte nicht gelesen werden."
            return
        }
        commit(bodies + shapes)
    }

    // MARK: Intern

    private func cutAll(with tool: PCKShape, failure: String) {
        guard requireKernel() else { return }
        var result: [PCKShape] = []
        for body in bodies {
            guard let cut = body.cutting(tool) else {
                message = failure
                return
            }
            result.append(cut)
        }
        commit(result)
    }

    private func requireKernel() -> Bool {
        if !PCKShape.kernelAvailable {
            message = "Diese Funktion braucht OpenCASCADE (siehe README)."
        }
        return PCKShape.kernelAvailable
    }

    private func commit(_ newBodies: [PCKShape]) {
        history.append(bodies)
        future.removeAll()
        bodies = newBodies
        afterChange()
    }

    private func afterChange() {
        message = nil
        remesh()
        select(nil)
        autosave()
    }

    private func remesh() {
        var combined = Mesh()
        for (index, body) in bodies.enumerated() {
            combined.append(Mesh(body.triangulate(deflection: 0.05), body: index))
        }
        mesh = combined
        revision += 1
    }

    private func autosave() {
        guard PCKShape.stepAvailable else { return }
        let path = Self.autosaveURL.path(percentEncoded: false)
        if bodies.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            _ = PCKShape.writeSTEP(bodies, path: path)
        }
    }
}
