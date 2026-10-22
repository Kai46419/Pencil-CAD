import simd

/// Orbit-Kamera um einen Zielpunkt, Z zeigt nach oben (CAD-Konvention).
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 10)
    var distance: Float = 150
    var yaw: Float = -.pi / 4
    var pitch: Float = 0.5
    let fieldOfView: Float = 45 * .pi / 180

    var position: SIMD3<Float> {
        let cp = cos(pitch)
        return target + distance * SIMD3(cp * cos(yaw), cp * sin(yaw), sin(pitch))
    }

    var viewMatrix: float4x4 {
        .lookAt(eye: position, center: target, up: SIMD3(0, 0, 1))
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        .perspective(fovY: fieldOfView, aspect: aspect, near: max(distance * 0.01, 0.1), far: distance * 20)
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.55), 1.55)
    }

    /// Verschiebt das Ziel so, dass der Inhalt dem Finger folgt.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let unitsPerPoint = 2 * distance * tan(fieldOfView / 2) / max(viewHeight, 1)
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
}
