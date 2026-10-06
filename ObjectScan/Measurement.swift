import Foundation
import simd

/// A straight-line distance between two points in ARKit world space (metres).
struct Measurement: Identifiable {
    enum Kind { case distance, height, box }

    let id = UUID()
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    var kind: Kind = .distance
    /// Set for `.box` measurements.
    var box: FittedBox?

    /// Straight-line length; for a box, its longest side.
    var meters: Float { box?.size.x ?? simd_distance(start, end) }
    var midpoint: SIMD3<Float> { (start + end) / 2 }

    func label(in unit: LengthUnit) -> String {
        switch kind {
        case .distance: return unit.format(meters)
        case .height: return "H " + unit.format(meters)
        case .box:
            guard let s = box?.size else { return "" }
            return "\(unit.value(s.x)) × \(unit.value(s.z)) × \(unit.value(s.y)) \(unit.rawValue)"
        }
    }
}

/// Distance: two taps, straight line between them.
/// Height: one tap on top of an object, measured straight down to the surface it stands on.
/// Box: one tap on an object; fits an upright box and reports length × width × height.
enum MeasureMode: String, CaseIterable, Identifiable {
    case distance = "Distance"
    case height = "Height"
    case box = "Box"
    var id: String { rawValue }
}

enum LengthUnit: String, CaseIterable, Identifiable {
    case cm
    case inches = "in"

    var id: String { rawValue }

    func format(_ meters: Float) -> String { "\(value(meters)) \(rawValue)" }

    /// The number alone, e.g. "30.2" for cm or "11.89" for inches.
    func value(_ meters: Float) -> String {
        switch self {
        case .cm: return String(format: "%.1f", meters * 100)
        case .inches: return String(format: "%.2f", meters * 39.3701)
        }
    }
}
