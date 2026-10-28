import SwiftUI
import UIKit
import simd

// Oberflächen wählen (SurfaceFinish.swift): Vorschau-Kugeln, Abschnitt im Eigenschaften-Fenster und
// Untermenü im Kontextmenü eines Körpers.

enum FinishColors {
    /// Lineare Farbe (wie im Viewport) als SwiftUI-Farbe
    static func color(_ linear: SIMD3<Float>, scale: Float = 1, lift: Float = 0) -> Color {
        let lo = SIMD3<Float>(repeating: 0)
        let hi = SIMD3<Float>(repeating: 1)
        let value: SIMD3<Float> = simd_clamp(linear * scale + SIMD3<Float>(repeating: lift), lo, hi)
        return Color(.sRGBLinear, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
    }

    /// SwiftUI-Farbe (sRGB) → lineare Farbe für den Viewport
    static func linear(_ color: Color) -> SIMD3<Float> {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(toLinear(r), toLinear(g), toLinear(b))
    }

    private static func toLinear(_ component: CGFloat) -> Float {
        let v = Float(min(max(component, 0), 1))
        if v <= 0.04045 { return v / 12.92 }
        return powf((v + 0.055) / 1.055, 2.4)
    }
}

/// Kleine Vorschau-Kugel einer Oberfläche (einfache Verläufe, Muster angedeutet).
struct FinishSwatch: View {
    let appearance: SurfaceAppearance
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(baseFill)
            patternOverlay
                .clipShape(Circle())
            Circle().fill(highlight)
            Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .opacity(appearance.transparent ? 0.7 : 1)
    }

    private var baseFill: AnyShapeStyle {
        let albedo = appearance.albedo
        // Matte Metalle wie in Shaders.metal diffus über ihre Farbe (keine Horizont-Spiegelung)
        if appearance.metallic && appearance.matteAmount < 0.5 {
            // Metall: Spiegelung eines Horizonts (heller Himmel, dunkler Boden); matt = weicher, flauer Horizont
            let rough: Float = min(max(appearance.roughness, 0), 1)
            let half: Double = 0.05 + Double(rough) * 0.3
            let groundScale: Float = 0.22 + rough * 0.4
            let stops: [Gradient.Stop] = [
                .init(color: FinishColors.color(albedo, scale: 1 - rough * 0.15, lift: 0.15 * (1 - rough)), location: 0),
                .init(color: FinishColors.color(albedo, scale: 0.9 - rough * 0.1), location: 0.49 - half),
                .init(color: FinishColors.color(albedo, scale: groundScale), location: 0.49 + half),
                .init(color: FinishColors.color(albedo, scale: 0.55), location: 1),
            ]
            return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
        }
        let colors: [Color] = [
            FinishColors.color(albedo, scale: 1.15, lift: 0.03),
            FinishColors.color(albedo, scale: 0.9),
            FinishColors.color(albedo, scale: 0.45),
        ]
        let gradient = RadialGradient(colors: colors, center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0,
                                      endRadius: size * 0.8)
        return AnyShapeStyle(gradient)
    }

    private var highlight: RadialGradient {
        let gloss: Double = Double(1 - appearance.roughness)
        let coat: Double = appearance.clearcoat ? 0.35 : 0
        // Matt: nur ein schwacher, breiter Schimmer (höchstens wenige Prozent), wie im Shader
        let matte: Double = Double(appearance.matteAmount)
        let glossy: Double = min(gloss * gloss * 0.85 + coat, 0.95)
        let strength: Double = glossy * (1 - matte) + 0.03 * gloss * matte
        let colors: [Color] = [Color.white.opacity(strength), Color.white.opacity(0)]
        return RadialGradient(colors: colors, center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0,
                              endRadius: size * 0.32)
    }

    @ViewBuilder
    private var patternOverlay: some View {
        let dark: Color = FinishColors.color(appearance.albedo, scale: 0.45)
        switch appearance.pattern {
        case .wood:
            VStack(spacing: size / 7) {
                ForEach(0..<6, id: \.self) { _ in
                    Capsule().fill(dark.opacity(0.55)).frame(height: max(size / 18, 1))
                }
            }
            .rotationEffect(.degrees(-12))
        case .brushed:
            VStack(spacing: 1.5) {
                ForEach(0..<12, id: \.self) { row in
                    Rectangle().fill(Color.white.opacity(row % 3 == 0 ? 0.25 : 0.1)).frame(height: 0.7)
                }
            }
        case .concrete:
            ZStack {
                ForEach(0..<7, id: \.self) { k in
                    Circle()
                        .fill(dark.opacity(0.6))
                        .frame(width: 2, height: 2)
                        .offset(x: size * Self.dotX[k], y: size * Self.dotY[k])
                }
            }
        case .carbon:
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { column in
                            Rectangle().fill(Color.white.opacity((row + column) % 4 < 2 ? 0.16 : 0.02))
                        }
                    }
                }
            }
        case .none:
            Color.clear
        }
    }

    private static let dotX: [CGFloat] = [-0.25, 0.1, 0.28, -0.05, 0.2, -0.3, 0.02]
    private static let dotY: [CGFloat] = [-0.2, -0.3, 0.05, 0.12, 0.3, 0.18, -0.05]
}

/// Abschnitt „Oberfläche“ im Eigenschaften-Fenster.
struct SurfaceFinishSection: View {
    @ObservedObject var model: ModelStore
    let bodyIndex: Int
    /// Gleich aufgeklappt (Liste „Mehr …“ aus dem rechten Fenster)
    var initiallyExpanded = false

    @State private var expanded = false
    @State private var customColor = Color.gray
    @State private var customGloss = SurfaceGloss.satin
    @State private var customMetal = false

    /// Bei Mehrfachauswahl alle gewählten Körper, sonst der gezeigte
    private var targets: [Int] {
        model.selectedBodies.contains(bodyIndex) ? model.selectedBodies : [bodyIndex]
    }

    var body: some View {
        if model.bodies.indices.contains(bodyIndex) {
            let item: SceneBody = model.bodies[bodyIndex]
            VStack(alignment: .leading, spacing: 6) {
                header(item)
                if expanded {
                    library(current: item.finish)
                    Divider().padding(.vertical, 2)
                    customControls(item)
                }
            }
            .onAppear {
                if initiallyExpanded { expanded = true }
            }
        }
    }

    private func header(_ item: SceneBody) -> some View {
        Button {
            withAnimation(Theme.spring) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Label("Oberfläche", systemImage: "paintbrush.pointed")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(item.finishName ?? "nach Werkstoff")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                FinishSwatch(appearance: item.appearance, size: 20)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .hoverTip("Oberfläche", "Darstellung des Körpers wie Chrom, Gold, Holz, Beton oder Lack. Ändert nur das Aussehen – das Gewicht kommt vom Werkstoff.")
    }

    private func library(current: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SurfaceFinish.Category.allCases) { category in
                Text(category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 40), spacing: 6)], alignment: .leading,
                          spacing: 6) {
                    ForEach(SurfaceFinish.all.filter { $0.category == category }) { finish in
                        swatchButton(finish, selected: current == finish.id)
                    }
                }
            }
            if current != nil {
                Button("Oberfläche entfernen", systemImage: "xmark") {
                    model.setFinish(nil, of: targets)
                }
                .font(.footnote)
                .padding(.top, 2)
            }
        }
    }

    private func swatchButton(_ finish: SurfaceFinish, selected: Bool) -> some View {
        Button {
            model.setFinish(finish.id, of: targets)
        } label: {
            FinishSwatch(appearance: finish.appearance, size: 30)
                .padding(2)
                .overlay {
                    if selected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(finish.name)
        .hoverTip(finish.name, finish.category.rawValue)
    }

    private func customControls(_ item: SceneBody) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Eigene Farbe")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 4)
                ColorPicker("Farbe", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
            }
            Picker("Glanz", selection: $customGloss) {
                ForEach(SurfaceGloss.allCases) { gloss in
                    Text(gloss.name).tag(gloss)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Metall", isOn: $customMetal)
                .font(.footnote)
            HStack(spacing: 8) {
                FinishSwatch(appearance: customAppearance, size: 24)
                Button("Übernehmen") {
                    model.setCustomFinish(color: FinishColors.linear(customColor), gloss: customGloss,
                                          metallic: customMetal, of: targets)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .onAppear { loadCustom(item) }
        .onChange(of: bodyIndex) { loadCustom(model.bodies.indices.contains(bodyIndex) ? model.bodies[bodyIndex] : item) }
    }

    private var customAppearance: SurfaceAppearance {
        SurfaceFinish.customAppearance(color: FinishColors.linear(customColor), gloss: customGloss,
                                       metallic: customMetal)
    }

    /// Regler mit der aktuellen Darstellung des Körpers vorbelegen
    private func loadCustom(_ item: SceneBody) {
        let look = item.appearance
        customColor = FinishColors.color(look.albedo)
        customMetal = look.metallic
        customGloss = SurfaceGloss.nearest(look.roughness)
    }
}

/// Kontextmenü eines Körpers: Oberfläche wählen (neben „Material“).
struct FinishMenuItems: View {
    @ObservedObject var model: ModelStore
    let index: Int
    /// Körper, die die Oberfläche bekommen (bei Mehrfachauswahl alle gewählten)
    let targets: [Int]

    var body: some View {
        if model.bodies.indices.contains(index) {
            let current: String? = model.bodies[index].finish
            let title: String = model.bodies[index].finishName.map { "Oberfläche: \($0)" } ?? "Oberfläche"
            Menu {
                ForEach(SurfaceFinish.Category.allCases) { category in
                    Menu {
                        ForEach(SurfaceFinish.all.filter { $0.category == category }) { finish in
                            Button {
                                model.setFinish(finish.id, of: targets)
                            } label: {
                                Label(finish.name, systemImage: current == finish.id ? "checkmark" : "circle.fill")
                            }
                        }
                    } label: {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                }
                Menu {
                    ForEach(SurfaceGloss.allCases) { gloss in
                        Button(gloss.name) {
                            model.setCustomFinish(color: nil, gloss: gloss, metallic: false, of: targets)
                        }
                    }
                    ForEach(SurfaceGloss.allCases) { gloss in
                        Button(gloss.name + ", Metall") {
                            model.setCustomFinish(color: nil, gloss: gloss, metallic: true, of: targets)
                        }
                    }
                } label: {
                    Label("Eigene Farbe (aktuelle Farbe)", systemImage: "paintpalette")
                }
                if current != nil {
                    Divider()
                    Button("Oberfläche entfernen", systemImage: "xmark") { model.setFinish(nil, of: targets) }
                }
            } label: {
                Label(title, systemImage: "paintbrush.pointed")
            }
        }
    }
}
