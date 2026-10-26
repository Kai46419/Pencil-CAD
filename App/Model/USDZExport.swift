import Foundation
import SceneKit
import UIKit

// USDZ für AR Quick Look (Modell im Raum ansehen) und zum Teilen: glatte Normalen aus der Kernel-Triangulierung,
// Farbe je Körper. USDZ rechnet in Metern mit Y nach oben; PencilCAD in mm mit Z nach oben.

enum USDZExport {
    /// Körper als USDZ-Datei schreiben; false bei Fehler.
    static func write(_ bodies: [(name: String, color: SIMD3<Float>, mesh: Mesh)], to url: URL) -> Bool {
        let scene = SCNScene()
        let root = SCNNode()
        // mm → m und Z oben → Y oben (−90° um X)
        root.scale = SCNVector3(0.001, 0.001, 0.001)
        root.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(root)
        for body in bodies where body.mesh.triangleCount > 0 {
            let vertices = body.mesh.vertices
            let positions = vertices.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) }
            let normals = vertices.map { SCNVector3($0.normal.x, $0.normal.y, $0.normal.z) }
            let element = SCNGeometryElement(indices: body.mesh.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                                       elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(red: CGFloat(body.color.x), green: CGFloat(body.color.y),
                                                blue: CGFloat(body.color.z), alpha: 1)
            material.roughness.contents = 0.55
            material.metalness.contents = 0.0
            material.isDoubleSided = true
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = body.name
            root.addChildNode(node)
        }
        try? FileManager.default.removeItem(at: url)
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }
}
