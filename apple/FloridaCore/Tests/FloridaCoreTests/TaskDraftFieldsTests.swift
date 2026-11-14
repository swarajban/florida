import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskDraftFieldsTests {
    @Test func serverSchedulingFieldsSurviveDraftDecodingAndEncoding() throws {
        let data = Data("""
            {"title":"Parsed task","durationMinutes":90,"priority":"high","deadlineType":"soft",\
            "context":"errand","projectId":"project-audit","attention":"shared","rationale":"A proposal"}
            """.utf8)
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(draft)) as? [String: Any])
        #expect(encoded["context"] as? String == "errand")
        #expect(encoded["projectId"] as? String == "project-audit")
        #expect(encoded["attention"] as? String == "shared")
    }

    @Test func legacyDraftsDoNotRequireSchedulingFields() throws {
        let data = Data("""
            {"title":"Legacy task","durationMinutes":30,"priority":"medium","deadlineType":"none","rationale":""}
            """.utf8)
        let draft = try JSONCoding.decoder.decode(TaskDraft.self, from: data)
        #expect(draft.title == "Legacy task")
        #expect(draft.context == nil)
        #expect(draft.projectId == nil)
        #expect(draft.attention == nil)
    }
}
