import ARKit
import Combine
import RealityKit
import UIKit

/// Owns the AR session: LiDAR scene reconstruction, the centre reticle, and point-to-point measurements.
@MainActor
final class ScanController: NSObject, ObservableObject {
    // MARK: Published UI state
    let isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @Published var showMesh = true { didSet { applyMeshVisibility() } }
    @Published var unit: LengthUnit = .cm { didSet { relabelMeasurements() } }
    @Published var mode: MeasureMode = .distance { didSet { cancelPending() } }
    @Published private(set) var hint: String?
    @Published private(set) var measurements: [Measurement] = []
    @Published private(set) var hasPendingStart = false
    @Published private(set) var liveDistance: Float?
    @Published private(set) var reticleOnSurface = false
    @Published private(set) var trackingMessage: String? = "Move your phone slowly around the object"
    @Published private(set) var meshAnchorCount = 0
    @Published var exportURL: URL?
    @Published var errorMessage: String?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    // MARK: Scene state
    private var updateSubscription: Cancellable?
    private let reticleAnchor = AnchorEntity(world: .zero)
    private let reticle = ModelEntity(mesh: .generateSphere(radius: 0.004), materials: [UnlitMaterial(color: .white)])
    private let previewAnchor = AnchorEntity(world: .zero)
    private let previewLine = ScanController.makeLine(color: .white)
    private var pendingStart: SIMD3<Float>?
    private var startMarker: AnchorEntity?
    private var reticleWorld: SIMD3<Float>?
    private var measurementAnchors: [UUID: AnchorEntity] = [:]
    private var labelEntities: [UUID: Entity] = [:]

    override init() {
        super.init()
        arView.session.delegate = self
        // Collision lets RealityKit hit-test the reconstructed mesh; occlusion is left off so markers stay visible.
        arView.environment.sceneUnderstanding.options = [.collision]
        arView.renderOptions.insert(.disableMotionBlur)

        reticleAnchor.addChild(reticle)
        previewAnchor.addChild(previewLine)
        previewLine.isEnabled = false
        arView.scene.addAnchor(reticleAnchor)
        arView.scene.addAnchor(previewAnchor)
    }

    // MARK: Session lifecycle
    func start() {
        guard isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .none
        config.planeDetection = [.horizontal] // the table or floor that Height mode measures down to
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyMeshVisibility()

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReticle() }
        }
    }

    func pause() {
        updateSubscription?.cancel()
        arView.session.pause()
    }

    /// Throws away the scan and all measurements and starts a fresh session.
    func resetScan() {
        clearMeasurements()
        meshAnchorCount = 0
        start()
    }

    // MARK: Measuring
    /// First tap sets the start point at the reticle; second tap finishes the measurement.
    func addPoint() {
        guard let point = reticleWorld else { return }
        if mode == .box {
            measureBox(at: point)
            return
        }
        if mode == .height {
            guard let foot = supportPoint(below: point) else {
                showHint("Scan the table or floor around the object first")
                return
            }
            let m = Measurement(start: point, end: foot, kind: .height)
            measurements.append(m)
            place(m)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if let start = pendingStart {
            let m = Measurement(start: start, end: point)
            measurements.append(m)
            place(m)
            cancelPending()
        } else {
            pendingStart = point
            hasPendingStart = true
            let anchor = AnchorEntity(world: point)
            anchor.addChild(Self.makeMarker())
            arView.scene.addAnchor(anchor)
            startMarker = anchor
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Cancels a half-finished measurement, or removes the most recent one.
    func undo() {
        if pendingStart != nil {
            cancelPending()
        } else if let last = measurements.popLast() {
            measurementAnchors.removeValue(forKey: last.id)?.removeFromParent()
            labelEntities.removeValue(forKey: last.id)
        }
    }

    func clearMeasurements() {
        cancelPending()
        measurements.removeAll()
        measurementAnchors.values.forEach { $0.removeFromParent() }
        measurementAnchors.removeAll()
        labelEntities.removeAll()
    }

    // MARK: Export
    func exportMesh() {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        do {
            exportURL = try MeshExporter.writeOBJ(anchors, measurements: measurements)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Per-frame reticle
    private func updateReticle() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = centerDepthPoint() ?? surfacePoint(at: center) else {
            reticle.isEnabled = false
            previewLine.isEnabled = false
            reticleWorld = nil
            if reticleOnSurface { reticleOnSurface = false }
            if liveDistance != nil { liveDistance = nil }
            return
        }
        reticle.isEnabled = true
        reticleAnchor.position = hit
        reticleWorld = hit
        if !reticleOnSurface { reticleOnSurface = true }

        // Distance mode previews from the first point; Height mode previews straight down to the support surface.
        let previewStart: SIMD3<Float>?
        let previewEnd: SIMD3<Float>?
        switch mode {
        case .height:
            previewStart = hit
            previewEnd = supportPoint(below: hit)
        case .distance:
            previewStart = pendingStart
            previewEnd = pendingStart == nil ? nil : hit
        case .box:
            previewStart = nil
            previewEnd = nil
        }
        if let a = previewStart, let b = previewEnd {
            Self.stretch(previewLine, from: a, to: b)
            previewLine.isEnabled = true
            let d = simd_distance(a, b)
            // Only publish millimetre-level changes so SwiftUI isn't redrawn on every frame.
            if liveDistance.map({ abs($0 - d) > 0.0005 }) ?? true { liveDistance = d }
        } else {
            previewLine.isEnabled = false
            if liveDistance != nil { liveDistance = nil }
        }
    }

    /// The point under the screen centre from this frame's LiDAR depth map, or nil when
    /// confidence isn't high. Sharper at object edges than the reconstructed mesh, which
    /// rounds corners off by about a centimetre. Uses the map's centre pixel: the camera
    /// image is aspect-filled into the view, so the view centre is the image centre.
    private func centerDepthPoint() -> SIMD3<Float>? {
        guard let frame = arView.session.currentFrame,
              let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidence = depth.confidenceMap,
              let ray = arView.ray(through: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY))
        else { return nil }

        let map = depth.depthMap
        let x = CVPixelBufferGetWidth(map) / 2
        let y = CVPixelBufferGetHeight(map) / 2

        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let confBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let level = confBase.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(confidence) + x, as: UInt8.self)
        guard level == UInt8(ARConfidenceLevel.high.rawValue) else { return nil }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(map) else { return nil }
        let z = depthBase.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(map) + x * 4, as: Float32.self)
        guard z.isFinite, z > 0.05 else { return nil }

        // Depth is distance along the camera's viewing axis (-Z), not along the ray.
        let c = frame.camera.transform.columns.2
        let forward = -SIMD3<Float>(c.x, c.y, c.z)
        let direction = simd_normalize(ray.direction)
        let cosAngle = simd_dot(direction, forward)
        guard cosAngle > 0.1 else { return nil }
        return ray.origin + direction * (z / cosAngle)
    }

    /// The point on the horizontal surface directly below `point` (the table or floor the object
    /// stands on). Starts 2 cm below the point so a plane detected on the object's own top is skipped.
    private func supportPoint(below point: SIMD3<Float>) -> SIMD3<Float>? {
        let origin = point - SIMD3<Float>(0, 0.02, 0)
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .existingPlaneInfinite] {
            let query = ARRaycastQuery(origin: origin, direction: [0, -1, 0], allowing: target, alignment: .horizontal)
            if let result = arView.session.raycast(query).first {
                return SIMD3(point.x, result.worldTransform.columns.3.y, point.z)
            }
        }
        return nil
    }

    // MARK: Box mode
    /// Gathers scanned points above the support surface near `point`, keeps the ones connected to it,
    /// and fits an upright box. Points come from the accumulated LiDAR mesh (every side you've scanned)
    /// plus the current depth frame (denser, so small objects get enough points).
    private func measureBox(at point: SIMD3<Float>) {
        guard let floor = supportPoint(below: point) else {
            showHint("Scan the table or floor around the object first")
            return
        }
        let floorY = floor.y
        let keep: (SIMD3<Float>) -> Bool = { p in
            let dx = p.x - point.x, dz = p.z - point.z
            return p.y > floorY + 0.012 && p.y < floorY + 2.5 && dx * dx + dz * dz < 2.25 // within 1.5 m
        }
        let candidates = meshPoints(where: keep) + depthFramePoints(where: keep)
        guard let box = ObjectBoxFitter.fit(points: candidates, seed: point, floorY: floorY) else {
            showHint("Couldn't find an object there. Scan around it, then try again")
            return
        }
        guard box.size.x < 3 else {
            showHint("That's bigger than an object. Is it touching a wall?")
            return
        }
        let m = Measurement(start: box.center, end: box.center, kind: .box, box: box)
        measurements.append(m)
        place(m)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func meshPoints(where keep: (SIMD3<Float>) -> Bool) -> [SIMD3<Float>] {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        var out: [SIMD3<Float>] = []
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let v = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(v[0], v[1], v[2], 1)
                let p = SIMD3(w.x, w.y, w.z)
                if keep(p) { out.append(p) }
            }
        }
        return out
    }

    /// High-confidence pixels of the current depth map as world points (every other pixel).
    private func depthFramePoints(where keep: (SIMD3<Float>) -> Bool) -> [SIMD3<Float>] {
        guard let frame = arView.session.currentFrame,
              let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidence = depth.confidenceMap else { return [] }
        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)

        // Intrinsics are for the full-resolution camera image; scale them to the depth map.
        let imageSize = frame.camera.imageResolution
        let sx = Float(width) / Float(imageSize.width), sy = Float(height) / Float(imageSize.height)
        var K = frame.camera.intrinsics
        K[0][0] *= sx; K[2][0] *= sx
        K[1][1] *= sy; K[2][1] *= sy

        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(map),
              let confBase = CVPixelBufferGetBaseAddress(confidence) else { return [] }
        let depthRow = CVPixelBufferGetBytesPerRow(map), confRow = CVPixelBufferGetBytesPerRow(confidence)
        let high = UInt8(ARConfidenceLevel.high.rawValue)

        var out: [SIMD3<Float>] = []
        for v in stride(from: 0, to: height, by: 2) {
            for u in stride(from: 0, to: width, by: 2) {
                guard confBase.load(fromByteOffset: v * confRow + u, as: UInt8.self) == high else { continue }
                let z = depthBase.load(fromByteOffset: v * depthRow + u * 4, as: Float32.self)
                guard z.isFinite, z > 0.05 else { continue }
                let p = ObjectBoxFitter.unproject(pixel: SIMD2(Float(u), Float(v)), depth: z,
                                                  intrinsics: K, cameraToWorld: frame.camera.transform)
                if keep(p) { out.append(p) }
            }
        }
        return out
    }

    private func showHint(_ text: String) {
        hint = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.hint == text { self?.hint = nil }
        }
    }

    /// Where the screen point lands on a real surface: the LiDAR mesh first, then ARKit's depth-based raycast.
    private func surfacePoint(at point: CGPoint) -> SIMD3<Float>? {
        if let hit = arView.hitTest(point, query: .nearest, mask: .sceneUnderstanding).first {
            return hit.position
        }
        if let query = arView.makeRaycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let result = arView.session.raycast(query).first {
            let t = result.worldTransform.columns.3
            return SIMD3(t.x, t.y, t.z)
        }
        return nil
    }

    private func cancelPending() {
        pendingStart = nil
        hasPendingStart = false
        liveDistance = nil
        previewLine.isEnabled = false
        startMarker?.removeFromParent()
        startMarker = nil
    }

    // MARK: Scene building
    private func place(_ m: Measurement) {
        if let box = m.box {
            placeBox(box, for: m)
            return
        }
        let anchor = AnchorEntity(world: .zero)
        let a = Self.makeMarker(); a.position = m.start
        let b = Self.makeMarker(); b.position = m.end
        let line = Self.makeLine(color: .systemYellow)
        Self.stretch(line, from: m.start, to: m.end)
        anchor.addChild(a)
        anchor.addChild(b)
        anchor.addChild(line)

        let label = makeLabel(for: m)
        anchor.addChild(label)
        arView.scene.addAnchor(anchor)
        measurementAnchors[m.id] = anchor
        labelEntities[m.id] = label
    }

    /// A yellow wireframe box (12 thin bars) with the dimensions floating above it.
    private func placeBox(_ box: FittedBox, for m: Measurement) {
        let anchor = AnchorEntity(world: box.center)
        let frame = Entity()
        frame.orientation = box.orientation
        let h = box.size / 2
        let t: Float = 0.002
        let material = UnlitMaterial(color: .systemYellow)
        func bar(_ size: SIMD3<Float>, at position: SIMD3<Float>) {
            let e = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            e.position = position
            frame.addChild(e)
        }
        for a: Float in [-1, 1] {
            for b: Float in [-1, 1] {
                bar([box.size.x, t, t], at: [0, a * h.y, b * h.z]) // along length
                bar([t, box.size.y, t], at: [a * h.x, 0, b * h.z]) // vertical
                bar([t, t, box.size.z], at: [a * h.x, b * h.y, 0]) // along width
            }
        }
        anchor.addChild(frame)
        arView.scene.addAnchor(anchor)

        let label = makeLabel(for: m)
        anchor.addChild(label) // makeLabel uses world coordinates; the anchor sits at the box centre
        label.setPosition(labelPosition(for: m), relativeTo: nil)
        measurementAnchors[m.id] = anchor
        labelEntities[m.id] = label
    }

    private func labelPosition(for m: Measurement) -> SIMD3<Float> {
        if let box = m.box { return box.center + SIMD3(0, box.size.y / 2 + 0.03, 0) }
        return m.midpoint + SIMD3(0, 0.025, 0)
    }

    private func relabelMeasurements() {
        for m in measurements {
            guard let anchor = measurementAnchors[m.id] else { continue }
            labelEntities[m.id]?.removeFromParent()
            let label = makeLabel(for: m)
            anchor.addChild(label)
            label.setPosition(labelPosition(for: m), relativeTo: nil)
            labelEntities[m.id] = label
        }
    }

    /// A text label floating just above the midpoint, turned to face the camera.
    private func makeLabel(for m: Measurement) -> Entity {
        let mesh = MeshResource.generateText(
            m.label(in: unit), extrusionDepth: 0.0005,
            font: .systemFont(ofSize: 0.025, weight: .semibold))
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        text.position = -mesh.bounds.center // centre the glyphs on the pivot

        let pivot = Entity()
        pivot.addChild(text)
        let position = labelPosition(for: m)
        let camera = arView.cameraTransform.translation
        pivot.look(at: camera, from: position, relativeTo: nil)
        pivot.orientation *= simd_quatf(angle: .pi, axis: [0, 1, 0]) // text faces +Z; look(at:) aims -Z
        return pivot
    }

    private static func makeMarker() -> ModelEntity {
        ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [UnlitMaterial(color: .systemYellow)])
    }

    /// A unit-length bar along Z, scaled to length by `stretch`.
    private static func makeLine(color: UIColor) -> ModelEntity {
        ModelEntity(mesh: .generateBox(size: [0.0015, 0.0015, 1]), materials: [UnlitMaterial(color: color)])
    }

    private static func stretch(_ line: ModelEntity, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        guard length > 0.0001 else { line.scale = [1, 1, 0.0001]; return }
        line.look(at: b, from: (a + b) / 2, relativeTo: nil) // resets scale, so set it after
        line.scale = [1, 1, length]
    }

    private func applyMeshVisibility() {
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }
}

// MARK: - ARSessionDelegate
extension ScanController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message: String?
        switch camera.trackingState {
        case .normal: message = nil
        case .notAvailable: message = "Tracking unavailable"
        case .limited(.initializing): message = "Move your phone slowly around the object"
        case .limited(.excessiveMotion): message = "Slow down"
        case .limited(.insufficientFeatures): message = "Point at something with more detail or light"
        case .limited(.relocalizing): message = "Relocalizing…"
        case .limited: message = "Tracking limited"
        }
        MainActor.assumeIsolated { self.trackingMessage = message }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let added = anchors.filter { $0 is ARMeshAnchor }.count
        guard added > 0 else { return }
        MainActor.assumeIsolated { self.meshAnchorCount += added }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removed = anchors.filter { $0 is ARMeshAnchor }.count
        guard removed > 0 else { return }
        MainActor.assumeIsolated { self.meshAnchorCount = max(0, self.meshAnchorCount - removed) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let text = error.localizedDescription
        MainActor.assumeIsolated { self.errorMessage = text }
    }
}
