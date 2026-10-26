import Foundation
import simd
import SwiftUI

// Komponenten (Fahrplan Nr. 20, Vorbild SketchUp/Fusion 360): verknüpfte Kopien eines Körpers.
// Jede Instanz speichert ihre Weltgeometrie wie jeder Körper, dazu componentID und ihre Lage (placement,
// nur Drehen und Verschieben). Verschieben mit Kopieren und Muster führen die Lage mit. Ändert ein Schritt
// die Geometrie einer Instanz (Extrudieren, Rundung, Bohrung …), leitet commit die übrigen Instanzen daraus neu
// ab: Instanz j = Lage j · Lage(geändert)⁻¹ · geänderte Form.

extension simd_double4x4 {
    /// Verschiebung um v.
    static func translation(_ v: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(v.x, v.y, v.z, 1)
        return m
    }

    /// Drehung um die Achse durch origin (rechte Hand, wie PCKShape.rotated).
    static func rotation(origin: SIMD3<Double>, axis: SIMD3<Double>, angle: Double) -> simd_double4x4 {
        guard simd_length(axis) > 1e-12, abs(angle) > 1e-15 else { return matrix_identity_double4x4 }
        let r = simd_double3x3(simd_quatd(angle: angle, axis: simd_normalize(axis)))
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4(r.columns.0, 0)
        m.columns.1 = SIMD4(r.columns.1, 0)
        m.columns.2 = SIMD4(r.columns.2, 0)
        // x' = r (x − o) + o
        let t = origin - r * origin
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

extension SceneBody {
    /// Wie with(_:), nach einer starren Bewegung: die Lage einer Komponenten-Instanz wird mitgeführt.
    func with(_ shape: PCKShape, moving motion: simd_double4x4) -> SceneBody {
        var body = with(shape)
        if componentID != nil { body.placement = motion * placement }
        // Gewinde (ThreadNotes.swift) bewegen sich mit
        if let threads { body.threads = threads.map { $0.moved(by: motion) } }
        return body
    }

    /// Ohne Verknüpfung (z. B. gespiegelt: Spiegeln ist keine starre Bewegung).
    func unlinked() -> SceneBody {
        var body = self
        body.componentID = nil
        body.placement = matrix_identity_double4x4
        return body
    }

    /// Skaliert: Die Lage einer Instanz kennt nur Drehen und Verschieben (wie in Fusion 360, wo Skalieren
    /// die Platzierung nicht skaliert). Damit nicht alle Instanzen mitwachsen, wird eine skalierte Instanz zum
    /// eigenständigen Körper; die übrigen Instanzen bleiben unverändert verknüpft.
    func scaledInstance(_ shape: PCKShape) -> SceneBody {
        componentID == nil ? with(shape) : with(shape).unlinked()
    }

    /// Lage als 16 Zahlen (spaltenweise) zum Speichern.
    var placementValues: [Double] {
        let c = placement.columns
        return [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// Komponente aus gespeicherten Werten übernehmen (fehlende Werte = keine Komponente).
    func restoringComponent(_ id: UUID?, placement values: [Double]?) -> SceneBody {
        var body = self
        guard let id else { return body }
        body.componentID = id
        if let values, values.count == 16, values.allSatisfy(\.isFinite) {
            body.placement = simd_double4x4(SIMD4(values[0], values[1], values[2], values[3]),
                                            SIMD4(values[4], values[5], values[6], values[7]),
                                            SIMD4(values[8], values[9], values[10], values[11]),
                                            SIMD4(values[12], values[13], values[14], values[15]))
        }
        return body
    }
}

extension ModelStore {
    /// Anzahl der Instanzen der Komponente dieses Körpers (0 = keine Komponente).
    func componentInstanceCount(_ body: Int) -> Int {
        guard bodies.indices.contains(body), let id = bodies[body].componentID else { return 0 }
        return bodies.filter { $0.componentID == id }.count
    }

    /// Körper zu Komponenten machen; Kopien davon (Verschieben mit Kopieren, Muster) bleiben verknüpft.
    func makeComponent(_ indices: [Int]) {
        commitPreview()
        let chosen = indices.filter { bodies.indices.contains($0) && bodies[$0].componentID == nil }
        guard !chosen.isEmpty else {
            message = "Schon eine Komponente."
            return
        }
        var result = bodies
        for index in chosen {
            result[index].componentID = UUID()
            result[index].placement = matrix_identity_double4x4
        }
        commit(result, name: "Als Komponente")
        message = "Komponente: Kopien (Verschieben mit Kopieren, Muster) bleiben verknüpft – änderst du eine, ändern sich alle."
    }

    /// Hinweis beim Skalieren, wenn Komponenten-Instanzen dabei sind (sie werden eigenständig).
    func scaledComponentNote(_ indices: [Int]) -> String? {
        let linked = indices.filter { bodies.indices.contains($0) && bodies[$0].componentID != nil }
        guard !linked.isEmpty else { return nil }
        return linked.count == 1
            ? "Skalierte Instanz wird ein eigenständiger Körper – die übrigen Instanzen der Komponente bleiben, wie sie sind."
            : "Skalierte Instanzen werden eigenständige Körper – die übrigen Instanzen der Komponente bleiben, wie sie sind."
    }

    /// Verknüpfung lösen: der Körper wird wieder eigenständig.
    func unlinkComponent(_ indices: [Int]) {
        commitPreview()
        let chosen = indices.filter { bodies.indices.contains($0) && bodies[$0].componentID != nil }
        guard !chosen.isEmpty else { return }
        var result = bodies
        for index in chosen {
            result[index] = result[index].unlinked()
        }
        // Bleibt nur eine Instanz übrig, ist auch sie keine Komponente mehr
        for id in Set(bodies.compactMap(\.componentID)) {
            let rest = result.indices.filter { result[$0].componentID == id }
            if rest.count == 1 { result[rest[0]] = result[rest[0]].unlinked() }
        }
        commit(result, name: "Verknüpfung lösen")
    }

    /// Abgleich beim Übernehmen eines Schritts: Wurde die Geometrie einer Instanz geändert (neue Form, Lage
    /// unverändert, anderes Volumen), bekommen alle Instanzen dieser Komponente die neue Form in ihrer Lage.
    /// Unklare Fälle (Teilen in mehrere Körper, unterschiedlich geänderte Instanzen, Bewegung ohne bekannte
    /// Lage) lösen die Verknüpfung der betroffenen Körper, statt etwas zu raten.
    func syncedComponents(_ newBodies: [SceneBody]) -> (bodies: [SceneBody], note: String?) {
        guard newBodies.contains(where: { $0.componentID != nil }) else { return (newBodies, nil) }
        let oldShapes = Set(bodies.map { ObjectIdentifier($0.shape) })
        var result = newBodies
        var note: String?
        let ids = Set(result.compactMap(\.componentID))
        for id in ids {
            let members = result.indices.filter { result[$0].componentID == id }
            let oldMembers = bodies.indices.filter { bodies[$0].componentID == id }
            // Geänderte Formen, deren Lage zu einer bisherigen Instanz passt
            var edits: [(index: Int, old: Int)] = []
            for index in members where !oldShapes.contains(ObjectIdentifier(result[index].shape)) {
                if let old = oldMembers.first(where: { Self.samePlacement(bodies[$0].placement, result[index].placement) }) {
                    edits.append((index, old))
                }
            }
            guard !edits.isEmpty else { continue }
            // Eine Instanz in mehrere Körper geteilt: diese Teile werden eigenständig
            var counts: [Int: Int] = [:]
            for edit in edits { counts[edit.old, default: 0] += 1 }
            var real: [Int] = []
            for edit in edits {
                if counts[edit.old, default: 0] > 1 {
                    result[edit.index] = result[edit.index].unlinked()
                    note = "Geteilte Komponente: die Teile sind jetzt eigenständige Körper."
                    continue
                }
                switch Self.change(from: bodies[edit.old].shape, to: result[edit.index].shape) {
                case .none:
                    break
                case .geometry:
                    real.append(edit.index)
                case .moved:
                    // Bewegt, ohne dass die Lage bekannt ist (z. B. Druckausrichtung)
                    result[edit.index] = result[edit.index].unlinked()
                    note = "\(result[edit.index].name) wurde bewegt und ist jetzt nicht mehr verknüpft."
                }
            }
            guard let source = real.first else { continue }
            // Mehrere Instanzen unterschiedlich geändert (z. B. Schnitt trifft zwei verschieden): Verknüpfung lösen
            let volume = result[source].shape.volume
            let consistent = real.allSatisfy { abs(result[$0].shape.volume - volume) <= Self.volumeTolerance(volume) }
            guard consistent else {
                for index in real { result[index] = result[index].unlinked() }
                note = "Instanzen unterschiedlich geändert – ihre Verknüpfung wurde gelöst."
                continue
            }
            // Alle übrigen Instanzen aus der geänderten Form ableiten
            let sourceShape = result[source].shape
            let inverse = result[source].placement.inverse
            var failed = false
            for index in result.indices where index != source && result[index].componentID == id {
                let motion = result[index].placement * inverse
                if let shape = Self.transformed(sourceShape, by: motion) {
                    result[index] = result[index].with(shape)
                } else {
                    result[index] = result[index].unlinked()
                    failed = true
                }
            }
            if failed { note = "Nicht alle Instanzen ließen sich nachführen; sie sind jetzt eigenständig." }
        }
        // Komponenten mit nur noch einer Instanz bleiben Komponente (weitere Kopien möglich)
        return (result, note)
    }

    private enum ShapeChange { case none, geometry, moved }

    /// Art der Änderung: anderes Volumen = Geometrie, gleiches Volumen und anderer Schwerpunkt = bewegt.
    private static func change(from old: PCKShape, to new: PCKShape) -> ShapeChange {
        let v0 = old.volume, v1 = new.volume
        if abs(v1 - v0) > volumeTolerance(v0) { return .geometry }
        guard let c0 = old.centerOfMass?.map(\.doubleValue), let c1 = new.centerOfMass?.map(\.doubleValue),
              c0.count == 3, c1.count == 3 else { return .none }
        let size = max(cbrt(abs(v0)), 1)
        let distance = simd_distance(SIMD3(c0[0], c0[1], c0[2]), SIMD3(c1[0], c1[1], c1[2]))
        return distance > 1e-6 * size ? .moved : .none
    }

    private static func volumeTolerance(_ volume: Double) -> Double {
        max(abs(volume) * 1e-6, 1e-9)
    }

    private static func samePlacement(_ a: simd_double4x4, _ b: simd_double4x4) -> Bool {
        let scale = max(1, simd_length(SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)))
        for column in 0..<4 {
            let d = a[column] - b[column]
            let tolerance = column == 3 ? 1e-7 * scale : 1e-7
            if abs(d.x) > tolerance || abs(d.y) > tolerance || abs(d.z) > tolerance || abs(d.w) > tolerance {
                return false
            }
        }
        return true
    }

    /// Starre Bewegung (Drehung um den Ursprung, dann Verschiebung) auf einen Körper anwenden.
    private static func transformed(_ shape: PCKShape, by m: simd_double4x4) -> PCKShape? {
        let r = simd_double3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                               SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var result: PCKShape? = shape
        let q = simd_quatd(r)
        if abs(q.angle) > 1e-12, q.angle.isFinite, simd_length(q.axis) > 0.5 {
            result = result?.rotated(origin: [0, 0, 0], axis: simd_normalize(q.axis), angle: q.angle)
        }
        if simd_length(t) > 1e-12 {
            result = result?.translated(by: t)
        }
        return result
    }
}

/// Einträge im Kontextmenü eines Körpers (Browser „Ebenen“): Als Komponente bzw. Verknüpfung lösen.
struct ComponentMenuItems: View {
    @ObservedObject var model: ModelStore
    let index: Int

    var body: some View {
        if model.bodies.indices.contains(index) {
            if model.bodies[index].componentID == nil {
                Button("Als Komponente", systemImage: "shippingbox") { model.makeComponent([index]) }
            } else {
                Button("Verknüpfung lösen (\(model.componentInstanceCount(index)) Instanzen)",
                       systemImage: "link.badge.plus") { model.unlinkComponent([index]) }
            }
        }
    }
}
