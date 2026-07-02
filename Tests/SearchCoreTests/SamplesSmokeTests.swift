import XCTest
@testable import SearchCore

/// 実際の Samples/ フォルダ(リポジトリ同梱の日本語 Markdown)に対する E2E スモークテスト。
final class SamplesSmokeTests: XCTestCase {

    private var samplesRoot: URL {
        // Tests/SearchCoreTests/<this file> → リポジトリルート/Samples
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SearchCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Samples")
    }

    func testIndexSamplesAndSearch() throws {
        let root = samplesRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "Samples/ not found")

        let dbPath = NSTemporaryDirectory() + "mado-samples-\(UUID().uuidString).sqlite"
        let store = try IndexStore(path: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let t0 = Date()
        let stats = try Indexer.reconcile(root: root, store: store, nowEpoch: t0.timeIntervalSince1970)
        let elapsed = Date().timeIntervalSince(t0)

        let files = try store.fileCount()
        let chunks = try store.chunkCount()
        print("[Samples] files=\(files) chunks=\(chunks) added=\(stats.added) in \(Int(elapsed * 1000))ms")

        XCTAssertGreaterThan(files, 0, "Samples に Markdown が 1 件以上ある")
        XCTAssertGreaterThan(chunks, 0)

        // Samples/README.md はレンダリングデモ。「コード」(2文字)と「mermaid」(英字)が存在する。
        let code = try store.searchLexical(matchExpr: Tokenizer.matchExpression("コード")!, limit: 10)
        XCTAssertGreaterThan(code.count, 0, "「コード」(2文字日本語)がヒット")

        let mermaid = try store.searchLexical(matchExpr: Tokenizer.matchExpression("mermaid")!, limit: 10)
        XCTAssertGreaterThan(mermaid.count, 0, "「mermaid」(英字)がヒット")

        // ヒットはセクション粒度: 見出し breadcrumb を持つ
        XCTAssertTrue(code.allSatisfy { !$0.path.isEmpty })
    }
}
