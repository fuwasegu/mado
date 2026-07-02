import Foundation
import SearchCore

/// 検索インデックスのバックグラウンド所有者。
///
/// すべての indexing / 検索は actor 内(= MainActor の外)で直列実行され、UI スレッドに触れない。
/// これにより WKWebView の描画(別プロセス)も含め、表示パフォーマンスに影響しない。
actor SearchIndex {
    private var store: IndexStore?
    private var root: URL?
    /// 意味検索の埋め込み。高品質な e5(CoreML)を優先し、使えなければ zero-dep の NLEmbedding。
    private lazy var embedder: Embedder = Self.makeEmbedder()
    private var semantic: SemanticStore?

    private static func makeEmbedder() -> Embedder {
        let e5 = CoreMLEmbedder()
        if e5.isAvailable { NSLog("[SearchIndex] embedder = e5 (CoreML)"); return e5 }
        NSLog("[SearchIndex] embedder = NLContextual (fallback)")
        return NLEmbedder(language: .japanese)
    }

    /// フォルダごとに 1 つの index ファイル。アプリと MCP サーバが同じパスを共有する。
    static func indexURL(for root: URL) -> URL { IndexLocation.url(forRoot: root) }

    /// フォルダを開いた時に呼ぶ。既存 index を開き(無ければ作成)、背景で差分照合する。
    func openAndReconcile(root: URL) {
        self.root = root
        do {
            store = try IndexStore(path: Self.indexURL(for: root).path)
        } catch {
            NSLog("[SearchIndex] open failed: \(error)")
            store = nil
            return
        }
        guard let store else { return }
        semantic = SemanticStore(store: store, embedder: embedder)
        // 埋め込みモデルが変わっていたら旧ベクトルを破棄(次元/意味空間が違うため)
        if (try? store.embedModelID()) != embedder.identifier {
            try? store.clearAllVectors()
            try? store.setEmbedModelID(embedder.identifier)
            semantic?.markDirty()
            NSLog("[SearchIndex] embed model=\(embedder.identifier) → ベクトル再構築")
        }
        do {
            let stats = try Indexer.reconcile(root: root, store: store, nowEpoch: Date().timeIntervalSince1970)
            NSLog("[SearchIndex] reconcile: +\(stats.added) ~\(stats.updated) -\(stats.removed) =\(stats.skipped)")
        } catch {
            NSLog("[SearchIndex] reconcile failed: \(error)")
        }
        // 埋め込みは重い。actor を占有せず小バッチ+yield で回し、検索を割り込ませる(結果整合)。
        startEmbedding()
    }

    private var embedding = false
    private var progressHandler: (@Sendable (Int, Int) -> Void)?

    /// 進捗(done, total)を受け取るハンドラを設定(UI が @Published へ反映する)。
    func setProgressHandler(_ h: @escaping @Sendable (Int, Int) -> Void) { progressHandler = h }

    /// 背景で未ベクトル化チャンクをバッチ埋め込みする。既に走っていれば何もしない。
    func startEmbedding() {
        guard let semantic, semantic.isAvailable, !embedding else { return }
        embedding = true
        Task { await self.embedLoop() }
    }

    private func embedLoop() async {
        guard let semantic, let store else { embedding = false; return }
        let total = (try? store.pendingVectorCount()) ?? 0
        guard total > 0 else { embedding = false; return }
        progressHandler?(0, total)
        var done = 0
        while true {
            let n = (try? semantic.embedNextBatch(limit: 16)) ?? 0
            if n == 0 { break }
            done += n
            progressHandler?(min(done, total), total)
            await Task.yield()   // ここで search() 等の actor メッセージが割り込める
        }
        progressHandler?(total, total)   // 完了 → UI は非表示に
        embedding = false
        if done > 0 { NSLog("[SearchIndex] embedded \(done) chunks") }
    }

    /// FSEvents 由来の変更パス群を index に反映(増分)。
    func apply(paths: [String]) {
        guard let store, let root else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for p in paths {
            if (try? Indexer.updatePath(URL(fileURLWithPath: p), root: root, store: store, nowEpoch: now)) == true {
                changed = true
            }
        }
        if changed {
            semantic?.markDirty()
            startEmbedding()   // 変更チャンクを背景で再ベクトル化
        }
    }

    /// ハイブリッド検索(構造化 + 全文 + 意味)。DSL: `tag:api status:draft "句" 自由語`。
    func search(_ query: String, limit: Int = 50) -> [SearchHit] {
        guard let store else { return [] }
        return QueryService(store: store, semantic: semantic).search(query, limit: limit)
    }

    /// CLI 用: 未ベクトル化チャンクを最後まで同期的に埋め込む(背景 loop と違い待てる)。
    @discardableResult
    func embedAllBlocking() -> Int {
        guard let semantic, semantic.isAvailable else { return 0 }
        var total = 0
        while let n = try? semantic.embedNextBatch(limit: 32), n > 0 { total += n }
        return total
    }

    /// クエリの解釈(検索窓の下に出すチップ + ハイライト語)。
    nonisolated func interpret(_ query: String) -> SearchInterpretation {
        QueryPlanner.interpret(query)
    }

    /// CLI / 検証用の件数。
    func indexStats() -> (files: Int, chunks: Int) {
        guard let store else { return (0, 0) }
        return ((try? store.fileCount()) ?? 0, (try? store.chunkCount()) ?? 0)
    }
}
