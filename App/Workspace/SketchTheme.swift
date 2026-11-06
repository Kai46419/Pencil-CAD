import Foundation
import simd
import SwiftUI
import UIKit

// Dunkles Farbschema „Anthrazit“ nach SolidCraft (MIT, assets/styles/ui/palettes.rs, Tokens::dark()).
// Kai: „nicht so hell, anthrazitgrau, abends flasht es nicht“ – dunkel gilt im ganzen Arbeitsbereich (Skizze und
// 3D) und auf der Startseite. Der Schalter „Helles Design“ (AppStorage "appearance.light", Standard aus) führt
// zurück zum bisherigen hellen Shapr3D-Aussehen.
//
// SwiftUI- und UIKit-Flächen folgen dem colorScheme (WorkspaceView/HomeView setzen `.appTheme()`), Metal liest
// `AppTheme.isDark`. Metal-Werte sind linear (die Ausgabe ist sRGB), aus den sRGB-Werten von SolidCraft berechnet.

/// Design der App: hell, dunkel (Anthrazit) oder automatisch wie das iPad (Build 51, Kai).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Hell"
        case .dark: return "Dunkel"
        case .automatic: return "Automatisch"
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .automatic: return "circle.lefthalf.filled"
        }
    }
}

/// Helles oder dunkles Design der App.
enum AppTheme {
    /// UserDefaults-Schlüssel des früheren Schalters „Helles Design“ (bleibt für ältere Einstellungen gültig)
    static let lightKey = "appearance.light"
    /// Hell, Dunkel oder Automatisch (AppearanceMode.rawValue)
    static let modeKey = "appearance.mode"
    /// Zuletzt gesehenes Aussehen des iPads (für „Automatisch“ in Metal, das keine SwiftUI-Umgebung hat)
    static let systemDarkKey = "appearance.systemDark"

    /// Gewähltes Design; ohne Wahl gilt der alte Schalter (aus = Anthrazit)
    static var mode: AppearanceMode {
        if let raw = UserDefaults.standard.string(forKey: modeKey), let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        return UserDefaults.standard.bool(forKey: lightKey) ? .light : .dark
    }

    static func setMode(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        if mode != .automatic { UserDefaults.standard.set(mode == .light, forKey: lightKey) }
    }

    /// true = Anthrazit, false = helles Design
    static var isDark: Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .automatic: return UserDefaults.standard.bool(forKey: systemDarkKey)
        }
    }

    static var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Viewport-Hintergrund linear (z. B. zum Abblenden von Farben zum Hintergrund hin)
    static var viewportBackgroundLinear: SIMD3<Float> {
        isDark ? SketchTheme.Metal.background : SIMD3<Float>(repeating: 0.845)
    }

    /// Farbe zum Viewport-Hintergrund hin abblenden (Anteil 0 = Farbe, 1 = Hintergrund).
    static func towardBackground(_ color: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        color * (1 - amount) + viewportBackgroundLinear * amount
    }

    /// Aussehen des iPads selbst (der Bildschirm kennt keine App-Vorgabe) merken, damit Metal bei „Automatisch“
    /// mitzieht; schreibt nur bei einer Änderung (jede Änderung lässt den Viewport neu zeichnen).
    @MainActor
    static func noteSystemAppearance(fallback: ColorScheme) {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let dark = screen.map { $0.traitCollection.userInterfaceStyle == .dark } ?? (fallback == .dark)
        let stored = UserDefaults.standard.object(forKey: systemDarkKey) as? Bool
        if stored != dark { UserDefaults.standard.set(dark, forKey: systemDarkKey) }
    }
}

/// Setzt das Farbschema nach dem gewählten Design; „Automatisch“ folgt dem iPad.
private struct AppThemeModifier: ViewModifier {
    @AppStorage(AppTheme.lightKey) private var light = false
    @AppStorage(AppTheme.modeKey) private var modeRaw = ""
    @Environment(\.colorScheme) private var colorScheme

    private var mode: AppearanceMode {
        AppearanceMode(rawValue: modeRaw) ?? (light ? .light : .dark)
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode == .automatic ? nil : (mode == .light ? .light : .dark))
            .onAppear { AppTheme.noteSystemAppearance(fallback: colorScheme) }
            .onChange(of: modeRaw) { _, _ in AppTheme.noteSystemAppearance(fallback: colorScheme) }
            .onChange(of: colorScheme) { _, scheme in AppTheme.noteSystemAppearance(fallback: scheme) }
    }
}

extension View {
    /// Helles, dunkles oder automatisches Design nach der Wahl „Design“.
    func appTheme() -> some View {
        modifier(AppThemeModifier())
    }
}

/// Wahl „Design“ (Hell, Dunkel, Automatisch) für Menüs (Ansicht-Menü der rechten Leiste, Startseite).
struct AppearanceToggle: View {
    @AppStorage(AppTheme.lightKey) private var light = false
    @AppStorage(AppTheme.modeKey) private var modeRaw = ""

    var body: some View {
        Picker("Design", systemImage: "circle.lefthalf.filled", selection: Binding(
            get: { AppearanceMode(rawValue: modeRaw) ?? (light ? .light : .dark) },
            set: { AppTheme.setMode($0) })) {
            ForEach(AppearanceMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Werte aus SolidCraft Tokens::dark() (Abschnitt C der Spezifikation).
enum SketchTheme {
    /// Dunkel aktiv? Gilt (anders als in der ersten Spezifikation) nicht nur in der Skizze, sondern immer im
    /// Arbeitsbereich, solange „Helles Design“ aus ist.
    static func isDark(sketchActive: Bool) -> Bool { AppTheme.isDark }

    // MARK: Umrechnung

    /// sRGB 0…255 als SwiftUI-Farbe.
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: alpha)
    }

    /// sRGB 0…255 als UIKit-Farbe.
    static func uiRGB(_ r: Int, _ g: Int, _ b: Int, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }

    /// Ein sRGB-Kanal 0…255 linear.
    static func linearChannel(_ value: Int) -> Float {
        let c = Double(value) / 255
        let linear: Double = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        return Float(linear)
    }

    /// sRGB 0…255 als lineare Farbe für Metal.
    static func linear(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        SIMD3<Float>(linearChannel(r), linearChannel(g), linearChannel(b))
    }

    /// UIKit-Farbe, die dem Farbschema der Ansicht folgt.
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }

    // MARK: Oberfläche (C.4)

    static let appBar = rgb(28, 31, 38)
    static let toolbar = rgb(39, 43, 52)
    static let panel = rgb(39, 43, 52)
    static let panelHeader = rgb(47, 52, 62)
    static let rule = rgb(53, 59, 71)
    static let border = rgb(63, 69, 82)
    static let field = rgb(30, 34, 41)
    static let controlFill = rgb(28, 31, 38)
    static let controlBorder = rgb(74, 82, 98)
    static let hover = rgb(54, 61, 74)
    static let text = rgb(222, 226, 232)
    static let textDim = rgb(148, 155, 168)
    static let formDim = rgb(180, 187, 200)
    static let icon = rgb(208, 214, 226)
    static let accent = rgb(58, 136, 238)
    static let accentSoft = rgb(42, 70, 110)
    static let selectedBackground = rgb(42, 70, 110)
    static let selectedInk = rgb(156, 199, 245)
    static let sketchInk = rgb(70, 190, 120)
    static let sketchSoft = rgb(31, 59, 43)
    static let error = rgb(240, 100, 96)
    static let warning = rgb(236, 170, 70)
    static let success = rgb(143, 219, 154)
    static let successFill = rgb(44, 74, 51)
    static let overlay = rgb(34, 38, 46, 240.0 / 255)
    /// Grund der Startseite (file_background)
    static let homeBackground = rgb(31, 35, 43)
    /// Viewport-Hintergrund (oben = unten, kein Verlauf im Dunkeln)
    static let viewport = rgb(46, 52, 64)

    // MARK: Bedingungs-Symbole und Fang (C.3)

    static let glyphBackground = rgb(44, 50, 60)
    static let glyphEdge = rgb(200, 130, 120)
    static let glyphText = rgb(193, 99, 88)
    static let glyphConflict = rgb(240, 100, 96)

    /// Icon-Akzente (palette.toml, Rolle active-3, dark)
    static let iconSketch = rgb(18, 141, 69)
    static let iconConstraint = rgb(193, 99, 88)
    static let iconConstruction = rgb(167, 93, 0)

    /// Maße: Radius klein/mittel/groß/sehr groß
    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 8
        static let extraLarge: CGFloat = 10
    }

    /// Schriftgrößen (pt)
    enum FontSize {
        static let micro: CGFloat = 10
        static let panel: CGFloat = 10.5
        static let small: CGFloat = 11
        static let body: CGFloat = 12
        static let button: CGFloat = 13
    }

    // MARK: UIKit (Etiketten und Wertfelder im Viewport), folgen dem Farbschema

    enum UI {
        /// Fanghinweis: Grund accent_soft, Text text (hell: bisher orange mit weißer Schrift)
        static let snapHintBackground = SketchTheme.dynamic(light: UIColor(red: 0.98, green: 0.45, blue: 0.05, alpha: 0.92),
                                                            dark: SketchTheme.uiRGB(42, 70, 110, 0.95))
        static let snapHintText = SketchTheme.dynamic(light: .white, dark: SketchTheme.uiRGB(222, 226, 232))
        /// Wertfeld beim Zeichnen bzw. Maß: Grund panel, gesperrt accent_soft
        static let field = SketchTheme.dynamic(light: .white, dark: SketchTheme.uiRGB(39, 43, 52))
        static let fieldLocked = SketchTheme.dynamic(light: .white, dark: SketchTheme.uiRGB(42, 70, 110))
        static let fieldText = SketchTheme.dynamic(light: .black, dark: SketchTheme.uiRGB(222, 226, 232))
        static let fieldBorder = SketchTheme.dynamic(light: .systemGray4, dark: SketchTheme.uiRGB(63, 69, 82))
        /// Zugeklapptes Maß (nur Schloss)
        static let fieldCollapsed = SketchTheme.dynamic(light: UIColor.white.withAlphaComponent(0.75),
                                                        dark: SketchTheme.uiRGB(39, 43, 52, 0.85))
        /// Wert beim Ziehen eines Pfeils
        static let valueText = SketchTheme.dynamic(light: .black, dark: SketchTheme.uiRGB(222, 226, 232))
        static let valueBackground = SketchTheme.dynamic(light: .white, dark: SketchTheme.uiRGB(39, 43, 52))
        /// Kurzzeichen der Bedingungen (Plaketten)
        static let glyphText = SketchTheme.dynamic(light: UIColor(white: 0.35, alpha: 1), dark: SketchTheme.uiRGB(193, 99, 88))
        static let glyphBackground = SketchTheme.dynamic(light: UIColor(white: 1, alpha: 0.8), dark: SketchTheme.uiRGB(44, 50, 60, 0.92))
        static let glyphEdge = SketchTheme.dynamic(light: UIColor(white: 0.75, alpha: 1), dark: SketchTheme.uiRGB(200, 130, 120))
        /// Koordinatenanzeige (text_dim)
        static let coordinateText = SketchTheme.dynamic(light: .secondaryLabel, dark: SketchTheme.uiRGB(148, 155, 168))
    }

    // MARK: Metal, linear (C.1, C.2)

    enum Metal {
        static let background = SketchTheme.linear(46, 52, 64)
        static let grid = SketchTheme.linear(59, 65, 76)
        static let gridMajor = SketchTheme.linear(73, 79, 90)
        static let origin = SketchTheme.linear(240, 200, 60)
        static let axisX = SketchTheme.linear(220, 60, 60)
        static let axisY = SketchTheme.linear(60, 170, 60)
        static let axisZ = SketchTheme.linear(60, 100, 230)
        static let profileFill = SIMD4<Float>(SketchTheme.linear(120, 150, 200), 40.0 / 255)
        static let body = SketchTheme.linear(152, 156, 162)
        static let bodyEdge = SketchTheme.linear(16, 16, 18)
        /// Körperkanten direkt auf dem Hintergrund (Drahtgitter, Röntgen): hell statt schwarz
        static let edgeOnBackground = SketchTheme.linear(196, 202, 212)
        /// Unterbestimmte Kurve der aktiven Skizze
        static let sketch = SketchTheme.linear(92, 150, 255)
        /// Vollständig bestimmte Kurve, fertige Skizze
        static let sketchFixed = SketchTheme.linear(232, 234, 238)
        static let sketchLocked = SketchTheme.linear(96, 204, 116)
        static let construction = SketchTheme.linear(230, 130, 40)
        static let centerline = SketchTheme.linear(200, 110, 60)
        static let projected = SketchTheme.linear(150, 60, 190)
        static let lost = SketchTheme.linear(200, 60, 90)
        static let halo = SketchTheme.linear(28, 32, 40)
        static let point = SketchTheme.linear(232, 234, 238)
        static let pointFree = SketchTheme.linear(92, 150, 255)
        /// Gewählt (Kurve, Kante, Punktmarker)
        static let selection = SketchTheme.linear(0, 127, 255)
        static let hoverHalo = SketchTheme.linear(203, 203, 203)
        /// Werkzeugvorschau / Gummiband (sketch_accent)
        static let toolPreview = SketchTheme.linear(18, 141, 69)
        static let previewProfile = SketchTheme.linear(32, 190, 96)
        /// Ableitungs-Hilfslinie, Rahmenauswahl
        static let rubberBand = SketchTheme.linear(92, 160, 255)
        static let dimension = SketchTheme.linear(224, 228, 234)
        static let dimensionDriven = SketchTheme.linear(142, 150, 164)
        /// Fang (Zeigerkreis, Fangsymbol): sketch_ink
        static let snap = SketchTheme.linear(70, 190, 120)
        static let text = SketchTheme.linear(222, 226, 232)
        static let textDim = SketchTheme.linear(148, 155, 168)
        static let error = SketchTheme.linear(240, 100, 96)
        static let warning = SketchTheme.linear(236, 170, 70)
        /// Fertige Skizzen, während eine andere Skizze bearbeitet wird (gedämpft)
        static let otherSketch = SketchTheme.linear(142, 150, 164)
    }
}
