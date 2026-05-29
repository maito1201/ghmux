import Foundation
import Testing
@testable import gmuxCore

@Suite("PRLinkExtractor")
struct PRLinkExtractorTests {

    @Test func extractsSingleURL() {
        let urls = PRLinkExtractor.matchAll(in: "Created PR: https://github.com/acme/widgets/pull/42")
        #expect(urls.map(\.absoluteString) == ["https://github.com/acme/widgets/pull/42"])
    }

    @Test func extractsMultipleUnique() {
        let text = """
            See https://github.com/a/b/pull/1 and https://github.com/a/b/pull/2.
            Also https://github.com/a/b/pull/1 (duplicate).
            """
        let urls = PRLinkExtractor.matchAll(in: text).map(\.absoluteString)
        #expect(urls == [
            "https://github.com/a/b/pull/1",
            "https://github.com/a/b/pull/2",
        ])
    }

    @Test func ignoresIssueURLs() {
        let text = "Filed https://github.com/a/b/issues/42 then opened https://github.com/a/b/pull/99"
        let urls = PRLinkExtractor.matchAll(in: text).map(\.absoluteString)
        #expect(urls == ["https://github.com/a/b/pull/99"])
    }

    @Test func instanceTracksAlreadySeen() {
        let ext = PRLinkExtractor()
        let first = ext.extractNew(from: "open https://github.com/a/b/pull/1")
        let second = ext.extractNew(from: "still https://github.com/a/b/pull/1 plus https://github.com/a/b/pull/2")
        #expect(first.map(\.absoluteString) == ["https://github.com/a/b/pull/1"])
        #expect(second.map(\.absoluteString) == ["https://github.com/a/b/pull/2"])
    }

    @Test func resetClearsHistory() {
        let ext = PRLinkExtractor()
        _ = ext.extractNew(from: "https://github.com/a/b/pull/1")
        ext.reset()
        let again = ext.extractNew(from: "https://github.com/a/b/pull/1")
        #expect(again.count == 1)
    }

    @Test func acceptsOwnerWithDotAndDash() {
        let urls = PRLinkExtractor.matchAll(in: "https://github.com/foo-bar/baz.qux/pull/7")
        #expect(urls.count == 1)
    }

    @Test func ignoresMalformedURLs() {
        let urls = PRLinkExtractor.matchAll(in: "github.com/a/b/pull/1 https://github.com/a/b/pull/abc")
        #expect(urls.isEmpty)
    }
}
