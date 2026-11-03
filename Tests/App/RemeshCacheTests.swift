import XCTest
import simd
@testable import PencilCAD

@MainActor
final class RemeshCacheTests: XCTestCase {
    func testPreviewOfSecondBodyKeepsFirstBodyMeshUnchanged() throws {
        let model = ModelStore(folder: nil)
        let first = SceneBody(shape: PCKShape.box(width: 20, depth: 20, height: 20),
                              name: "Erster", color: SceneBody.defaultColor)
        let secondShape = try XCTUnwrap(PCKShape.box(width: 10, depth: 10, height: 10)
            .translated(by: [40, 0, 0]))
        let second = SceneBody(shape: secondShape, name: "Zweiter", color: SceneBody.defaultColor)
        model.commit([first, second], name: "Testkörper")

        let firstMesh = Mesh(first.shape.triangulate(deflection: 0.05), body: 0,
                             color: first.renderColor)
        let original = model.mesh
        let changed = try XCTUnwrap(second.shape.translated(by: [5, 0, 0]))
        model.showPreview([first, second.with(changed)], name: "Zweiten bewegen")

        XCTAssertEqual(model.lastRemeshReuseCount, 1)
        XCTAssertEqual(Array(model.mesh.vertices.prefix(firstMesh.vertices.count)).map(\.position),
                       Array(original.vertices.prefix(firstMesh.vertices.count)).map(\.position))
        XCTAssertEqual(Array(model.mesh.vertices.prefix(firstMesh.vertices.count)).map(\.normal),
                       Array(original.vertices.prefix(firstMesh.vertices.count)).map(\.normal))
        XCTAssertEqual(Array(model.mesh.vertices.prefix(firstMesh.vertices.count)).map(\.color),
                       Array(original.vertices.prefix(firstMesh.vertices.count)).map(\.color))
        XCTAssertEqual(Array(model.mesh.indices.prefix(firstMesh.indices.count)),
                       Array(original.indices.prefix(firstMesh.indices.count)))
        XCTAssertEqual(Array(model.mesh.triangleFaces.prefix(firstMesh.triangleFaces.count)),
                       Array(original.triangleFaces.prefix(firstMesh.triangleFaces.count)))
        XCTAssertEqual(Array(model.mesh.edges.prefix(firstMesh.edges.count)),
                       Array(original.edges.prefix(firstMesh.edges.count)))
        XCTAssertEqual(Array(model.mesh.edgeRefs.prefix(firstMesh.edgeRefs.count)),
                       Array(original.edgeRefs.prefix(firstMesh.edgeRefs.count)))
    }

    func testReorderAndAppearanceChangesDoNotReuseWrongBodyMesh() throws {
        let model = ModelStore(folder: nil)
        let first = SceneBody(shape: PCKShape.box(width: 20, depth: 20, height: 20),
                              name: "Erster", color: SceneBody.defaultColor)
        let second = SceneBody(shape: try XCTUnwrap(PCKShape.box(width: 8, depth: 8, height: 8)
            .translated(by: [40, 0, 0])), name: "Zweiter", color: SceneBody.defaultColor)
        model.commit([first, second], name: "Testkörper")

        model.showPreview([second, first], name: "Reihenfolge")
        XCTAssertEqual(model.lastRemeshReuseCount, 0)
        XCTAssertTrue(model.mesh.triangleFaces.contains { $0.body == 0 })
        XCTAssertTrue(model.mesh.triangleFaces.contains { $0.body == 1 })

        var recolored = first
        recolored.color = [0.9, 0.1, 0.1]
        model.showPreview([second, recolored], name: "Farbe")
        XCTAssertEqual(model.lastRemeshReuseCount, 1)
        let expected = recolored.renderColor
        let coloredVertices = model.mesh.triangleIndices(ofBody: 1).map { model.mesh.vertices[Int($0)] }
        XCTAssertFalse(coloredVertices.isEmpty)
        XCTAssertTrue(coloredVertices.allSatisfy { $0.color == expected })

        var hidden = second
        hidden.isHidden = true
        model.showPreview([hidden, recolored], name: "Sichtbarkeit")
        XCTAssertEqual(model.lastRemeshReuseCount, 1)
        XCTAssertFalse(model.mesh.triangleFaces.contains { $0.body == 0 })
        model.showPreview([second, recolored], name: "Wieder sichtbar")
        XCTAssertEqual(model.lastRemeshReuseCount, 1)
        XCTAssertTrue(model.mesh.triangleFaces.contains { $0.body == 0 })

        model.showPreview([second, recolored], name: "Extrudieren")
        XCTAssertEqual(model.lastRemeshReuseCount, 0, "Andere Deflection braucht neue Netze")
        model.showPreview([second, recolored], name: "Extrudieren")
        XCTAssertEqual(model.lastRemeshReuseCount, 2)
        model.showPreview([second, recolored], name: "Normale Vorschau")
        XCTAssertEqual(model.lastRemeshReuseCount, 0)

        var movedPlacement = recolored
        movedPlacement.placement = .translation([1, 0, 0])
        model.showPreview([second, movedPlacement], name: "Andere Platzierung")
        XCTAssertEqual(model.lastRemeshReuseCount, 1)
    }
}
