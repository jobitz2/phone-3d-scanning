import ARKit

/// Writes ARKit's reconstructed LiDAR mesh to a Wavefront OBJ file in world coordinates (metres).
/// OBJ opens in MeshLab, Blender, CloudCompare, Open3D and the macOS Finder preview.
enum MeshExporter {
    enum ExportError: LocalizedError {
        case nothingScanned
        var errorDescription: String? { "Nothing has been scanned yet. Move the phone around the object first." }
    }

    static func writeOBJ(_ anchors: [ARMeshAnchor], measurements: [Measurement]) throws -> URL {
        guard !anchors.isEmpty else { throw ExportError.nothingScanned }

        var obj = "# ObjectScan export. Units: metres. Y is up (ARKit world space).\n"
        for (i, m) in measurements.enumerated() {
            if let s = m.box?.size {
                obj += String(format: "# measurement %d (box): %.4f x %.4f x %.4f m (L x W x H)\n", i + 1, s.x, s.z, s.y)
            } else {
                obj += String(format: "# measurement %d: %.4f m\n", i + 1, m.meters)
            }
        }

        var vertexOffset = 0
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Vertices are float3 in the anchor's local space; move them into world space.
            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let p = vertexBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                obj += "v \(world.x) \(world.y) \(world.z)\n"
            }

            // Faces are triangles; indices are UInt32 or UInt16 depending on bytesPerIndex.
            let faces = geometry.faces
            let faceBase = faces.buffer.contents()
            let perFace = faces.indexCountPerPrimitive
            for f in 0..<faces.count {
                var line = "f"
                for j in 0..<perFace {
                    let k = (f * perFace + j) * faces.bytesPerIndex
                    let index = faces.bytesPerIndex == 4
                        ? Int(faceBase.load(fromByteOffset: k, as: UInt32.self))
                        : Int(faceBase.load(fromByteOffset: k, as: UInt16.self))
                    line += " \(index + vertexOffset + 1)" // OBJ indices are 1-based
                }
                obj += line + "\n"
            }
            vertexOffset += vertices.count
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ObjectScan-\(stamp).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
