import XCTest
@testable import SearchCore

final class QueryParserTests: XCTestCase {

    func testFieldExtraction() {
        let q = QueryParser.parse("tag:api status:draft 認証 \"完全 一致\"")
        XCTAssertEqual(q.filters.tags, ["api"])
        XCTAssertEqual(q.filters.status, ["draft"])
        XCTAssertEqual(q.lexicalTerms, ["認証", "完全 一致"])
    }

    func testDateRangeOperators() {
        let q = QueryParser.parse("modified:>2026-06-01")
        XCTAssertNotNil(q.filters.modifiedAfter)
        XCTAssertNil(q.filters.modifiedBefore)

        let month = QueryParser.parse("modified:2026-06")
        XCTAssertNotNil(month.filters.modifiedAfter)
        XCTAssertNotNil(month.filters.modifiedBefore)
        // 6月の範囲 = 7月1日未満
        XCTAssertLessThan(month.filters.modifiedAfter!, month.filters.modifiedBefore!)
    }

    func testIsTaskAndLangAndPath() {
        let q = QueryParser.parse("is:todo lang:swift path:docs")
        XCTAssertEqual(q.filters.taskState, .todo)
        XCTAssertEqual(q.filters.langs, ["swift"])
        XCTAssertEqual(q.filters.pathContains, ["docs"])
    }

    func testURLNotMisparsedAsField() {
        // http://... の "http:" を field 扱いしない(key は単純語のみ)
        let q = QueryParser.parse("https://example.com")
        XCTAssertTrue(q.filters.isEmpty)
        XCTAssertEqual(q.lexicalTerms, ["https://example.com"])
    }
}

final class HybridSearchTests: XCTestCase {

    private func makeIndexedStore(_ files: [String: String]) throws -> (IndexStore, () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mado-hybrid-\(UUID().uuidString)")
        for (rel, content) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let dbPath = NSTemporaryDirectory() + "mado-hyb-\(UUID().uuidString).sqlite"
        let store = try IndexStore(path: dbPath)
        _ = try Indexer.reconcile(root: root, store: store, nowEpoch: 1_700_000_000)
        return (store, {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: dbPath)
        })
    }

    func testStructuredFilterNarrowsLexical() throws {
        let (store, cleanup) = try makeIndexedStore([
            "draft.md": "---\ntags: [api]\nstatus: draft\n---\n# 認証\nOAuth2 の認証フロー。",
            "published.md": "---\ntags: [api]\nstatus: published\n---\n# 認証\n公開済みの認証ドキュメント。",
            "other.md": "# メモ\n認証とは関係ない雑記。",
        ])
        defer { cleanup() }
        let svc = QueryService(store: store)

        // 全文のみ: 3 件すべて「認証」を含む
        XCTAssertGreaterThanOrEqual(svc.search("認証").count, 2)

        // status:draft で絞る → draft.md だけ
        let draftOnly = svc.search("status:draft 認証")
        XCTAssertTrue(draftOnly.allSatisfy { $0.relPath == "draft.md" })
        XCTAssertEqual(draftOnly.count, 1)
        XCTAssertTrue(draftOnly[0].kinds.contains(.lexical))
        XCTAssertTrue(draftOnly[0].kinds.contains(.structured))
    }

    func testStructuredOnlyQuery() throws {
        let (store, cleanup) = try makeIndexedStore([
            "a.md": "---\nstatus: draft\n---\n# A\n本文。",
            "b.md": "---\nstatus: done\n---\n# B\n本文。",
        ])
        defer { cleanup() }
        let svc = QueryService(store: store)
        let drafts = svc.search("status:draft")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].relPath, "a.md")
        XCTAssertTrue(drafts[0].kinds.contains(.structured))
        XCTAssertFalse(drafts[0].kinds.contains(.lexical))
    }

    func testTagAndLangFilter() throws {
        let (store, cleanup) = try makeIndexedStore([
            "x.md": "---\ntags: [infra]\n---\n# X\n```swift\nlet x = 1\n```",
            "y.md": "---\ntags: [docs]\n---\n# Y\n```python\ny = 1\n```",
        ])
        defer { cleanup() }
        let svc = QueryService(store: store)
        XCTAssertEqual(svc.search("tag:infra").map { $0.relPath }, ["x.md"])
        XCTAssertEqual(svc.search("lang:python").map { $0.relPath }, ["y.md"])
        XCTAssertTrue(svc.search("tag:infra lang:python").isEmpty)  // AND
    }

    func testSnippetCentersOnTerm() throws {
        let (store, cleanup) = try makeIndexedStore([
            "long.md": "# 長文\n" + String(repeating: "前置き。", count: 30) + "ここに検索語キーワードがある。" + String(repeating: "後置き。", count: 30),
        ])
        defer { cleanup() }
        let hits = QueryService(store: store).search("キーワード")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("キーワード"))
        XCTAssertTrue(hits[0].snippet.count < 200, "スニペットは窓で切られる")
    }
}
