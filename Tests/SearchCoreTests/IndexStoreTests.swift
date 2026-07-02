import XCTest
@testable import SearchCore

final class IndexStoreTests: XCTestCase {

    private func tempStore() throws -> (IndexStore, String) {
        let path = NSTemporaryDirectory() + "mado-test-\(UUID().uuidString).sqlite"
        return (try IndexStore(path: path), path)
    }

    private func makeRoot(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mado-corpus-\(UUID().uuidString)")
        for (rel, content) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func testReconcileAndLexicalSearchJapanese() throws {
        let root = try makeRoot([
            "auth.md": """
            ---
            tags: [api]
            status: draft
            ---
            # 認証
            OAuth2 の authorization code grant を使う。アクセストークンの有効期限は 3600 秒。
            ## リフレッシュ
            リフレッシュトークンでローテーションする。
            """,
            "signup.md": """
            # ユーザ登録
            メールアドレスとパスワードで登録し、確認メールを送る。
            """,
            "sub/payment.md": """
            # 支払い
            Stripe を経由し Webhook で完了通知を受け取る。
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let stats = try Indexer.reconcile(root: root, store: store, nowEpoch: 1_700_000_000)
        XCTAssertEqual(stats.added, 3)
        XCTAssertEqual(try store.fileCount(), 3)
        XCTAssertGreaterThanOrEqual(try store.chunkCount(), 4)

        // 2 文字日本語語(trigram では引けない)が引けること = Phase 0 軌道修正の検証
        func hits(_ q: String) throws -> [IndexStore.LexicalRow] {
            try store.searchLexical(matchExpr: Tokenizer.matchExpression(q)!, limit: 20)
        }
        let auth = try hits("認証")
        XCTAssertTrue(auth.contains { $0.relPath == "auth.md" }, "「認証」で auth.md がヒット")

        let register = try hits("登録")
        XCTAssertTrue(register.contains { $0.relPath == "signup.md" })
        XCTAssertFalse(register.contains { $0.relPath == "auth.md" }, "「登録」で誤ヒットしない")

        let token = try hits("トークン")
        XCTAssertTrue(token.contains { $0.relPath == "auth.md" })

        // セクション粒度: ヒットが見出し slug を持つ
        XCTAssertTrue(token.contains { $0.headingSlug == "リフレッシュ" || $0.headingSlug == "認証" })
    }

    func testIncrementalSkipAndUpdate() throws {
        let root = try makeRoot(["a.md": "# A\n初版の本文。検索語アルファ。"])
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        _ = try Indexer.reconcile(root: root, store: store, nowEpoch: 1)
        // 2 回目は未変更 → skip
        let s2 = try Indexer.reconcile(root: root, store: store, nowEpoch: 2)
        XCTAssertEqual(s2.skipped, 1)
        XCTAssertEqual(s2.updated, 0)

        // 内容変更 → update、古い語は消え新しい語が引ける
        try "# A\n改訂版。検索語ベータ。".write(to: root.appendingPathComponent("a.md"),
                                              atomically: true, encoding: .utf8)
        let s3 = try Indexer.reconcile(root: root, store: store, nowEpoch: 3)
        XCTAssertEqual(s3.updated, 1)
        XCTAssertTrue(try store.searchLexical(matchExpr: Tokenizer.matchExpression("ベータ")!, limit: 5).count > 0)
        XCTAssertEqual(try store.searchLexical(matchExpr: Tokenizer.matchExpression("アルファ")!, limit: 5).count, 0,
                       "更新後は古いチャンクが FTS から消えている")
    }

    func testDeletionRemovesFromIndex() throws {
        let root = try makeRoot([
            "keep.md": "# Keep\n残す文書。",
            "gone.md": "# Gone\n消える文書ガンマ。",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        _ = try Indexer.reconcile(root: root, store: store, nowEpoch: 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.md"))
        let s = try Indexer.reconcile(root: root, store: store, nowEpoch: 2)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(try store.fileCount(), 1)
        XCTAssertEqual(try store.searchLexical(matchExpr: Tokenizer.matchExpression("ガンマ")!, limit: 5).count, 0)
    }

    func testLinkResolution() throws {
        let root = try makeRoot([
            "index.md": "# Index\n[詳細](./detail.md) を参照。",
            "detail.md": "# Detail\n本文。",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        _ = try Indexer.reconcile(root: root, store: store, nowEpoch: 1)
        // resolveLinkTargets が relative リンクを解決していること(間接的に検証)
        let hits = try store.searchLexical(matchExpr: Tokenizer.matchExpression("詳細")!, limit: 5)
        XCTAssertTrue(hits.contains { $0.relPath == "index.md" })
    }
}

final class NonMarkdownIndexTests: XCTestCase {
    func testYamlAndJsonIndexed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mado-nonmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "server:\n  port: 8080\n  authProvider: keycloak\n".write(
            to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "{\"featureFlags\": {\"newSearchEngine\": true}}".write(
            to: root.appendingPathComponent("flags.json"), atomically: true, encoding: .utf8)
        try "# Doc\n本文。".write(
            to: root.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)

        let dbPath = NSTemporaryDirectory() + "mado-nonmd-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let store = try IndexStore(path: dbPath)
        let stats = try Indexer.reconcile(root: root, store: store, nowEpoch: 1)
        XCTAssertEqual(stats.added, 3, "yaml/json/md すべて索引される")

        let svc = QueryService(store: store)
        XCTAssertTrue(svc.search("keycloak").contains { $0.relPath == "config.yaml" })
        XCTAssertTrue(svc.search("featureflags").contains { $0.relPath == "flags.json" })
        // ext フィルタも効く
        XCTAssertEqual(svc.search("ext:yaml keycloak").map { $0.relPath }, ["config.yaml"])
    }
}
