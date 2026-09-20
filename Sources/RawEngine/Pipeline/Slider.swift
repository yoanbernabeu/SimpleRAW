/// Maps slider values (user-facing scale) to the ranges the engine expects.
enum Slider {
    /// Centered slider, from -100 to +100 → -1…1.
    static func bipolar(_ value: Double) -> Double {
        min(max(value / 100, -1), 1)
    }

    /// Amount slider, from 0 to 100 → 0…1.
    static func unipolar(_ value: Double) -> Double {
        min(max(value / 100, 0), 1)
    }
}
