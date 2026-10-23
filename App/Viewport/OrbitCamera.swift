import CoreGraphics
import simd

/// Orbit-Kamera um einen Zielpunkt, Z zeigt nach oben (CAD-Konvention).
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 10)
    var distance: Float = 150
    var yaw: Float = -.pi / 4
    var pitch: Float = 0.5
    let fieldOfView: Float = 45 * .pi / 180
    /// Parallelprojektion statt Perspektive (Schalter „Projektion“).
    var isOrthographic = false

    var position: SIMD3<Float> {
        let cp = cos(pitch)
        return target + distance * SIMD3(cp * cos(yaw), cp * sin(yaw), sin(pitch))
    }

    var viewMatrix: float4x4 {
        .lookAt(eye: position, center: target, up: SIMD3(0, 0, 1))
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        if isOrthographic {
            let halfHeight = distance * tan(fieldOfView / 2)
            return .orthographic(halfWidth: halfHeight * aspect, halfHeight: halfHeight, near: -distance * 20,
                                 far: distance * 20)
        }
        return .perspective(fovY: fieldOfView, aspect: aspect, near: max(distance * 0.01, 0.1), far: distance * 20)
    }

    /// Richtung von der Kamera zum Ziel.
    var forward: SIMD3<Float> { simd_normalize(target - position) }

    /// Weltlänge eines Bildschirmpunkts in der Tiefe von point.
    func worldUnitsPerPoint(at point: SIMD3<Float>, viewHeight: Float) -> Float {
        if isOrthographic { return worldUnitsPerPoint(viewHeight: viewHeight) }
        let depth = max(simd_dot(point - position, forward), distance * 0.01)
        return 2 * depth * tan(fieldOfView / 2) / max(viewHeight, 1)
    }

    /// Bildschirmpunkt eines Weltpunkts; nil hinter der Kamera.
    func project(_ p: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let aspect = Float(viewSize.width / viewSize.height)
        let clip = projectionMatrix(aspect: aspect) * viewMatrix * SIMD4(p.x, p.y, p.z, 1)
        guard clip.w > 1e-6 else { return nil }
        let x = clip.x / clip.w, y = clip.y / clip.w
        return CGPoint(x: CGFloat((x + 1) / 2) * viewSize.width, y: CGFloat((1 - y) / 2) * viewSize.height)
    }

    /// Ungefähre Weltlänge eines Bildschirmpunkts in der Tiefe des Zielpunkts.
    func worldUnitsPerPoint(viewHeight: Float) -> Float {
        2 * distance * tan(fieldOfView / 2) / max(viewHeight, 1)
    }

    /// Sehstrahl durch einen Bildschirmpunkt (Ursprung auf der nahen Ebene, normierte Richtung).
    func ray(through p: CGPoint, viewSize: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let aspect = Float(viewSize.width / viewSize.height)
        let inverse = (projectionMatrix(aspect: aspect) * viewMatrix).inverse
        let ndc = SIMD2(Float(2 * p.x / viewSize.width - 1), Float(1 - 2 * p.y / viewSize.height))
        func unproject(_ depth: Float) -> SIMD3<Float> {
            let v = inverse * SIMD4(ndc.x, ndc.y, depth, 1)
            return SIMD3(v.x, v.y, v.z) / v.w
        }
        let near = unproject(0), far = unproject(1)
        return (near, simd_normalize(far - near))
    }

    /// Schnittpunkt des Sehstrahls mit einer Ebene.
    func intersect(screenPoint p: CGPoint, viewSize: CGSize,
                   planeOrigin: SIMD3<Float>, planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        guard let ray = ray(through: p, viewSize: viewSize) else { return nil }
        let denom = simd_dot(ray.direction, planeNormal)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(planeOrigin - ray.origin, planeNormal) / denom
        guard t >= 0 else { return nil }
        return ray.origin + t * ray.direction
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -Self.maxPitch), Self.maxPitch)
    }

    /// Verschiebt das Ziel so, dass der Inhalt dem Finger folgt.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let unitsPerPoint = worldUnitsPerPoint(viewHeight: viewHeight)
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        target += (-right * dx + up * dy) * unitsPerPoint
    }

    mutating func zoom(by scale: Float) {
        distance = min(max(distance / scale, 2), 5000)
    }

    mutating func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = simd_length(hi - lo) / 2
        distance = max(radius / sin(fieldOfView / 2) * 1.2, 5)
    }

    /// Fast senkrecht; genau 90° würde die Blickrichtung mit der Hochachse zusammenfallen lassen.
    static let maxPitch: Float = 1.5695

    /// Blickt senkrecht auf eine Ebene (Kamera auf der Seite der Normale).
    /// right: Richtung, die auf dem Bildschirm waagerecht nach rechts zeigen soll (muss waagerecht liegen).
    /// Ohne right bleibt die Drehung bei Drauf- und Untersicht erhalten.
    mutating func look(along normal: SIMD3<Float>, at point: SIMD3<Float>, right: SIMD3<Float>? = nil) {
        let n = simd_normalize(normal)
        target = point
        pitch = min(max(asin(min(max(n.z, -1), 1)), -Self.maxPitch), Self.maxPitch)
        if let right, abs(right.z) < 0.01, simd_length(right) > 0 {
            // Bildschirm-rechts ist (−sin yaw, cos yaw, 0)
            yaw = atan2(-right.x, right.y)
        } else if abs(n.z) < 0.999 {
            yaw = atan2(n.y, n.x)
        }
    }
}

extension float4x4 {
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    /// Rechtshändig, Tiefenbereich 0...1 (Metal).
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tan(fovY / 2)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)
        ))
    }

    /// Rechtshändig, Tiefenbereich 0...1 (Metal).
    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> float4x4 {
        let zs = 1 / (near - far)
        return float4x4(columns: (
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, zs, 0),
            SIMD4(0, 0, near * zs, 1)
        ))
    }

    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }

    /// Basiswechsel: lokale x/y/z-Achsen auf u/v/n, Ursprung auf origin.
    init(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        self.init(columns: (SIMD4(u, 0), SIMD4(v, 0), SIMD4(n, 0), SIMD4(origin, 1)))
    }
}
