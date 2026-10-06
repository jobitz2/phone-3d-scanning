import RealityKit
import SwiftUI

struct ContentView: View {
    @StateObject private var scan = ScanController()

    var body: some View {
        ZStack {
            ARViewContainer(arView: scan.arView).ignoresSafeArea()

            if scan.isSupported {
                Reticle(onSurface: scan.reticleOnSurface)
                VStack {
                    topBar
                    Spacer()
                    bottomPanel
                }
                .padding()
            } else {
                UnsupportedView()
            }
        }
        .onAppear { scan.start() }
        .onDisappear { scan.pause() }
        .alert("Something went wrong", isPresented: Binding(
            get: { scan.errorMessage != nil },
            set: { if !$0 { scan.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scan.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if let message = scan.trackingMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Picker("Unit", selection: $scan.unit) {
                ForEach(LengthUnit.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
            CircleButton(systemName: scan.showMesh ? "cube.transparent.fill" : "cube.transparent") {
                scan.showMesh.toggle()
            }
            .accessibilityLabel(scan.showMesh ? "Hide mesh" : "Show mesh")
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if let hint = scan.hint {
                Text(hint)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.85), in: Capsule())
            } else if let d = scan.liveDistance {
                Text((scan.mode == .height ? "H " : "") + scan.unit.format(d))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            } else if !scan.measurements.isEmpty {
                measurementList
            } else {
                Text(instruction)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Picker("Mode", selection: $scan.mode) {
                ForEach(MeasureMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 270)

            HStack(spacing: 28) {
                CircleButton(systemName: "arrow.uturn.backward") { scan.undo() }
                    .disabled(scan.measurements.isEmpty && !scan.hasPendingStart)
                    .accessibilityLabel("Undo")

                Button { scan.addPoint() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 76, height: 76)
                        .background(scan.reticleOnSurface ? Color.white : Color.white.opacity(0.4), in: Circle())
                        .foregroundStyle(.black)
                }
                .disabled(!scan.reticleOnSurface)
                .accessibilityLabel(scan.hasPendingStart ? "Set end point" : "Set start point")

                exportButton
            }

            HStack {
                Text("\(scan.meshAnchorCount) mesh chunks")
                Spacer()
                Button("Clear") { scan.clearMeasurements() }
                    .disabled(scan.measurements.isEmpty)
                Button("New scan") { scan.resetScan() }
                    .padding(.leading, 12)
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var instruction: String {
        switch scan.mode {
        case .height: return "Aim at the top of the object, just inside the edge, then tap +"
        case .box: return "Scan all the way around the object, aim at it, then tap +"
        case .distance: return scan.hasPendingStart ? "Aim at the other end" : "Aim the dot at one end of the object, then tap +"
        }
    }

    private var measurementList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(scan.measurements.enumerated().suffix(3)), id: \.element.id) { index, m in
                HStack {
                    Text("#\(index + 1)").foregroundStyle(.secondary)
                    Text(m.label(in: scan.unit)).monospacedDigit().bold()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var exportButton: some View {
        if let url = scan.exportURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Color.yellow, in: Circle())
                    .foregroundStyle(.black)
            }
            .simultaneousGesture(TapGesture().onEnded { scan.exportMesh() }) // refresh the file on each share
            .accessibilityLabel("Share scan")
        } else {
            CircleButton(systemName: "square.and.arrow.down") { scan.exportMesh() }
                .accessibilityLabel("Export scan")
        }
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

private struct Reticle: View {
    let onSurface: Bool
    var body: some View {
        Circle()
            .strokeBorder(onSurface ? Color.yellow : Color.white.opacity(0.6), lineWidth: 2)
            .frame(width: 28, height: 28)
            .allowsHitTesting(false)
    }
}

private struct CircleButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
    }
}

private struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward").font(.largeTitle)
            Text("This device has no LiDAR scanner").font(.headline)
            Text("ObjectScan needs an iPhone Pro or iPad Pro with LiDAR.")
                .font(.subheadline).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}
