import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskMetadataInputTests {
    private var task: TaskItem {
        TaskItem(id: "task", categoryId: "work", title: "Review proposal", durationMinutes: 30,
                 createdAt: Date(), updatedAt: Date(), tags: ["client", "review"], waitingOn: "Alice")
    }

    @Test func inputUsesExistingNormalization() throws {
        var edited = task
        edited.tags += TaskItem.tagsFromInput("#CLIENT, Finance\n#Review  ")
        try edited.normalizeMetadata()
        #expect(edited.tags == ["client", "review", "finance"])
    }

    @Test func localSearchCombinesWaitingAndTags() {
        #expect(task.matchesMetadataSearch("#CLIENT Alice", waitingOnly: true))
        #expect(task.matchesMetadataSearch("proposal"))
        #expect(!task.matchesMetadataSearch("#cli"))
        #expect(!task.matchesMetadataSearch("#client Bob"))
        var active = task
        active.waitingOn = nil
        #expect(!active.matchesMetadataSearch("", waitingOnly: true))
        #expect(active.matchesMetadataSearch(""))
    }
}
