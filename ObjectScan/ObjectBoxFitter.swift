import simd

/// An upright box around an object resting on a horizontal surface, in world space (metres).
struct FittedBox {
    /// Centre of the box.
    var center: SIMD3<Float>
    /// Direction of the box's long side in the horizontal plane, as atan2(z, x).
    var axisAngle: Float
    /// x = length (longest horizontal side), y = height, z = width.
    var size: SIMD3<Float>
    var pointCount: Int

    /// Rotation that turns an entity's local X axis into the box's long side.
    var orientation: simd_quatf { simd_quatf(angle: -axisAngle, axis: [0, 1, 0]) }
}

/// Pure geometry for the Box mode, kept free of ARKit so it can be tested on a Mac.
enum ObjectBoxFitter {
    /// Fits an upright minimum-area box to the cluster of points connected to `seed`.
    /// - Parameters:
    ///   - points: world points already cut to above the support surface.
    ///   - seed: where the user aimed (on the object's surface).
    ///   - floorY: height of the support surface; the box's bottom.
    ///   - voxel: grid size for connectivity. Gaps wider than about one voxel split objects.
    static func fit(points: [SIMD3<Float>], seed: SIMD3<Float>, floorY: Float, voxel: Float = 0.015) -> FittedBox? {
        let cluster = connectedCluster(points, seed: seed, voxel: voxel)
        guard cluster.count >= 30, let top = cluster.map(\.y).max() else { return nil }

        let hull = convexHull(cluster.map { SIMD2($0.x, $0.z) })
        guard hull.count >= 3 else { return nil }

        // Rotating calipers: the minimum-area rectangle has one side flush with a hull edge.
        var best: (area: Float, angle: Float, lo: SIMD2<Float>, hi: SIMD2<Float>)?
        for i in hull.indices {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            guard simd_length(edge) > 1e-6 else { continue }
            let angle = atan2(edge.y, edge.x)
            let rotated = hull.map { rotate($0, by: -angle) }
            let lo = rotated.reduce(rotated[0]) { simd_min($0, $1) }
            let hi = rotated.reduce(rotated[0]) { simd_max($0, $1) }
            let area = (hi.x - lo.x) * (hi.y - lo.y)
            if best == nil || area < best!.area { best = (area, angle, lo, hi) }
        }
        guard let b = best else { return nil }

        var extent = b.hi - b.lo
        var axisAngle = b.angle
        if extent.y > extent.x { // make the first side the longer one
            extent = SIMD2(extent.y, extent.x)
            axisAngle += .pi / 2
        }
        let centerXZ = rotate((b.lo + b.hi) / 2, by: b.angle)
        let height = top - floorY
        return FittedBox(
            center: SIMD3(centerXZ.x, floorY + height / 2, centerXZ.y),
            axisAngle: axisAngle,
            size: SIMD3(extent.x, height, extent.y),
            pointCount: cluster.count)
    }

    /// Points in the 26-connected voxel region that contains (or is nearest to) `seed`.
    static func connectedCluster(_ points: [SIMD3<Float>], seed: SIMD3<Float>, voxel: Float) -> [SIMD3<Float>] {
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>(p / voxel, rounding: .down) }

        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in points.enumerated() { grid[key(p), default: []].append(i) }

        // The aimed-at point sits on the surface, so its own voxel may be empty: take the nearest occupied one.
        let s = key(seed)
        var start: SIMD3<Int32>?
        var bestDistance = Int32.max
        for dx in Int32(-3)...3 { for dy in Int32(-3)...3 { for dz in Int32(-3)...3 {
            let k = s &+ SIMD3(dx, dy, dz)
            let d = dx * dx + dy * dy + dz * dz
            if d < bestDistance, grid[k] != nil { bestDistance = d; start = k }
        }}}
        guard let start else { return [] }

        var visited: Set<SIMD3<Int32>> = [start]
        var queue = [start]
        var head = 0
        var out: [SIMD3<Float>] = []
        while head < queue.count {
            let k = queue[head]; head += 1
            for i in grid[k]! { out.append(points[i]) }
            for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
                let n = k &+ SIMD3(dx, dy, dz)
                if grid[n] != nil, visited.insert(n).inserted { queue.append(n) }
            }}}
        }
        return out
    }

    /// Andrew's monotone chain; returns the hull counter-clockwise without repeating the first point.
    static func convexHull(_ input: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let pts = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func rotate(_ v: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Turns a depth-map pixel into a world point.
    /// - Parameters:
    ///   - pixel: (u, v) in depth-map pixels, origin top-left, in the sensor's landscape orientation.
    ///   - depth: metres along the camera's viewing axis.
    ///   - intrinsics: camera intrinsics already scaled to the depth map's resolution.
    ///   - cameraToWorld: `ARCamera.transform` (camera space: +x right, +y up, looking down -z).
    static func unproject(pixel: SIMD2<Float>, depth: Float, intrinsics: simd_float3x3, cameraToWorld: simd_float4x4) -> SIMD3<Float> {
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        // Image coordinates have +y down and +z forward; ARKit's camera has +y up and looks down -z.
        let x = (pixel.x - cx) * depth / fx
        let y = (pixel.y - cy) * depth / fy
        let world = cameraToWorld * SIMD4(x, -y, -depth, 1)
        return SIMD3(world.x, world.y, world.z)
    }
}
