import XCTest
@testable import SearchCore

final class SemanticTests: XCTestCase {

    private func buildCorpus(_ files: [String: String]) throws -> (IndexStore, SemanticStore, () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mado-sem-\(UUID().uuidString)")
        for (rel, content) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let dbPath = NSTemporaryDirectory() + "mado-sem-\(UUID().uuidString).sqlite"
        let store = try IndexStore(path: dbPath)
        _ = try Indexer.reconcile(root: root, store: store, nowEpoch: 1_700_000_000)
        let sem = SemanticStore(store: store, embedder: NLEmbedder(language: .japanese))
        return (store, sem, {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: dbPath)
        })
    }

    func testSemanticRecallBeyondLexical() throws {
        let (store, sem, cleanup) = try buildCorpus([
            "auth.md": "# ログイン認証\nOAuth2 を用いてアクセストークンを発行し、有効期限を管理する。",
            "csv.md": "# 表データ\nCSV ファイルを RFC4180 で解析し、行番号を付けて表示する。",
            "theme.md": "# 外観\nダークモードに追従してテーマを切り替える。",
        ])
        defer { cleanup() }
        try XCTSkipUnless(sem.isAvailable, "NLContextualEmbedding assets unavailable")
        _ = try sem.embedPending()
        XCTAssertGreaterThan(try store.vectorCount(), 0, "チャンクがベクトル化される")

        // クエリ「サインインの手順」は corpus と語彙がほぼ重ならない(ログイン認証/OAuth とは別語)
        let query = "サインインの手順とトークン発行"
        let lexicalOnly = QueryService(store: store, semantic: nil).search(query)
        let withSemantic = QueryService(store: store, semantic: sem).search(query)

        // 意味検索ありなら auth.md が上位に出る(言い換えを捕捉)
        XCTAssertTrue(withSemantic.contains { $0.relPath == "auth.md" },
                      "意味検索で auth.md を回収(lexical=\(lexicalOnly.map{$0.relPath}), semantic=\(withSemantic.map{$0.relPath}))")
        XCTAssertTrue(withSemantic.first?.kinds.contains(.semantic) ?? false ||
                      withSemantic.contains { $0.kinds.contains(.semantic) },
                      "semantic 種別が付与される")
    }

    func testSemanticRespectsStructuredFilter() throws {
        let (store, sem, cleanup) = try buildCorpus([
            "draft.md": "---\nstatus: draft\n---\n# ログイン認証\nアクセストークンを発行する。",
            "pub.md": "---\nstatus: published\n---\n# ログイン認証\nアクセストークンを発行する。",
        ])
        defer { cleanup() }
        try XCTSkipUnless(sem.isAvailable, "embeddings unavailable")
        _ = try sem.embedPending()

        // 意味的には両方ヒットするが status:draft で draft.md のみ
        let hits = QueryService(store: store, semantic: sem).search("status:draft サインイン認証の手順")
        XCTAssertTrue(hits.allSatisfy { $0.relPath == "draft.md" }, "意味検索も構造化フィルタに従う")
        XCTAssertFalse(hits.isEmpty)
    }
}

final class SegmentationTests: XCTestCase {
    func testSegmentsSplitByParagraphAndSentence() {
        let text = """
        # 見出し
        短い段落です。

        これは長い段落で、複数の文から成ります。認証はOAuth2で行います。トークンの有効期限は3600秒です。失効したらリフレッシュします。さらに続きの文章がここにあってそれなりの長さになるように埋めています。区切りの確認をします。
        """
        let segs = SemanticStore.segments(text, maxCount: 16, target: 60)
        XCTAssertGreaterThan(segs.count, 1, "段落/文で複数セグメントに分割される")
        XCTAssertTrue(segs.allSatisfy { !$0.isEmpty })
    }
}

final class CoreMLEmbedderTests: XCTestCase {
    // Python(torch)実測で top1=4/5 だった検索セットを Swift/CoreML 経路で再現し、
    // トークナイズ+変換+int8 が壊れていないことを確認する。
    func testE5RetrievalQuality() throws {
        let e = CoreMLEmbedder()
        try XCTSkipUnless(e.isAvailable, "e5 CoreML モデルをロードできない環境")
        XCTAssertEqual(e.dimension, 384)

        let corpus = [
            "ユーザー登録ではメールアドレスとパスワードを受け取り確認メールを送る",
            "ログイン認証はOAuth2を用い、アクセストークンを発行して有効期限を管理する",
            "リフレッシュトークンを使ってセッションを更新し、ローテーションする",
            "支払い処理はStripeを経由し、Webhookで決済完了を受け取る",
            "CSVファイルはRFC4180準拠でパースし、ヘッダを固定して行番号を付ける",
            "MermaidのコードブロックはSVGに描画してキャッシュする",
            "OpenAPIドキュメントはRedocで表示し、外部$refを解決する",
            "ダークモードに追従してテーマを切り替える",
        ]
        let queries: [(String, Int)] = [
            ("サインインの仕組みとトークンの発行手順は?", 1),
            ("会員のアカウント作成フローを知りたい", 0),
            ("クレジットカード決済の連携方法", 3),
            ("表形式データの読み込みと表示", 4),
            ("図表のレンダリングとキャッシュ", 5),
        ]
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map(*).reduce(0, +) }
        let docVecs = corpus.map { e.embed($0, kind: .document)! }
        var top1 = 0
        for (q, gold) in queries {
            let qv = e.embed(q, kind: .query)!
            let ranked = docVecs.enumerated().max { dot(qv, $0.element) < dot(qv, $1.element) }!
            if ranked.offset == gold { top1 += 1 }
        }
        // Python では 4/5。int8 量子化ノイズを見て 3 以上を合格とする。
        XCTAssertGreaterThanOrEqual(top1, 3, "e5/CoreML の top-1 が低すぎる(\(top1)/5)= トークナイズ/変換の疑い")
    }
}
