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

/// Einstellungen aus dem Import-Fenster (MeshImportSheet.swift, Build 69). STL hat keine Einheit: Dateien in
/// Zoll oder cm kamen sonst in falscher Größe an; viele Programme speichern Y oben statt Z oben.
struct MeshImportOptions {
    /// Faktor auf mm (1 = Datei in mm, 25,4 = Zoll …). 3MF bringt die Einheit selbst mit (dort meist 1).
    var unitScale: Double = 1
    /// Datei hat Y oben (Blender, viele Scanner): um +90° um X drehen, damit Z oben ist
    var yUp = false
    /// Unterseite auf Z = 0 legen
    var placeOnGround = false
    /// In X und Y in den Ursprung setzen
    var center = false
    /// Höchstzahl Dreiecke vor dem Umwandeln (mehr = genauer, aber langsamer)
    var maxTriangles: Int = MeshSolid.maxTriangles
    /// Getrennte Teile als EIN Körper (sonst je Teil ein Körper, bis maxParts)
    var keepTogether = false

    static let standard = MeshImportOptions()

    /// Einheiten für das Import-Fenster
    static let units: [(title: String, scale: Double)] = [("mm", 1), ("cm", 10), ("m", 1000), ("Zoll", 25.4)]
}

/// Kurzinfo vor dem Import (Dreiecke, Größe), damit Einheit und Detailstufe passend gewählt werden können.
struct MeshImportPreview {
    var triangles = 0
    var objects = 0
    /// Größe in Datei-Einheiten (bei STL ohne Einheit, bei 3MF schon in mm)
    var size: SIMD3<Double>?
    var error: String?
}

enum MeshImporter {
    /// Datei nur lesen und zählen (schnell genug für das Import-Fenster, im Hintergrund aufrufen).
    static func preview(_ data: Data, name: String, fileExtension: String) -> MeshImportPreview {
        var result = MeshImportPreview()
        do {
            let objects = try MeshFileReader.read(data, name: name, fileExtension: fileExtension)
            result.objects = objects.count
            result.triangles = objects.reduce(0) { $0 + $1.soup.count / 3 }
            var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
            for object in objects {
                for p in object.soup where p.x.isFinite && p.y.isFinite && p.z.isFinite {
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
            if low.x.isFinite, high.x.isFinite { result.size = high - low }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    /// Einheit, Ausrichtung und Lage auf alle Objekte anwenden (vor dem Reparieren).
    static func place(_ objects: [ImportedMeshObject], options: MeshImportOptions) -> [ImportedMeshObject] {
        let scale = options.unitScale > 0 && options.unitScale.isFinite ? options.unitScale : 1
        var placed: [ImportedMeshObject] = objects.map { object in
            var copy = object
            copy.soup = object.soup.map { p -> SIMD3<Double> in
                let q = options.yUp ? SIMD3<Double>(p.x, -p.z, p.y) : p
                return q * scale
            }
            return copy
        }
        guard options.placeOnGround || options.center else { return placed }
        var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
        for object in placed {
            for p in object.soup where p.x.isFinite && p.y.isFinite && p.z.isFinite {
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        guard low.x.isFinite, high.x.isFinite else { return placed }
        var shift = SIMD3<Double>(repeating: 0)
        if options.center {
            shift.x = -(low.x + high.x) / 2
            shift.y = -(low.y + high.y) / 2
        }
        if options.placeOnGround { shift.z = -low.z }
        for k in placed.indices {
            placed[k].soup = placed[k].soup.map { $0 + shift }
        }
        return placed
    }

    /// Teile mit weniger Dreiecken (Splitter) fallen weg; mehr Teile als maxParts bleiben ein Körper.
    static let minimumPartTriangles = 4
    static let maxParts = 32

    /// Datei lesen, reparieren, bei Bedarf reduzieren und in Körper umwandeln (langsam: im Hintergrund aufrufen).
    static func convert(_ data: Data, name: String, fileExtension: String,
                        options: MeshImportOptions = .standard) -> MeshImportResult {
        var result = MeshImportResult()
        let objects: [ImportedMeshObject]
        do {
            objects = place(try MeshFileReader.read(data, name: name, fileExtension: fileExtension), options: options)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        let limit = max(1000, options.maxTriangles)
        let total = objects.reduce(0) { $0 + $1.soup.count / 3 }
        for object in objects {
            let repaired = MeshRepair.repair(soup: object.soup)
            var mesh = repaired.mesh
            var report = repaired.report
            // Anteil dieses Objekts an der Höchstzahl (mehrere Objekte teilen sich die Grenze)
            let share = max(1, object.soup.count / 3)
            let budget = max(1000, limit * share / max(1, total))
            if mesh.triangles.count > budget {
                report.reducedFrom = mesh.triangles.count
                mesh = MeshRepair.simplify(mesh, target: budget)
                report.reducedTo = mesh.triangles.count
            }
            result.report.add(report)
            result.triangles += mesh.triangles.count
            let parts = MeshRepair.components(mesh).filter { $0.triangles.count >= minimumPartTriangles }
            if parts.count > 1, parts.count <= maxParts, !options.keepTogether {
                for (index, part) in parts.enumerated() {
                    guard let shape = MeshSolid.shape(from: part) else { continue }
                    result.parts.append(MeshImportResult.Part(name: "\(object.name) \(index + 1)", color: object.color,
                                                              shape: shape, closed: shape.isClosedSolid))
                }
            } else if parts.count > 1 {
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
        guard let file = MeshImportFile(url: url) else {
            message = "\(url.pathExtension.lowercased() == "3mf" ? "3MF" : "STL")-Datei konnte nicht gelesen werden."
            return
        }
        importMesh(file, options: .standard, done: done)
    }

    /// Bereits gelesene Datei mit den Einstellungen aus dem Import-Fenster einfügen (Build 69).
    func importMesh(_ file: MeshImportFile, options: MeshImportOptions, done: (() -> Void)? = nil) {
        guard requireKernel() else { return }
        let data = file.data, name = file.name, fileExtension = file.fileExtension
        let kind = fileExtension == "3mf" ? "3MF" : "STL"
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
                UncheckedBox(MeshImporter.convert(data, name: name, fileExtension: fileExtension, options: options))
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
            notes.append("rote offene Kanten und „Reparieren“ unter Ändern › Netz bearbeiten")
        }
        message = notes.joined(separator: " · ")
    }
}

/// Gelesene Netzdatei (Daten schon geladen, damit das Import-Fenster ohne Dateizugriff auskommt).
struct MeshImportFile: Identifiable {
    let id = UUID()
    var data: Data
    var name: String
    var fileExtension: String

    init(data: Data, name: String, fileExtension: String) {
        self.data = data
        self.name = name
        self.fileExtension = fileExtension.lowercased()
    }

    init?(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard let data else { return nil }
        self.init(data: data, name: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension)
    }

    var kind: String { fileExtension == "3mf" ? "3MF" : "STL" }
}
