// Mac-runnable checks for ObjectBoxFitter. Run with: ./Tests/run-box-fitter-tests.sh
import Foundation
import simd

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print(ok ? "PASS" : "FAIL", message)
    if !ok { failures += 1 }
}
func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

/// Points sampled on the surface of an upright box resting on y = floorY, plus noise.
func boxSurface(center: SIMD2<Float>, length: Float, width: Float, height: Float, angle: Float,
                floorY: Float, step: Float = 0.008, noise: Float = 0.002, seed: UInt64) -> [SIMD3<Float>] {
    var rng = SystemRandomNumberGenerator()
    _ = seed
    var local: [SIMD3<Float>] = []
    let hx = length / 2, hz = width / 2
    var x = -hx
    while x <= hx {
        var y: Float = 0
        while y <= height { local.append([x, y, -hz]); local.append([x, y, hz]); y += step }
        var z = -hz
        while z <= hz { local.append([x, height, z]); z += step }
        x += step
    }
    var z = -hz
    while z <= hz {
        var y: Float = 0
        while y <= height { local.append([-hx, y, z]); local.append([hx, y, z]); y += step }
        z += step
    }
    return local.map { p in
        let r = ObjectBoxFitter.rotate(SIMD2(p.x, p.z), by: angle) + center
        let n = SIMD3<Float>(Float.random(in: -noise...noise, using: &rng),
                             Float.random(in: -noise...noise, using: &rng),
                             Float.random(in: -noise...noise, using: &rng))
        return SIMD3(r.x, floorY + p.y, r.y) + n
    }.filter { $0.y > floorY + 0.012 } // the app drops points near the table
}

// 1. A rotated box (like a cereal box) is measured to within about 1 cm.
let floorY: Float = 0.75
let cereal = boxSurface(center: [0.3, -0.2], length: 0.30, width: 0.08, height: 0.40, angle: 0.6, floorY: floorY, seed: 1)
if let box = ObjectBoxFitter.fit(points: cereal, seed: [0.3, floorY + 0.2, -0.16], floorY: floorY) {
    check(near(box.size.x, 0.30, 0.01), "cereal length \(box.size.x) ≈ 0.30")
    check(near(box.size.z, 0.08, 0.01), "cereal width \(box.size.z) ≈ 0.08")
    check(near(box.size.y, 0.40, 0.01), "cereal height \(box.size.y) ≈ 0.40")
    check(near(box.center.x, 0.3, 0.01) && near(box.center.z, -0.2, 0.01), "cereal centre \(box.center)")
    // The long side should point along the box's rotation (0.6 rad), modulo 180°.
    let d = abs(remainder(box.axisAngle - 0.6, Float.pi))
    check(d < 0.05, "cereal long-axis angle \(box.axisAngle) ≈ 0.6 (mod π)")
    // orientation maps local +X onto the long side direction.
    let xAxis = box.orientation.act([1, 0, 0])
    check(near(xAxis.x, cos(box.axisAngle), 1e-4) && near(xAxis.z, sin(box.axisAngle), 1e-4), "orientation local X → (cos, 0, sin) of axisAngle")
} else { check(false, "cereal box fit returned nil") }

// 2. A bat-like long thin object lying on the table.
let bat = boxSurface(center: [-0.5, 0.4], length: 0.84, width: 0.065, height: 0.065, angle: -1.2, floorY: floorY, seed: 2)
if let box = ObjectBoxFitter.fit(points: bat, seed: [-0.5, floorY + 0.06, 0.4], floorY: floorY) {
    check(near(box.size.x, 0.84, 0.01), "bat length \(box.size.x) ≈ 0.84")
    check(near(box.size.z, 0.065, 0.01), "bat width \(box.size.z) ≈ 0.065")
} else { check(false, "bat fit returned nil") }

// 3. A second object 10 cm away is not merged into the first.
let mug = boxSurface(center: SIMD2<Float>(0.6, -0.2), length: 0.09, width: 0.09, height: 0.10, angle: 0, floorY: floorY, seed: 3)
if let box = ObjectBoxFitter.fit(points: cereal + mug, seed: [0.3, floorY + 0.2, -0.16], floorY: floorY) {
    check(box.size.x < 0.32, "neighbouring mug excluded (length \(box.size.x))")
} else { check(false, "fit with neighbour returned nil") }

// 4. Too few points → nil instead of a junk box.
check(ObjectBoxFitter.fit(points: [[0, 1, 0], [0.01, 1, 0]], seed: [0, 1, 0], floorY: 0.9) == nil, "tiny cluster rejected")

// 5. Unprojection inverts a pinhole projection.
let K = simd_float3x3(columns: ([200, 0, 0], [0, 200, 0], [128, 96, 1]))
let camToWorld = simd_float4x4(simd_quatf(angle: 0.4, axis: simd_normalize([0.2, 1, 0.1])))
    * simd_float4x4(columns: ([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0.1, 1.3, -0.2, 1]))
let worldPoint = SIMD3<Float>(0.25, 1.1, -0.9)
let camPoint4 = camToWorld.inverse * SIMD4(worldPoint, 1)
let cam = SIMD3(camPoint4.x, -camPoint4.y, -camPoint4.z) // to image convention (+y down, +z forward)
let pixel = SIMD2(K[0][0] * cam.x / cam.z + K[2][0], K[1][1] * cam.y / cam.z + K[2][1])
let back = ObjectBoxFitter.unproject(pixel: pixel, depth: cam.z, intrinsics: K, cameraToWorld: camToWorld)
check(simd_distance(back, worldPoint) < 1e-4, "unproject round-trip error \(simd_distance(back, worldPoint))")

print(failures == 0 ? "ALL BOX FITTER TESTS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
