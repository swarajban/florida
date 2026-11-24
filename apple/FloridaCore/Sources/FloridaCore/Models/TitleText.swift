public enum TitleText {
    static let foundationWhitespaceExtra = "\u{200B}"

    public static func trimmingWhitespace(_ text: String) -> String {
        trim(text, leading: foundationWhitespaceExtra, trailing: foundationWhitespaceExtra)
    }

    static func trim(_ text: String, leading: String, trailing: String?) -> String {
        let scalars = text.unicodeScalars
        func isTrimmed(_ scalar: Unicode.Scalar, separators: String) -> Bool {
            scalar.properties.isWhitespace || separators.unicodeScalars.contains(scalar)
        }

        var start = scalars.startIndex
        while start != scalars.endIndex, isTrimmed(scalars[start], separators: leading) {
            scalars.formIndex(after: &start)
        }
        var end = scalars.endIndex
        if let trailing {
            while start != end {
                let previous = scalars.index(before: end)
                guard isTrimmed(scalars[previous], separators: trailing) else { break }
                end = previous
            }
        }
        if start == scalars.startIndex, end == scalars.endIndex { return text }
        return String(scalars[start..<end])
    }
}
