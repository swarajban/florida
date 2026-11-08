import Foundation

/// JSON coders matching the server: dates are ISO 8601 instants. The server writes millisecond
/// fractions ("2026-11-08T17:00:00.000Z"); clients may send whole seconds. Both decode.
public enum JSONCoding {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseInstant(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 instant: \(string)")
            }
            return date
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatInstant(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Parses an ISO 8601 instant with or without fractional seconds, "Z" or a numeric offset.
    public static func parseInstant(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }

    /// Formats an instant the way JavaScript's `Date.prototype.toISOString` does: UTC, milliseconds, "Z".
    public static func formatInstant(_ date: Date) -> String {
        date.formatted(fractional)
    }
}
