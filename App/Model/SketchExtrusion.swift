import Foundation
import simd

// MARK: Profile für den Kernel

/// Außenkontur und Löcher eines Bereichs als Kernel-Kodierung, um offset entlang der Normale verschoben.
func profileWires(_ region: SketchRegion, plane: SketchPlane, offset: Double = 0) -> [[NSNumber]] {
    let base = plane.normal * offset
    let world = { (p: Point2) -> [NSNumber] in
        let w = plane.world(p) + base
        return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
    }
    return ([region.outer] + region.holes).map { $0.code(normal: plane.normal, xAxis: plane.u, world: world) }
}

/// Körper aus Bereichen einer Skizze. Beim Abziehen beginnt das Werkzeug minimal außerhalb,
/// damit keine hauchdünnen Restflächen bleiben. taper: Verjüngungswinkel in Grad (Seitenflächen geneigt).
func extrudeRegions(_ chosen: [SketchRegion], plane: SketchPlane, distance: Double, mode: ExtrudeMode,
                    direction: ExtrudeDirection = .oneSide, secondDistance: Double = 0, taper: Double = 0) -> PCKShape? {
    guard !chosen.isEmpty, distance != 0, distance.isFinite, secondDistance.isFinite, taper.isFinite,
          abs(taper) < 90 else { return nil }
    guard PCKShape.kernelAvailable || (abs(taper) < 1e-9 && chosen.allSatisfy({ $0.holes.isEmpty })) else { return nil }
    // Neuer Körper: jeder Bereich einzeln (eigener Körper). Sonst bzw. bei sehr vielen Bereichen angrenzende
    // (z. B. Zähne einer Gewindestange) als ein Profil: keine Vereinigung vieler Prismen
    let regions = SketchRegionMerge.forExtrusion(chosen, mode: mode)
    let sign = plane.extrusionSign(mode: mode)
    guard let span = ExtrusionSpan.make(distance: distance, direction: direction, secondDistance: secondDistance,
                                       sign: sign, isCut: mode == .cut) else { return nil }
    let from = span.start, length = span.length
    let vector = plane.normal * length
    var shapes: [PCKShape] = []
    for region in regions {
        let shape: PCKShape?
        if PCKShape.kernelAvailable {
            if abs(taper) > 1e-9 {
                shape = PCKShape.draftPrism(profileWires: profileWires(region, plane: plane, offset: from),
                                            direction: vector, angle: taper)
            } else {
                shape = holedPrism(region, plane: plane, from: from, length: length)
                    ?? PCKShape.prism(profileWires: profileWires(region, plane: plane, offset: from), direction: vector)
            }
        } else {
            let xyz = region.polygon.flatMap { p -> [NSNumber] in
                let w = plane.world(p) + plane.normal * from
                return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
            }
            shape = PCKShape.prism(pointsXYZ: xyz, direction: vector)
        }
        guard let shape else { return nil }
        shapes.append(shape)
    }
    return PCKShape.compound(shapes)
}

/// Ringe und Bereiche mit Löchern: Außenkontur voll extrudieren und die Löcher als etwas längere
/// Prismen abziehen. Robuster als eine Fläche mit Lochdrähten, deren Umlaufrichtung (Ellipsen,
/// Splines) der Kernel sonst selbst erraten muss. nil ohne Löcher oder wenn der Kernel scheitert.
private func holedPrism(_ region: SketchRegion, plane: SketchPlane, from: Double, length: Double) -> PCKShape? {
    guard !region.holes.isEmpty, length != 0 else { return nil }
    let outer = SketchRegion(outer: region.outer, holes: [], polygon: region.polygon, area: region.area)
    guard var body = PCKShape.prism(profileWires: profileWires(outer, plane: plane, offset: from),
                                    direction: plane.normal * length) else { return nil }
    let overshoot = 0.5 * (length > 0 ? 1.0 : -1.0)
    for hole in region.holes {
        let tool = SketchRegion(outer: hole, holes: [], polygon: hole.polygon, area: abs(signedArea(hole.polygon)))
        guard let prism = PCKShape.prism(profileWires: profileWires(tool, plane: plane, offset: from - overshoot),
                                         direction: plane.normal * (length + 2 * overshoot)),
              let cut = body.cutting(prism) else { return nil }
        body = cut
    }
    return body
}

/// Dreiecke (Weltpunkte, je drei) zum Einfärben eines Bereichs.
func regionTriangles(_ region: SketchRegion, plane: SketchPlane) -> [SIMD3<Float>] {
    if region.holes.isEmpty, PCKShape.kernelAvailable, let face = PCKShape.face(profileWires: profileWires(region, plane: plane)) {
        let mesh = Mesh(face.triangulate(deflection: 0.05), body: -1)
        return mesh.indices.map { mesh.vertices[Int($0)].position }
    }
    // Mit Löchern (Ringe) oder ohne Kernel: Polygon mit Löchern in Ohren zerlegen
    let triangles = triangulate(outer: region.polygon, holes: region.holes.map(\.polygon))
    return triangles.map { SIMD3<Float>(plane.world($0)) }
}
