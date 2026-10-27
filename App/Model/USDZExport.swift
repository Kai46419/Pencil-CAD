import Foundation
import SceneKit
import UIKit

// USDZ für AR Quick Look (Modell im Raum ansehen) und zum Teilen: glatte Normalen aus der Kernel-Triangulierung,
// Farbe, Metall, Rauheit, Klarlack und Transparenz je Körper aus seiner Oberfläche (SurfaceFinish.swift; Muster wie
// Holz oder Carbon gibt es nur im Viewport). USDZ rechnet in Metern mit Y nach oben; PencilCAD in mm mit Z nach oben.

enum USDZExport {
    /// Körper als USDZ-Datei schreiben; false bei Fehler.
    static func write(_ bodies: [(name: String, appearance: SurfaceAppearance, mesh: Mesh)], to url: URL) -> Bool {
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
            let look = body.appearance
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(red: CGFloat(look.albedo.x), green: CGFloat(look.albedo.y),
                                                blue: CGFloat(look.albedo.z), alpha: 1)
            // Ganz matt (bisherige Darstellung ohne Oberfläche) wie früher mit 0,55
            let roughness: Float = look.roughness >= 0.99 ? 0.55 : max(look.roughness, 0.03)
            material.roughness.contents = NSNumber(value: roughness)
            material.metalness.contents = NSNumber(value: look.metallic ? 1.0 : 0.0)
            if look.clearcoat {
                material.clearCoat.contents = NSNumber(value: 1.0)
                material.clearCoatRoughness.contents = NSNumber(value: 0.05)
            }
            if look.transparent {
                material.transparency = 0.35
                material.blendMode = .alpha
            }
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
