import simd
import UIKit

// Darstellung der Wertfelder beim Zeichnen (SolidCraft-Klickwerkzeuge: Linie, Rechteck, Kreis, Bogen, Polygon …;
// Felder „box-<Schlüssel>“ aus SketchDimBoxes.swift). Kai: feine, kleine Schrift, dünne Maßlinie und Pfeile, neutral
// gedämpftes Grau auf Anthrazit statt Rot. Grün erst, wenn ein getippter Wert bestätigt (gesperrt) ist, Rot nur bei
// einem Fehler. Die bleibenden Skizzenmaße behalten ihr Aussehen.

enum LiveDimensionStyle {
    /// Zustand eines Wertfelds beim Zeichnen
    enum State {
        /// folgt dem Stift (live)
        case free
        /// wird gerade getippt, noch nicht bestätigt
        case editing
        /// bestätigt und gesperrt
        case locked
        /// getippter Wert ungültig (Formel, Bereich)
        case conflict
    }

    /// Feine Schrift der Wertfelder
    static let font = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .light)
    static let fieldHeight: CGFloat = 20
    static let borderWidth: CGFloat = 0.5
    static let cornerRadius: CGFloat = 4

    // MARK: Farben der Felder (UIKit, folgen dem Farbschema)

    static let text = SketchTheme.dynamic(light: UIColor(white: 0.28, alpha: 1), dark: SketchTheme.uiRGB(196, 200, 207))
    static let background = SketchTheme.dynamic(light: UIColor(white: 1, alpha: 0.88),
                                                dark: SketchTheme.uiRGB(36, 39, 46, 0.88))
    static let border = SketchTheme.dynamic(light: UIColor(white: 0.74, alpha: 1), dark: SketchTheme.uiRGB(78, 84, 96))
    /// Rahmen beim Tippen: etwas heller, damit man sieht, welches Feld die Eingabe bekommt
    static let borderEditing = SketchTheme.dynamic(light: UIColor(white: 0.5, alpha: 1),
                                                   dark: SketchTheme.uiRGB(150, 156, 168))
    /// Offenes Schloss: gedämpft
    static let lockFree = SketchTheme.dynamic(light: UIColor(white: 0.55, alpha: 1), dark: SketchTheme.uiRGB(128, 134, 146))
    static let locked = SketchTheme.dynamic(light: SketchTheme.uiRGB(28, 140, 72), dark: SketchTheme.uiRGB(96, 200, 132))
    static let lockedBackground = SketchTheme.dynamic(light: SketchTheme.uiRGB(234, 247, 238, 0.92),
                                                      dark: SketchTheme.uiRGB(30, 50, 40, 0.9))
    static let conflict = SketchTheme.dynamic(light: UIColor.systemRed, dark: SketchTheme.uiRGB(240, 100, 96))

    static func textColor(_ state: State) -> UIColor {
        switch state {
        case .free, .editing: return text
        case .locked: return locked
        case .conflict: return conflict
        }
    }

    static func borderColor(_ state: State) -> UIColor {
        switch state {
        case .free: return border
        case .editing: return borderEditing
        case .locked: return locked.withAlphaComponent(0.75)
        case .conflict: return conflict.withAlphaComponent(0.85)
        }
    }

    static func backgroundColor(_ state: State) -> UIColor {
        state == .locked ? lockedBackground : background
    }

    static func lockTint(_ state: State) -> UIColor {
        switch state {
        case .free, .editing: return lockFree
        case .locked: return locked
        case .conflict: return conflict
        }
    }

    // MARK: Maßlinien (Metal, linear)

    /// Dünne Maßlinie und Pfeile beim Zeichnen
    static let lineWidth: Float = 0.75
    /// Pfeilspitze in Bildschirmpunkten (Länge, halbe Breite); bleibende Maße 8 und 3
    static let arrowLength: Double = 6
    static let arrowWing: Double = 2.2

    static var lineInk: SIMD3<Float> {
        AppTheme.isDark ? SketchTheme.linear(150, 156, 168) : SIMD3<Float>(0.3, 0.32, 0.36)
    }
    static var lineInkLocked: SIMD3<Float> {
        AppTheme.isDark ? SketchTheme.linear(96, 200, 132) : SketchTheme.linear(28, 140, 72)
    }
}
