import Testing
@testable import FloridaCore

@Suite struct SelectorSearchTests {
    @Test func ranksPrefixBeforeSubstringBeforeSubsequence() {
        let labels = ["Annual Review", "Review", "Roadmap Event", "Preview", "Research", "Revenue"]
        #expect(SelectorSearch.rankedIndices(in: labels, query: "rev") == [1, 5, 0, 3, 2])
    }

    @Test func preservesInputOrderWithinEachRank() {
        let labels = ["X Work", "Work Zebra", "W-o-r-k", "Work Alpha", "Y Work", "Wider Outlook Risk"]
        #expect(SelectorSearch.rankedIndices(in: labels, query: "work") == [1, 3, 0, 4, 2, 5])
        #expect(SelectorSearch.rankedIndices(in: ["Work", "Work", "Work"], query: "work") == [0, 1, 2])
    }

    @Test func ignoresCaseAndDiacritics() {
        let labels = ["Café", "CAFETERIA", "A cafe\u{301}", "Caffè", "Home"]
        #expect(SelectorSearch.rankedIndices(in: labels, query: "CAFÉ") == [0, 1, 2, 3])
        #expect(SelectorSearch.rankedIndices(in: ["Résumé", "Rose essays"], query: "rés") == [0, 1])
    }

    @Test func emptyQueryKeepsCategoryOrder() {
        let labels = ["Zebra", "", "Home", "Work"]
        #expect(SelectorSearch.rankedIndices(in: labels, query: "") == [0, 1, 2, 3])
        #expect(SelectorSearch.rankedIndices(in: labels, query: " \n\t ") == [0, 1, 2, 3])
        #expect(SelectorSearch.rankedIndices(in: labels, query: " home ") == [2])
    }

    @Test func fuzzyMatchRequiresEveryCharacterInOrder() {
        #expect(SelectorSearch.rankedIndices(in: ["abc", "acb", "aabbcc", "", "ab"], query: "abc") == [0, 2])
        #expect(SelectorSearch.rankedIndices(in: ["aba", "abb", "baba"], query: "aaa").isEmpty)
        #expect(SelectorSearch.rankedIndices(in: [], query: "work").isEmpty)
        #expect(SelectorSearch.rankedIndices(in: ["Home"], query: "xyz").isEmpty)
    }
}
