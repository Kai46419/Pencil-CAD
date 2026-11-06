import Foundation
import simd

// MARK: - Umwandeln

/// Ergebnis eines Netzimports, im Hintergrund berechnet.
struct MeshImportResult {
    struct Part {
        var name: String
        var color: SIMD3<Float>?
        var shape: PCKShape
        var closed: Bool
    }

    var parts: [Part] = []
    var report = MeshRepairReport()
    var triangles = 0
    var error: String?
}

enum MeshImporter {
    /// Teile mit weniger Dreiecken (Splitter) fallen weg; mehr Teile als maxParts bleiben ein Körper.
    static let minimumPartTriangles = 4
    static let maxParts = 32

    /// Datei lesen, reparieren, bei Bedarf reduzieren und in Körper umwandeln (langsam: im Hintergrund aufrufen).
    static func convert(_ data: Data, name: String, fileExtension: String) -> MeshImportResult {
        var result = MeshImportResult()
        let objects: [ImportedMeshObject]
        do {
            objects = try MeshFileReader.read(data, name: name, fileExtension: fileExtension)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        let total = objects.reduce(0) { $0 + $1.soup.count / 3 }
        for object in objects {
            let repaired = MeshRepair.repair(soup: object.soup)
            var mesh = repaired.mesh
            var report = repaired.report
            // Anteil dieses Objekts an der Höchstzahl (mehrere Objekte teilen sich die Grenze)
            let share = max(1, object.soup.count / 3)
            let budget = max(2000, MeshSolid.maxTriangles * share / max(1, total))
            if mesh.triangles.count > budget {
                report.reducedFrom = mesh.triangles.count
                mesh = MeshRepair.simplify(mesh, target: budget)
                report.reducedTo = mesh.triangles.count
            }
            result.report.add(report)
            result.triangles += mesh.triangles.count
            let parts = MeshRepair.components(mesh).filter { $0.triangles.count >= minimumPartTriangles }
            if parts.count > 1, parts.count <= maxParts {
                for (index, part) in parts.enumerated() {
                    guard let shape = MeshSolid.shape(from: part) else { continue }
                    result.parts.append(MeshImportResult.Part(name: "\(object.name) \(index + 1)", color: object.color,
                                                              shape: shape, closed: shape.isClosedSolid))
                }
            } else if parts.count > maxParts {
                let shapes: [PCKShape] = parts.compactMap { MeshSolid.shape(from: $0) }
                if let combined = PCKShape.compound(shapes) {
                    let closed = shapes.allSatisfy { $0.isClosedSolid }
                    result.parts.append(MeshImportResult.Part(name: object.name, color: object.color, shape: combined,
                                                              closed: closed))
                }
            } else if let only = parts.first, let shape = MeshSolid.shape(from: only) {
                result.parts.append(MeshImportResult.Part(name: object.name, color: object.color, shape: shape,
                                                          closed: shape.isClosedSolid))
            }
        }
        if result.parts.isEmpty, result.error == nil {
            result.error = "Das Netz ließ sich nicht in einen Körper umwandeln."
        }
        return result
    }
}

extension ModelStore {
    /// STL- bzw. 3MF-Datei als Körper einfügen (Lesen und Umwandeln im Hintergrund). done läuft danach
    /// (z. B. Ansicht einpassen).
    func importMesh(from url: URL, done: (() -> Void)? = nil) {
        guard requireKernel() else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if accessing { url.stopAccessingSecurityScopedResource() }
        let fileExtension = url.pathExtension.lowercased()
        let kind = fileExtension == "3mf" ? "3MF" : "STL"
        guard let data else {
            message = "\(kind)-Datei konnte nicht gelesen werden."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        message = "\(kind) wird gelesen und in einen Körper umgewandelt …"
        // C4/N3 (Build 41): Import an diese Instanz und diesen Stand binden. Ein neuer Import, close() oder ein
        // gelöschter Ordner lassen das Ergebnis verfallen, statt später ein anderes bzw. gelöschtes Projekt zu
        // überschreiben. Ein früherer, noch laufender Import wird abgebrochen.
        meshImportTask?.cancel()
        meshImportGeneration += 1
        let generation = meshImportGeneration
        meshImportTask = Task { [weak self] in
            // B8: OCCT (MeshSolid/PCKShape) auf dem großen Stapel (KernelThread, 32 MB) statt Task.detached (512 KB)
            let box = await KernelThread.value("PencilCAD.meshImport") { () -> UncheckedBox<MeshImportResult> in
                UncheckedBox(MeshImporter.convert(data, name: name, fileExtension: fileExtension))
            }
            guard let self, !Task.isCancelled, generation == self.meshImportGeneration else { return }
            self.meshImportTask = nil
            guard self.canWriteProject || self.folder == nil else {
                // Projekt inzwischen geschlossen, neu geöffnet oder gelöscht: nichts übernehmen
                return
            }
            self.finishMeshImport(box.value, kind: kind)
            done?()
        }
    }

    private func finishMeshImport(_ result: MeshImportResult, kind: String) {
        guard result.error == nil, !result.parts.isEmpty else {
            message = result.error ?? "\(kind)-Import fehlgeschlagen."
            return
        }
        commitPreview()
        var list = bodies
        var number = bodies.count
        for part in result.parts {
            number += 1
            let color: SIMD3<Float> = part.color ?? SceneBody.palette[(number - 1) % SceneBody.palette.count]
            list.append(SceneBody(shape: part.shape, name: part.name, color: color))
        }
        commit(list, name: "\(kind) importieren")
        var notes: [String] = []
        let count = result.parts.count
        notes.append(count == 1 ? "\(kind) importiert (\(result.triangles) Dreiecke)"
                     : "\(kind) importiert: \(count) Körper (\(result.triangles) Dreiecke)")
        let repair = result.report.summary
        if !repair.isEmpty { notes.append(repair) }
        let open = result.parts.filter { !$0.closed }.count
        if open > 0 {
            notes.append(open == 1 ? "Netz nicht geschlossen – als Fläche eingefügt (Bohren und Vereinigen gehen erst geschlossen)"
                         : "\(open) Netze nicht geschlossen – als Flächen eingefügt")
        }
        message = notes.joined(separator: " · ")
    }
}
