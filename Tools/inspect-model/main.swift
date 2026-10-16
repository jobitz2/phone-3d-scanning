// Measures a 3D model file (USDZ/USDA/OBJ) on the Mac: units, axis-aligned size, and the
// upright minimum box from ObjectBoxFitter (same fit as ObjectScan's Box mode).
// Usage: inspect-model <model.usdz> [<model2> ...]
import Foundation
import ModelIO
import simd

func positions(of object: MDLObject, into out: inout [SIMD3<Float>]) {
    if let mesh = object as? MDLMesh,
       let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) {
        let world = MDLTransform.globalTransform(with: object, atTime: 0)
        for i in 0..<mesh.vertexCount {
            let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
            let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
            out.append(SIMD3(w.x, w.y, w.z))
        }
    }
    for child in object.children.objects { positions(of: child, into: &out) }
}

func fmt(_ m: Float) -> String { String(format: "%.1f mm (%.2f in)", m * 1000, m * 39.3701) }

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let asset = MDLAsset(url: url)
    var pts: [SIMD3<Float>] = []
    for i in 0..<asset.count { positions(of: asset.object(at: i), into: &pts) }
    print("== \(url.lastPathComponent)")
    guard !pts.isEmpty else { print("   no mesh vertices found"); continue }

    let lo = pts.reduce(pts[0]) { simd_min($0, $1) }
    let hi = pts.reduce(pts[0]) { simd_max($0, $1) }
    let ext = hi - lo
    print("   vertices: \(pts.count)")
    print("   ModelIO assumes metres. Axis-aligned extent (x, y=up, z):")
    print("     x \(fmt(ext.x))   y \(fmt(ext.y))   z \(fmt(ext.z))")

    // Upright minimum-area box, as in Box mode. The floor is the model's lowest point.
    let floorY = lo.y
    let above = pts.filter { $0.y > floorY + 0.0005 }
    let mid = (lo + hi) / 2
    let seed = above.min { simd_distance($0, mid) < simd_distance($1, mid) } ?? mid
    if let box = ObjectBoxFitter.fit(points: above, seed: seed, floorY: floorY, voxel: max(0.002, simd_length(ext) / 200)) {
        print("   Upright box (L × W × H): \(fmt(box.size.x)) × \(fmt(box.size.z)) × \(fmt(box.size.y))")
        print("   points in main cluster: \(box.pointCount) of \(above.count)")
    }
    print("   longest straight-line extent (diagonal of box): \(fmt(simd_length(ext)))")
}
