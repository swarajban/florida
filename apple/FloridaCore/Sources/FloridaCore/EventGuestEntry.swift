import Foundation

public struct EventGuestEntry: Equatable, Sendable {
    public private(set) var guests: [EventAttendeeWrite]
    private let initial: [EventAttendeeWrite]
    private var excluded = Set<String>()
    public var input = ""

    public init(attendees: [EventAttendee] = []) {
        let guests = EventAttendeeWrite.normalized(attendees.filter { !$0.isSelf }.map {
            EventAttendeeWrite(email: $0.email, displayName: $0.displayName, optional: $0.optional)
        })
        self.guests = guests
        initial = guests
    }

    public func combined(parsed: [String] = []) -> [EventAttendeeWrite] {
        EventAttendeeWrite.normalized(guests + parsed.map { EventAttendeeWrite(email: $0) })
            .filter { !excluded.contains($0.email) }
    }

    public mutating func remove(_ email: String) {
        guests.removeAll { $0.email == email }
        excluded.insert(email)
    }

    public mutating func add(_ email: String, displayName: String? = nil) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard GuestSuggestion.isEmail(email) else { return }
        excluded.remove(email)
        guests = EventAttendeeWrite.normalized(guests + [EventAttendeeWrite(email: email, displayName: displayName)])
        input = ""
    }

    public mutating func commitInput() {
        let email = input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        add(email)
    }

    public mutating func write(isNew: Bool, parsed: [String] = []) -> [EventAttendeeWrite]? {
        commitInput()
        let result = combined(parsed: parsed)
        return isNew ? (result.isEmpty ? nil : result) : (result == initial ? nil : result)
    }
}
