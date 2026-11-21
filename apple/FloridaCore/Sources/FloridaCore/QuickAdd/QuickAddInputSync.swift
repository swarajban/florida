public struct QuickAddInputSync {
    public private(set) var appliedRevision: Int

    public init(revision: Int) {
        appliedRevision = revision
    }

    public mutating func takeEdit(revision: Int, hasMarkedText: Bool) -> Bool {
        guard revision > appliedRevision, !hasMarkedText else { return false }
        appliedRevision = revision
        return true
    }
}
