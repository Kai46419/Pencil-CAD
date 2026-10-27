import CoreGraphics
import simd

// Griff des Werkzeugs „Verschieben/Rotieren“ (Kai: „Die Kreise sind ein bisschen zu groß gewählt“).
// Vorbilder (nur Doku bzw. offener Quelltext):
// - Blender (Quelltext, Transform-Gizmo / gizmo_types dial3d): Größe in Bildschirmpunkten (U.gizmo_size, 75 px),
//   unabhängig von Zoom und Objektgröße; beim Drehen voller Kreis mit abgeblendeter Rückseite, überstrichener
//   Winkel als halbtransparentes Kreissegment; Griff unter dem Zeiger wird hervorgehoben, beim Ziehen bleibt nur
//   der gegriffene sichtbar.
// - Fusion 360 (Hilfe „Move/Copy“): Drehgriffe als kurze Bögen zwischen den Achsenpfeilen, Winkel als Wertfeld
//   am Griff. Shapr3D (Hilfe „Move/Rotate“): Pfeile und Drehbögen fester Bildschirmgröße, Winkel rastet ein.
// - FreeCAD (Quelltext, SoFCCSysDragger): schlanke Drehbögen, feste Bildschirmgröße.
enum TransformGizmo {
    /// Radius der Drehbögen in Bildschirmpunkten (Pfeile sind 64 pt lang, die Bögen liegen knapp außerhalb)
    static let ringRadius: Double = 72
    /// Halbe Spannweite eines Bogens (Bogenmaß): 60° im Viertel zur Kamera, berührt die Achsenpfeile nicht
    static let arcHalfSpan: Double = 30 * .pi / 180
    /// Strichbreite ruhend bzw. unter dem Stift / gegriffen (Punkte)
    static let lineWidth: Float = 2
    static let activeWidth: Float = 3.5
    /// Unsichtbare Trefferzone um Bögen (Punkte), reicht für Finger und Stift
    static let hitDistance: CGFloat = 22
    /// Ebenengriffe: Abstand von der Mitte und Kantenlänge (Punkte)
    static let planeOffset: Double = 16
    static let planeSize: Double = 15
    /// Rasterstriche beim Drehen (Grad), passend zum Einrasten
    static let tickStep: Double = 15

    /// Mittelwinkel des Viertels der Ringebene (Basis e1, e2), das zur Kamera zeigt; fest je Viertel, damit der
    /// Bogen beim Drehen der Ansicht nicht wandert.
    static func facingAngle(e1: SIMD3<Double>, e2: SIMD3<Double>, toward: SIMD3<Double>) -> Double {
        let x: Double = simd_dot(e1, toward) >= 0 ? 1 : -1
        let y: Double = simd_dot(e2, toward) >= 0 ? 1 : -1
        return atan2(y, x)
    }

    /// Farbe zum Viewport-Hintergrund hin abgeblendet (Rückseite des Rings).
    static func faded(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let background = SIMD3<Float>(repeating: 0.845)
        return color * 0.4 + background * 0.6
    }

    /// Aufgehellte Farbe für den Griff unter dem Stift bzw. den gegriffenen Griff.
    static func highlighted(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let white = SIMD3<Float>(repeating: 1)
        return color * 0.7 + white * 0.3
    }
}

/// Griff des Verschieben-Werkzeugs unter dem Stift (Apple Pencil Hover).
enum GizmoPart: Equatable {
    case arrow(HandleKind)
    case plane(Int)
    case ring(Int)
}
