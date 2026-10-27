import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Einfügen › Bild als Vorlage aus drei Quellen: Fotoalbum (PhotosPicker in WorkspaceView), Dateien (PNG, JPEG,
// HEIC, PDF-Seite 1) und Kamera. Alle Wege enden in WorkspaceView.insertImage(_:) – auf 2048 px verkleinert,
// Ausrichtung normalisiert, danach gleich kalibrieren.

/// Kamera als SwiftUI-Ansicht (UIImagePickerController, Quelle .camera).
struct CameraCapture: UIViewControllerRepresentable {
    /// Aufgenommenes Foto, nil bei Abbrechen
    let completion: (UIImage?) -> Void

    /// Gerät hat eine Kamera (sonst wird „Foto aufnehmen“ ausgegraut)
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            completion(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}

/// Kamera bildschirmfüllend mit kurzem Hinweis als Kapsel oben (verschwindet nach einigen Sekunden).
struct CameraCaptureView: View {
    let completion: (UIImage?) -> Void
    @State private var showsHint = true

    var body: some View {
        CameraCapture(completion: completion)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if showsHint {
                    Label("Möglichst senkrecht von oben fotografieren, ein bekanntes Maß (z. B. Lineal) mit ins Bild legen.",
                          systemImage: "camera.viewfinder")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.top, 64)
                        .padding(.horizontal, 24)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                withAnimation(.easeOut(duration: 0.4)) { showsHint = false }
            }
    }
}

/// Bilddateien für „Bild aus Dateien“ lesen.
enum ImageFileLoader {
    /// Erlaubte Typen im Dateiimporter
    static let contentTypes: [UTType] = [.image, .pdf]

    /// Datei ist ein Bild oder PDF (der gemeinsame Dateiimporter unterscheidet so die Wege)
    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // SVG zählt als Bild, wird aber als Skizze eingelesen (Workspace.importVectorFile)
        guard ext != "svg", let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// Bild aus PNG, JPEG, HEIC … oder die erste Seite eines PDF (weißer Hintergrund, längste Seite 2048 px).
    static func image(from url: URL) -> UIImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            return pdfFirstPage(url)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func pdfFirstPage(_ url: URL) -> UIImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds: CGRect = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Gedrehte Seiten (90°/270°): Breite und Höhe tauschen
        let turned: Bool = page.rotation % 180 != 0
        let width: CGFloat = turned ? bounds.height : bounds.width
        let height: CGFloat = turned ? bounds.width : bounds.height
        let factor: CGFloat = 2048 / max(width, height)
        let size = CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
