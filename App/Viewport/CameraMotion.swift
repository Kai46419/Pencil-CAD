import QuartzCore
import UIKit
import simd

/// Weiche Kamerabewegungen (Kai: „mit dem Stift den Würfel richtig schön smooth drehen“, wie Shapr3D und Fusion):
/// Ziehen am Ansichtswürfel dreht die Ansicht um den Drehpunkt wie das Ein-Finger-Drehen im Viewport und läuft
/// beim Loslassen kurz nach. Antippen des Würfels (bzw. `.look`) schwenkt animiert in die Ansicht.
/// Die Kamera wird direkt im Renderer gedreht, ohne Umweg über SwiftUI-Zustand.
@MainActor
final class CameraMotion: NSObject {
    /// Vom Viewport gesetzt.
    weak var view: ViewportView?

    /// Drehung je Bildschirmpunkt beim Ziehen am Würfel (0,6°/pt).
    static let radiansPerPoint: Float = 0.6 * .pi / 180
    /// Abklingzeit des Nachlaufens in Sekunden (kurz, damit die Ansicht nicht „wegschwimmt“)
    private static let spinDecay: Double = 0.16
    /// Höchste Ziehgeschwindigkeit, die ins Nachlaufen übernommen wird (Punkte/s)
    private static let maxFlingSpeed: CGFloat = 1400
    /// Unter dieser Geschwindigkeit (Punkte/s) beim Loslassen kein Nachlaufen
    private static let minFlingSpeed: CGFloat = 60
    /// Dauer des Einschwenkens in eine Ansicht (Sekunden)
    private static let flightDuration: Double = 0.38

    private struct Flight {
        let fromYaw: Float
        let fromPitch: Float
        let deltaYaw: Float
        let deltaPitch: Float
        let start: CFTimeInterval
    }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Nachlaufen: Winkelgeschwindigkeit (Gier, Neigung) in Bogenmaß/s
    private var spin = SIMD2<Float>(0, 0)
    private var flight: Flight?

    /// Ziehen am Würfel um (dx, dy) Bildschirmpunkte: dreht wie das Ein-Finger-Drehen im Viewport
    /// (waagerecht = Gierwinkel, senkrecht = Neigung).
    func drag(dx: CGFloat, dy: CGFloat) {
        stop()
        let yaw: Float = -Float(dx) * Self.radiansPerPoint
        let pitch: Float = Float(dy) * Self.radiansPerPoint
        view?.turnCamera(yaw: yaw, pitch: pitch)
    }

    /// Loslassen mit dieser Geschwindigkeit (Punkte/s): die Drehung läuft kurz nach und klingt aus.
    func fling(velocity: CGSize) {
        stop()
        let speed: CGFloat = hypot(velocity.width, velocity.height)
        guard speed > Self.minFlingSpeed else { return }
        let factor: CGFloat = min(1, Self.maxFlingSpeed / speed)
        let vx = Float(velocity.width * factor)
        let vy = Float(velocity.height * factor)
        spin = SIMD2<Float>(-vx * Self.radiansPerPoint, vy * Self.radiansPerPoint)
        start()
    }

    /// Schwenkt animiert auf diese Winkel (Gierwinkel auf dem kürzeren Weg).
    func fly(toYaw yaw: Float, pitch: Float) {
        stop()
        guard let camera = view?.renderer?.camera else { return }
        let deltaYaw: Float = (yaw - camera.yaw).remainder(dividingBy: 2 * Float.pi)
        let deltaPitch: Float = pitch - camera.pitch
        let tiny = abs(deltaYaw) < 1e-4 && abs(deltaPitch) < 1e-4
        if tiny || UIAccessibility.isReduceMotionEnabled {
            view?.setCameraAngles(yaw: camera.yaw + deltaYaw, pitch: pitch)
            return
        }
        flight = Flight(fromYaw: camera.yaw, fromPitch: camera.pitch, deltaYaw: deltaYaw, deltaPitch: deltaPitch,
                        start: CACurrentMediaTime())
        start()
    }

    /// Hält Nachlaufen und Einschwenken an (z. B. sobald wieder gegriffen wird).
    func stop() {
        link?.invalidate()
        link = nil
        flight = nil
        spin = SIMD2<Float>(0, 0)
    }

    private func start() {
        lastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        // ProMotion: bis 120 Bilder/s
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let view else {
            stop()
            return
        }
        let now = CACurrentMediaTime()
        if let flight {
            let progress: Double = min(max((now - flight.start) / Self.flightDuration, 0), 1)
            let eased = Float(Self.easeInOut(progress))
            let yaw: Float = flight.fromYaw + flight.deltaYaw * eased
            let pitch: Float = flight.fromPitch + flight.deltaPitch * eased
            view.setCameraAngles(yaw: yaw, pitch: pitch)
            if progress >= 1 { stop() }
            return
        }
        let dt = Float(min(max(now - lastTimestamp, 0), 0.05))
        lastTimestamp = now
        let pitchBefore: Float = view.renderer?.camera.pitch ?? 0
        let stepPitch: Float = spin.y * dt
        view.turnCamera(yaw: spin.x * dt, pitch: stepPitch)
        // Am Anschlag (fast senkrecht) nicht weiter neigen, nur noch um die Hochachse drehen
        let pitchAfter: Float = view.renderer?.camera.pitch ?? 0
        if abs(pitchAfter - pitchBefore) < abs(stepPitch) * 0.5 {
            spin.y = 0
        }
        let decay = Float(exp(-Double(dt) / Self.spinDecay))
        spin *= decay
        if simd_length(spin) < 0.05 { stop() }
    }

    private static func easeInOut(_ t: Double) -> Double {
        if t < 0.5 { return 4 * t * t * t }
        let u: Double = -2 * t + 2
        return 1 - u * u * u / 2
    }
}

extension ViewportView {
    /// Dreht die Kamera um den Drehpunkt (Bogenmaß); die Neigung bleibt knapp unter senkrecht.
    func turnCamera(yaw: Float, pitch: Float) {
        guard let renderer else { return }
        let limit = OrbitCamera.maxPitch
        renderer.camera.yaw += yaw
        renderer.camera.pitch = min(max(renderer.camera.pitch + pitch, -limit), limit)
        cameraMoved()
    }

    /// Setzt die Blickwinkel direkt (Einschwenken in eine Ansicht).
    func setCameraAngles(yaw: Float, pitch: Float) {
        guard let renderer else { return }
        let limit = OrbitCamera.maxPitch
        renderer.camera.yaw = yaw
        renderer.camera.pitch = min(max(pitch, -limit), limit)
        cameraMoved()
    }
}
