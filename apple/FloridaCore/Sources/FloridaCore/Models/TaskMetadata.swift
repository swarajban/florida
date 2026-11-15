import Foundation

public enum TaskMetadataError: Error, Hashable, Sendable, LocalizedError {
    case tooManyTags
    case tagTooLong
    case waitingOnTooLong

    public var errorDescription: String? {
        switch self {
        case .tooManyTags: "Use at most 30 tags."
        case .tagTooLong: "Each tag must be at most 64 characters."
        case .waitingOnTooLong: "Waiting on must be at most 500 characters."
        }
    }
}

extension TaskItem {
    private static let metadataWhitespace = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

    public var isWaiting: Bool {
        waitingOn.map { !$0.trimmingCharacters(in: Self.metadataWhitespace).isEmpty } ?? false
    }

    public func allowsPlacement(at start: Date, pinned: Bool = false) -> Bool {
        guard !someday else { return false }
        guard isWaiting else { return true }
        guard !pinned, let waitingUntil else { return false }
        return start >= waitingUntil
    }

    public mutating func normalizeMetadata() throws {
        var seen = Set<[UInt16]>()
        let normalized = tags.compactMap { raw -> String? in
            let tag = raw.trimmingCharacters(in: Self.metadataWhitespace).lowercased(with: Locale(identifier: ""))
            return !tag.isEmpty && seen.insert(Array(tag.utf16)).inserted ? tag : nil
        }
        guard normalized.count <= 30 else { throw TaskMetadataError.tooManyTags }
        guard normalized.allSatisfy({ $0.utf16.count <= 64 }) else { throw TaskMetadataError.tagTooLong }
        let normalizedWaitingOn = waitingOn.flatMap {
            let value = $0.trimmingCharacters(in: Self.metadataWhitespace)
            return value.isEmpty ? nil : value
        }
        guard normalizedWaitingOn.map({ $0.utf16.count <= 500 }) ?? true else {
            throw TaskMetadataError.waitingOnTooLong
        }
        tags = normalized
        waitingOn = normalizedWaitingOn
        if waitingOn == nil {
            waitingUntil = nil
        } else {
            pinnedStart = nil
        }
    }
}
