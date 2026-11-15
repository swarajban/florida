import Foundation

public enum DeepLink: Equatable, Sendable {
    case agenda(day: String? = nil)
    case tasks
    case newTask
    case task(UUID)
    case project(UUID)
    case settings

    public init?(url: URL) {
        guard url.scheme == "florida", let host = url.host else { return nil }
        let path = url.path
        switch (host, path) {
        case ("agenda", ""): self = .agenda()
        case ("tasks", ""): self = .tasks
        case ("tasks", "/new"): self = .newTask
        case ("settings", ""): self = .settings
        default:
            let value = String(path.dropFirst())
            if host == "agenda", Self.date(for: value, timeZone: .gmt) != nil {
                self = .agenda(day: value)
            } else if ["task", "tasks"].contains(host), let id = UUID(uuidString: value) {
                self = .task(id)
            } else if ["project", "projects"].contains(host), let id = UUID(uuidString: value) {
                self = .project(id)
            } else {
                return nil
            }
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "florida"
        switch self {
        case .agenda(let day):
            parts.host = "agenda"
            parts.path = day.map { "/\($0)" } ?? ""
        case .tasks: parts.host = "tasks"
        case .newTask:
            parts.host = "tasks"
            parts.path = "/new"
        case .task(let id):
            parts.host = "tasks"
            parts.path = "/\(id.uuidString.lowercased())"
        case .project(let id):
            parts.host = "projects"
            parts.path = "/\(id.uuidString.lowercased())"
        case .settings: parts.host = "settings"
        }
        return parts.url!
    }

    public func agendaDate(timeZone: TimeZone) -> Date? {
        guard case .agenda(let day?) = self else { return nil }
        return Self.date(for: day, timeZone: timeZone)
    }

    private static func date(for day: String, timeZone: TimeZone) -> Date? {
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.map(\.count) == [4, 2, 2],
              day.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(pieces[0]), year > 0, let month = Int(pieces[1]), let date = Int(pieces[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: date)
        guard let result = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: result) == components
        else { return nil }
        return result
    }
}
