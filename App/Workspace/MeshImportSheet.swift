import SwiftUI

// Build 69: Import-Fenster für STL/3MF (Einfügen › STL / 3MF). Zeigt Dreieckszahl und Größe und fragt, was
// eine STL-Datei nicht selbst weiß: Einheit, welche Achse oben ist, Lage (auf den Boden, in die Mitte) und wie
// fein das Netz bleiben soll (vorher wurde ungefragt auf 60.000 Dreiecke reduziert).

struct MeshImportSheet: View {
    let file: MeshImportFile
    let onImport: (MeshImportOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: MeshImportPreview?
    @State private var unitIndex = 0
    @State private var yUp = false
    @State private var placeOnGround = true
    @State private var center = true
    @State private var keepTogether = false
    /// Höchstzahl Dreiecke in Tausend (Regler)
    @State private var thousands: Double = Double(MeshSolid.maxTriangles) / 1000

    private static let minimumThousands: Double = 5
    private static let maximumThousands: Double = 250

    private var is3MF: Bool { file.fileExtension == "3mf" }
    private var unitScale: Double { MeshImportOptions.units[unitIndex].scale }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview {
                        if let error = preview.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else {
                            LabeledContent("Dreiecke", value: preview.triangles.formatted())
                            if preview.objects > 1 {
                                LabeledContent("Objekte", value: preview.objects.formatted())
                            }
                            if let size = preview.size {
                                LabeledContent("Größe", value: sizeText(size * unitScale))
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Datei wird gelesen …")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(file.name)
                }

                Section {
                    Picker("Einheit der Datei", selection: $unitIndex) {
                        ForEach(MeshImportOptions.units.indices, id: \.self) { index in
                            Text(MeshImportOptions.units[index].title).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Oben ist", selection: $yUp) {
                        Text("Z oben").tag(false)
                        Text("Y oben").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Größe und Ausrichtung")
                } footer: {
                    Text(is3MF
                         ? "3MF enthält die Einheit schon – „mm“ lässt die Größe wie in der Datei. „Y oben“ für Dateien aus Blender oder von Scannern, die liegend ankommen."
                         : "STL speichert keine Einheit. Ist das Teil viel zu klein, war die Datei wohl in Zoll oder cm. „Y oben“ für Dateien aus Blender oder von Scannern, die liegend ankommen.")
                }

                Section {
                    Toggle("Auf den Boden legen (Z = 0)", isOn: $placeOnGround)
                    Toggle("In die Mitte setzen", isOn: $center)
                    Toggle("Getrennte Teile als ein Körper", isOn: $keepTogether)
                } header: {
                    Text("Lage")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Höchstens")
                            Spacer()
                            Text("\((Int(thousands.rounded()) * 1000).formatted()) Dreiecke")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $thousands, in: Self.minimumThousands...Self.maximumThousands, step: 5)
                    }
                    if let note = reductionNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Detail")
                } footer: {
                    Text("Mehr Dreiecke bleiben genauer, machen Bohren, Schneiden und die Anzeige aber langsamer. Für Druckteile reichen meist 60.000–100.000.")
                }
            }
            .navigationTitle("\(file.kind) importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importieren") {
                        var options = MeshImportOptions()
                        options.unitScale = unitScale
                        options.yUp = yUp
                        options.placeOnGround = placeOnGround
                        options.center = center
                        options.keepTogether = keepTogether
                        options.maxTriangles = Int(thousands.rounded()) * 1000
                        dismiss()
                        onImport(options)
                    }
                    .disabled(preview?.error != nil)
                }
            }
        }
        .task {
            let data = file.data, name = file.name, fileExtension = file.fileExtension
            let read = await Task.detached(priority: .userInitiated) {
                MeshImporter.preview(data, name: name, fileExtension: fileExtension)
            }.value
            preview = read
            // Großes Netz: Regler so, dass nicht unnötig reduziert wird (bis 100.000)
            if read.triangles > 0 {
                let wanted = min(max(Double(read.triangles) / 1000, Self.minimumThousands), 100)
                thousands = max(thousands, (wanted / 5).rounded(.up) * 5)
            }
            // Winzig (unter 2 mm): vermutlich Zoll bzw. Meter
            if let size = read.size, !is3MF {
                let largest = max(size.x, size.y, size.z)
                if largest > 0, largest < 2 { unitIndex = MeshImportOptions.units.firstIndex { $0.title == "Zoll" } ?? 0 }
            }
        }
    }

    private var reductionNote: String? {
        guard let preview, preview.error == nil, preview.triangles > 0 else { return nil }
        let limit = Int(thousands.rounded()) * 1000
        guard preview.triangles > limit else { return "Wird nicht reduziert." }
        let percent = Int((Double(limit) / Double(preview.triangles) * 100).rounded())
        return "Wird auf etwa \(limit.formatted()) Dreiecke reduziert (\(percent) %)."
    }

    private func sizeText(_ size: SIMD3<Double>) -> String {
        let unit = LengthUnit.current
        return "\(unit.format(size.x)) × \(unit.format(size.y)) × \(unit.format(size.z))"
    }
}
