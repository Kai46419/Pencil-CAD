import Foundation

/// Hält den aktuellen Körper und die Undo-Historie.
/// Phase 1: feste Demo-Operationen. Ab Phase 2 kommen Skizzen mit dem Pencil dazu.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var mesh: Mesh = .empty
    @Published private(set) var revision = 0
    @Published var message: String?

    private var shape: PCKShape
    private var history: [PCKShape] = []
    private var holeCount = 0

    /// Bohrungspositionen für die Demo (mm, relativ zur Quadermitte).
    private let holePositions: [SIMD2<Double>] = [[0, 0], [-18, 0], [18, 0], [-18, 10], [18, 10], [-18, -10], [18, -10]]

    var canUndo: Bool { !history.isEmpty }

    init() {
        shape = PCKShape.box(width: 60, depth: 40, height: 20)
        remesh()
        if !PCKShape.kernelAvailable {
            message = "Fallback-Modus: OpenCASCADE nicht eingebunden (siehe README)."
        }
    }

    func newBlock() {
        apply(PCKShape.box(width: 60, depth: 40, height: 20), failure: "")
        holeCount = 0
    }

    func drillHole() {
        let p = holePositions[holeCount % holePositions.count]
        let tool = PCKShape.cylinder(x: p.x, y: p.y, z: -1, radius: 4, height: 1000)
        apply(shape.cutting(tool), failure: "Bohrung fehlgeschlagen.")
        holeCount += 1
    }

    func roundEdges() {
        apply(shape.filletingAllEdges(radius: 1.5), failure: "Rundung fehlgeschlagen (Radius zu groß?).")
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        shape = previous
        remesh()
    }

    func stlData() -> Data {
        mesh.binarySTL()
    }

    private func apply(_ result: PCKShape?, failure: String) {
        guard let result else {
            message = PCKShape.kernelAvailable ? failure : "Diese Funktion braucht OpenCASCADE."
            return
        }
        history.append(shape)
        shape = result
        message = nil
        remesh()
    }

    private func remesh() {
        mesh = Mesh(shape.triangulate(deflection: 0.05))
        revision += 1
    }
}
