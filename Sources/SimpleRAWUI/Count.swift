/// "1 photo", "3 photos": a count and its noun, agreed. Nothing reads more like a script
/// than "1 photo(s)".
enum Count {
    static func of(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }

    static func photos(_ count: Int) -> String { of(count, "photo") }
}
