import SwiftUI

// Gestaltung an einer Stelle: Radien, Maße, Farben, Schatten und Bewegungen der Oberfläche.
// Leitbild: ruhig, Kacheln und Kapseln schweben mit feinem Rand und weichem Schatten über dem Viewport;
// aktive Zustände sind farbig gefüllt mit weißem Symbol. Standard ist das dunkle Anthrazit nach SolidCraft
// (SketchTheme.swift); „Helles Design“ zeigt die bisherigen weißen Flächen.

enum Theme {
    /// Eckenradien (immer mit `style: .continuous` verwenden)
    enum Radius {
        /// Listenzeilen in Seitenfenstern
        static let row: CGFloat = 8
        /// Schilder neben Kacheln, kleine Symbolfelder
        static let label: CGFloat = 9
        /// Säulen der rechten Leiste, Vorschaubilder der Startseite
        static let group: CGFloat = 14
        /// Karten, Seitenfenster, Untermenüs
        static let panel: CGFloat = 16
    }

    /// Höhe der Titelleiste und des Reiters „Ebenen“
    static let barHeight: CGFloat = 40

    // MARK: Farben

    /// Grund schwebender Kacheln, Knöpfe und Fenster: hell weiß, dunkel Anthrazit-Panel #272B34 (SolidCraft)
    static let surface = Color(SketchTheme.dynamic(light: .systemBackground, dark: SketchTheme.uiRGB(39, 43, 52)))
    /// Feiner Rand um schwebende Flächen; dunkel der SolidCraft-Rand #3F4552
    static let hairline = Color(SketchTheme.dynamic(light: UIColor.label.withAlphaComponent(0.08),
                                                    dark: SketchTheme.uiRGB(63, 69, 82)))
    static let hairlineWidth: CGFloat = 0.5
    /// Hintergrund der Startseite; dunkel #1F232B (SolidCraft file_background)
    static let homeBackground = Color(SketchTheme.dynamic(light: .systemGroupedBackground,
                                                          dark: SketchTheme.uiRGB(31, 35, 43)))
    /// Dunkles Farbschema (Anthrazit) mit allen SolidCraft-Werten
    typealias Sketch = SketchTheme
    /// Schatten im Dunkeln stärker, sonst verschwänden sie auf dem Anthrazit-Grund
    static let darkShadowFactor: Double = 3.5
    /// Hinterlegung der gewählten Zeile in Listen
    static let rowHighlight = Color.accentColor.opacity(0.14)

    // MARK: Schrift

    /// Name neben einer Kachel bzw. einem Knopf
    static let labelFont = Font.caption.weight(.semibold)
    /// Projektname und Reiter in der Titelleiste
    static let barFont = Font.callout.weight(.semibold)

    // MARK: Bewegung

    /// Kurze, kaum federnde Bewegung für Zustandswechsel (aktiv, gedrückt, Schweben)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// Ein- und Ausblenden von Fenstern und Untermenüs
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

/// Höhe einer Fläche über dem Viewport: bestimmt Rand und Schatten.
enum Elevation {
    /// Innerhalb einer gemeinsamen Säule: weder Rand noch Schatten
    case inset
    /// Schild ohne Schatten, nur mit feinem Rand
    case flat
    /// Kacheln und runde Knöpfe
    case raised
    /// Leisten, Karten, Untermenüs, Seitenfenster
    case floating
    /// Schilder beim Schweben und das Werkzeugrad über allem
    case overlay

    var hasBorder: Bool { self != .inset }

    var shadowOpacity: Double {
        switch self {
        case .inset, .flat: 0
        case .raised: 0.10
        case .floating: 0.10
        case .overlay: 0.16
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .inset, .flat: 0
        case .raised: 3
        case .floating: 12
        case .overlay: 16
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .inset, .flat: 0
        case .raised: 1
        case .floating: 4
        case .overlay: 5
        }
    }
}

/// Fläche in einer Form: Grund, feiner Rand und weicher Schatten (Schatten nur von der Form, nicht vom Inhalt).
struct FloatingShape<S: InsettableShape, Fill: ShapeStyle>: View {
    let shape: S
    let fill: Fill
    var elevation: Elevation = .raised

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let factor: Double = colorScheme == .dark ? Theme.darkShadowFactor : 1
        let opacity: Double = min(elevation.shadowOpacity * factor, 0.6)
        shape
            .fill(fill)
            .overlay {
                shape.strokeBorder(elevation.hasBorder ? Theme.hairline : Color.clear, lineWidth: Theme.hairlineWidth)
            }
            .shadow(color: .black.opacity(opacity), radius: elevation.shadowRadius, y: elevation.shadowY)
    }
}

extension View {
    /// Schwebende Fläche hinter dem Inhalt (z. B. `.floatingSurface(.regularMaterial, in: Capsule())`).
    func floatingSurface<S: InsettableShape, Fill: ShapeStyle>(_ fill: Fill, in shape: S,
                                                                elevation: Elevation = .raised) -> some View {
        background {
            FloatingShape(shape: shape, fill: fill, elevation: elevation)
        }
    }

    /// Weiße schwebende Fläche.
    func floatingSurface<S: InsettableShape>(in shape: S, elevation: Elevation = .raised) -> some View {
        floatingSurface(Theme.surface, in: shape, elevation: elevation)
    }

    /// Karte bzw. Seitenfenster: weiß, großer Radius, weicher Schatten.
    func floatingPanel() -> some View {
        floatingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous), elevation: .floating)
    }

    /// Nur der feine Rand (für Flächen, die ihren Grund selbst zeichnen).
    func hairlineBorder<S: InsettableShape>(_ shape: S) -> some View {
        overlay {
            shape.strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
                .allowsHitTesting(false)
        }
    }

    /// Nur der Schatten einer Höhenstufe.
    func elevationShadow(_ elevation: Elevation) -> some View {
        shadow(color: .black.opacity(elevation.shadowOpacity), radius: elevation.shadowRadius, y: elevation.shadowY)
    }

    /// Schatten einer Werkzeugkachel: aktiv als weicher Schein in der Füllfarbe, sonst neutral.
    func tileShadow(_ glow: Color?) -> some View {
        shadow(color: glow?.opacity(0.28) ?? Color.black.opacity(Elevation.raised.shadowOpacity),
               radius: glow == nil ? Elevation.raised.shadowRadius : 5,
               y: glow == nil ? Elevation.raised.shadowY : 2)
    }
}

/// Knopf, der beim Drücken leicht nachgibt; sonst wie `.plain` (Inhalt unverändert).
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Knopf mit leichtem Nachgeben beim Drücken.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
