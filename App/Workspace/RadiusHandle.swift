import SwiftUI
import simd

// Rundung am Körper ändern (Kai): Zylinderfläche (z. B. aus einem extrudierten Skizzenbogen) im Auswahlwerkzeug
// antippen → Pfeil an der Fläche, Ziehen bzw. Eingabe ändert den Radius. Technisch „Fläche versetzen“ um die
// Radiusänderung: Nachbarflächen wachsen bzw. schrumpfen mit (wie Shapr3D).

/// Gewählte Zylinderfläche mit ihrem Ausgangsradius (bleibt während der Vorschau unverändert).
struct RadiusTarget {
    var face: FaceRef
    /// Punkt auf der Fläche (Fuß des Pfeils bei Versatz 0)
    var origin: SIMD3<Double>
    /// Aus dem Material heraus: beim Zapfen von der Achse weg, bei der Bohrung zur Achse hin
    var direction: SIMD3<Double>
    var radius: Double
    var convex: Bool
    var revision: Int
}

extension Workspace {
    /// Zylinderfläche, deren Radius sich gerade per Pfeil ändern lässt (nur Auswahlwerkzeug, genau eine Fläche).
    func radiusTarget() -> RadiusTarget? {
        guard !sketch.isActive, tool == .select, let face = model.selection, model.faceHandle == nil,
              model.extraFaces.isEmpty, model.selectedEdges.isEmpty, model.selectedRegions.isEmpty else {
            return nil
        }
        // Während der Vorschau zeigt das Netz schon den neuen Radius: den gemerkten Ausgangswert behalten
        if let cached = radiusCache, cached.face == face, model.hasPreview || cached.revision == model.revision {
            return cached
        }
        guard let cylinder = model.cylinder(of: face), let centroid = model.mesh.centroid(of: face) else {
            radiusCache = nil
            return nil
        }
        let axis = simd_normalize(cylinder.axis)
        let relative: SIMD3<Double> = SIMD3<Double>(centroid) - cylinder.origin
        let along: Double = simd_dot(relative, axis)
        var radial: SIMD3<Double> = relative - axis * along
        if simd_length(radial) < 1e-9 {
            // Schwerpunkt auf der Achse (voller Zylinder): irgendeine Richtung quer zur Achse
            let helper: SIMD3<Double> = abs(axis.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
            radial = simd_cross(axis, helper)
        }
        radial = simd_normalize(radial)
        let onSurface: SIMD3<Double> = cylinder.origin + axis * along + radial * cylinder.radius
        let target = RadiusTarget(face: face, origin: onSurface, direction: cylinder.convex ? radial : -radial,
                                  radius: cylinder.radius, convex: cylinder.convex, revision: model.revision)
        radiusCache = target
        radiusOffset = 0
        return target
    }

    /// Radius nach der jetzigen Änderung.
    var currentRadius: Double? {
        guard let target = radiusTarget() else { return nil }
        return target.convex ? target.radius + radiusOffset : target.radius - radiusOffset
    }

    /// Ziehpfeil der Zylinderfläche (Wert = Versatz aus dem Material heraus).
    var radiusHandle: DragHandle? {
        guard let target = radiusTarget() else { return nil }
        return DragHandle(kind: .radius, axisOrigin: SIMD3<Float>(target.origin), direction: SIMD3<Float>(target.direction),
                          value: radiusOffset, color: Workspace.handleBlue)
    }

    /// Versatz setzen (Pfeil); der Radius bleibt größer als 0,01 mm.
    func setRadiusOffset(_ value: Double) {
        guard let target = radiusTarget() else { return }
        var offset = value
        if target.convex {
            offset = max(offset, 0.01 - target.radius)
        } else {
            offset = min(offset, target.radius - 0.01)
        }
        guard offset != radiusOffset else { return }
        radiusOffset = offset
        model.previewOffsetFaces(distance: offset)
    }

    /// Radius direkt eingeben.
    func setRadius(_ radius: Double) {
        guard let target = radiusTarget(), radius > 0 else { return }
        let change = radius - target.radius
        setRadiusOffset(target.convex ? change : -change)
    }
}

/// Karte unten, wenn eine Zylinderfläche gewählt ist: Radius bzw. Durchmesser eingeben.
struct RadiusCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        if let target = workspace.radiusTarget(), let radius = workspace.currentRadius {
            Card {
                HStack(spacing: 16) {
                    Label(target.convex ? "Rundung" : "Bohrung", systemImage: "circle.dashed")
                        .font(.callout.weight(.semibold))
                    NumberField(title: "Radius", value: radius, width: 64) { workspace.setRadius($0) }
                    NumberField(title: "Ø", value: radius * 2, width: 64) { workspace.setRadius($0 / 2) }
                    if workspace.radiusOffset != 0 {
                        Button("Zurück", systemImage: "arrow.uturn.backward") { workspace.setRadius(target.radius) }
                            .labelStyle(.iconOnly)
                            .hoverTip("Ursprünglicher Radius", LengthUnit.current.format(target.radius))
                    }
                }
            }
        }
    }
}
