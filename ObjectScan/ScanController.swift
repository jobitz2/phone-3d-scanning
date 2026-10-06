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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
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
        guard let hit = surfacePoint(at: center) else {
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

        if let start = pendingStart {
            Self.stretch(previewLine, from: start, to: hit)
            previewLine.isEnabled = true
            let d = simd_distance(start, hit)
            // Only publish millimetre-level changes so SwiftUI isn't redrawn on every frame.
            if liveDistance.map({ abs($0 - d) > 0.0005 }) ?? true { liveDistance = d }
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

    private func relabelMeasurements() {
        for m in measurements {
            guard let anchor = measurementAnchors[m.id] else { continue }
            labelEntities[m.id]?.removeFromParent()
            let label = makeLabel(for: m)
            anchor.addChild(label)
            labelEntities[m.id] = label
        }
    }

    /// A text label floating just above the midpoint, turned to face the camera.
    private func makeLabel(for m: Measurement) -> Entity {
        let mesh = MeshResource.generateText(
            unit.format(m.meters), extrusionDepth: 0.0005,
            font: .systemFont(ofSize: 0.025, weight: .semibold))
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        text.position = -mesh.bounds.center // centre the glyphs on the pivot

        let pivot = Entity()
        pivot.addChild(text)
        let position = m.midpoint + SIMD3(0, 0.025, 0)
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
