import Foundation

enum ExtrudeMode: String, CaseIterable, Identifiable {
    case newBody = "Neuer Körper"
    case union = "Vereinigen"
    case cut = "Abziehen"

    var id: Self { self }
}

/// Hält die Körper der Szene und die Undo-Historie.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var mesh: Mesh = .empty
    @Published private(set) var revision = 0
    @Published var message: String?

    private var bodies: [PCKShape] = []
    private var history: [[PCKShape]] = []
    private var holeCount = 0

    /// Bohrungspositionen für die Demo (mm, relativ zur Quadermitte).
    private let holePositions: [SIMD2<Double>] = [[0, 0], [-18, 0], [18, 0], [-18, 10], [18, 10], [-18, -10], [18, -10]]

    var canUndo: Bool { !history.isEmpty }
    var isEmpty: Bool { bodies.isEmpty }

    init() {
        bodies = [PCKShape.box(width: 60, depth: 40, height: 20)]
        remesh()
        if !PCKShape.kernelAvailable {
            message = "Fallback-Modus: OpenCASCADE nicht eingebunden (siehe README)."
        }
    }

    func newBlock() {
        commit([PCKShape.box(width: 60, depth: 40, height: 20)])
        holeCount = 0
    }

    func clear() {
        commit([])
    }

    func drillHole() {
        let p = holePositions[holeCount % holePositions.count]
        cutAll(with: PCKShape.cylinder(x: p.x, y: p.y, z: -500, radius: 4, height: 1000),
               failure: "Bohrung fehlgeschlagen.")
        holeCount += 1
    }

    func roundEdges() {
        guard requireKernel() else { return }
        var result: [PCKShape] = []
        for body in bodies {
            guard let rounded = body.filletingAllEdges(radius: 1.5) else {
                message = "Rundung fehlgeschlagen (Radius zu groß?)."
                return
            }
            result.append(rounded)
        }
        commit(result)
    }

    func extrude(_ profile: SketchProfile, planeZ: Double, height: Double, mode: ExtrudeMode) {
        switch mode {
        case .newBody:
            guard let solid = profile.solid(z: planeZ, height: height) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            commit(bodies + [solid])
        case .union:
            guard requireKernel() else { return }
            guard let solid = profile.solid(z: planeZ, height: height) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            guard let last = bodies.last else {
                commit([solid])
                return
            }
            guard let fused = last.fusing(solid) else {
                message = "Vereinigen fehlgeschlagen."
                return
            }
            commit(Array(bodies.dropLast()) + [fused])
        case .cut:
            // Werkzeug minimal über die Skizzenebene hinaus verlängern, damit keine koplanaren Restflächen bleiben.
            let overlap = height < 0 ? 0.01 : -0.01
            guard let tool = profile.solid(z: planeZ + overlap, height: height - overlap) else {
                message = "Profil lässt sich nicht extrudieren."
                return
            }
            cutAll(with: tool, failure: "Abziehen fehlgeschlagen.")
        }
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        bodies = previous
        message = nil
        remesh()
    }

    func stlData() -> Data {
        mesh.binarySTL()
    }

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
        bodies = newBodies
        message = nil
        remesh()
    }

    private func remesh() {
        var combined = Mesh()
        for body in bodies {
            combined.append(Mesh(body.triangulate(deflection: 0.05)))
        }
        mesh = combined
        revision += 1
    }
}
