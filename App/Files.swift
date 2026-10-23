import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stl = UTType(filenameExtension: "stl", conformingTo: .data) ?? .data
    static let stepFile = UTType(filenameExtension: "step", conformingTo: .data) ?? .data
    static let stpFile = UTType(filenameExtension: "stp", conformingTo: .data) ?? .data
}

/// Fertige Exportdaten (STL oder STEP) für den Datei-Export.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.stl, .stepFile] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
