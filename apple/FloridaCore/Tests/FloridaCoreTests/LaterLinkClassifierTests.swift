import Foundation
import Testing
@testable import FloridaCore

@Suite struct LaterLinkClassifierTests {
    @Test(arguments: [
        "https://newsletter.substack.com/p/why-it-works",
        "https://medium.com/@writer/product/story",
        "https://www.nytimes.com/2026/11/20/technology/story.html",
        "https://news.example.com/products/report",
        "https://blog.example.com/product/announcement",
        "https://example.com/blog/shop-trends",
        "https://example.com/p/product/comparison",
        "https://example.com/posts/shop/interview",
        "https://example.com/2026/11/product/review",
        "https://example.com/something-new",
        "https://youtube.com.example.org/story",
        "https://notamazon.com/story",
    ])
    func articlesAndUnknownWebLinks(url: String) {
        #expect(LaterLinkClassifier.classify(url) == .later(.article))
    }

    @Test(arguments: [
        "https://WWW.YouTube.com/watch?v=example",
        "https://m.youtube.com/shorts/example",
        "https://youtu.be/example",
        "https://player.vimeo.com/video/123",
        "https://vimeo.com./123",
    ])
    func videos(url: String) throws {
        #expect(LaterLinkClassifier.classify(try #require(URL(string: url))) == .later(.video))
    }

    @Test(arguments: [
        "https://www.amazon.co.uk/dp/X",
        "https://www.amazon.com/",
        "https://store.myshopify.com/collections/all",
        "https://example.com/product/mug",
        "https://example.com/products/mug",
        "https://example.com/dp/mug",
        "https://github.com/example/repo",
        "https://github.com/example/repo/pull/42",
        "https://maps.apple.com/place?foo=bar",
        "https://www.google.com/maps/place/example",
        "https://maps.app.goo.gl/example",
        "https://docs.google.com/document/d/example",
        "https://developer.mozilla.org/en-US/docs/Web",
        "https://docs.example.com/start",
        "https://example.com/documentation/start",
        "https://example.notion.site/share",
        "mailto:user@example.com",
        "file:///tmp/example",
        "https://user:pass@example.com",
        "https://example.com/%00",
        "garbage",
    ])
    func tasksAndNonWebLinks(url: String) {
        #expect(LaterLinkClassifier.classify(url) == .task)
    }
}
