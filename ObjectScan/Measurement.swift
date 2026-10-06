import Foundation
import simd

/// A straight-line distance between two points in ARKit world space (metres).
struct Measurement: Identifiable {
    enum Kind { case distance, height }

    let id = UUID()
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    var kind: Kind = .distance

    var meters: Float { simd_distance(start, end) }
    var midpoint: SIMD3<Float> { (start + end) / 2 }

    func label(in unit: LengthUnit) -> String {
        kind == .height ? "H " + unit.format(meters) : unit.format(meters)
    }
}

/// Distance: two taps, straight line between them.
/// Height: one tap on top of an object, measured straight down to the surface it stands on.
enum MeasureMode: String, CaseIterable, Identifiable {
    case distance = "Distance"
    case height = "Height"
    var id: String { rawValue }
}

enum LengthUnit: String, CaseIterable, Identifiable {
    case cm
    case inches = "in"

    var id: String { rawValue }

    func format(_ meters: Float) -> String {
        switch self {
        case .cm: return String(format: "%.1f cm", meters * 100)
        case .inches: return String(format: "%.2f in", meters * 39.3701)
        }
    }
}
