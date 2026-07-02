import Foundation

/// 意味検索の本体。チャンク埋め込みを生成・保存し、メモリ上で brute-force cosine する。
/// 個人のドキュメント規模(数千チャンク × 512 次元)では ANN なしで ms オーダ。
public final class SemanticStore {
    private let store: IndexStore
    private let embedder: Embedder
    private var cache: [(chunkId: Int64, fileId: Int64, seg: Int32, vec: [Float])] = []
    private var fileCentroids: [Int64: [Float]] = [:]   // 文書全体の意味ベクトル(素朴ベースライン)
    private var dirty = true

    public init(store: IndexStore, embedder: Embedder) {
        self.store = store
        self.embedder = embedder
    }

    public var isAvailable: Bool { embedder.isAvailable }

    /// 未ベクトル化チャンクを埋め込み、保存する。返り値 = 今回埋め込んだ件数。
    /// 語彙/構造の更新後に背景で呼ぶ(結果整合)。
    @discardableResult
    public func embedPending(maxBatches: Int = 1000) throws -> Int {
        guard embedder.isAvailable else { return 0 }
        var total = 0
        for _ in 0..<maxBatches {
            let pending = try store.chunksMissingVectors(limit: 32)
            if pending.isEmpty { break }
            for (id, text, context) in pending {
                let segs = Self.segments(text)
                // 埋め込み入力は文脈(タイトル+見出し)前置、保存する text はセグメント原文
                let pairs: [(vec: [Float], text: String)] = segs.compactMap { seg in
                    embedder.embed(Self.withContext(context, seg), kind: .document).map { ($0, seg) }
                }
                try store.setSegments(chunkId: id, segments: pairs)   // 空でも番兵で処理済みに
                total += 1
            }
            dirty = true
        }
        return total
    }

    /// 各セグメントに話題語(タイトル+見出し)を前置して埋め込む。概念クエリとの一致を強める。
    static func withContext(_ context: String, _ segment: String) -> String {
        context.isEmpty ? segment : "\(context)\n\(segment)"
    }

    /// 未ベクトル化チャンクを 1 バッチだけ埋め込む(呼び出し側で yield して検索を割り込ませる用)。
    /// 返り値 = 今回処理したチャンク数。0 なら残りなし。
    @discardableResult
    public func embedNextBatch(limit: Int = 16) throws -> Int {
        guard embedder.isAvailable else { return 0 }
        let pending = try store.chunksMissingVectors(limit: limit)
        if pending.isEmpty { return 0 }
        for (id, text, context) in pending {
            let segs = Self.segments(text)
            let pairs: [(vec: [Float], text: String)] = segs.compactMap { seg in
                embedder.embed(Self.withContext(context, seg), kind: .document).map { ($0, seg) }
            }
            try store.setSegments(chunkId: id, segments: pairs)
        }
        dirty = true
        return pending.count
    }

    /// チャンク本文を段落→(長ければ)文でセグメント化する。意味検索の粒度。
    static func segments(_ text: String, maxCount: Int = 16, target: Int = 220) -> [String] {
        var out: [String] = []
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: { $0.isEmpty })
            .map { $0.joined(separator: " ") }
        for para in paragraphs {
            if para.count <= target {
                if para.count >= 4 { out.append(para) }
            } else {
                // 長い段落は文単位に分け、~target 文字へ束ねる
                var buf = ""
                for sentence in splitSentences(para) {
                    if buf.count + sentence.count > target, !buf.isEmpty { out.append(buf); buf = "" }
                    buf += sentence
                }
                if buf.count >= 4 { out.append(buf) }
            }
            if out.count >= maxCount { break }
        }
        if out.isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out = [String(t.prefix(target))] }
        }
        return Array(out.prefix(maxCount))
    }

    private static func splitSentences(_ s: String) -> [String] {
        var result: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ch == "。" || ch == "！" || ch == "？" || ch == "." || ch == "!" || ch == "?" {
                result.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { result.append(cur) }
        return result
    }

    private func ensureLoaded() {
        guard dirty else { return }
        cache = (try? store.allVectors()) ?? []
        // 文書ごとのセントロイド(全セグメント平均→正規化)を第2意味ビューとして用意
        var sums: [Int64: [Float]] = [:]
        for (_, fid, _, vec) in cache {
            if sums[fid] == nil { sums[fid] = [Float](repeating: 0, count: vec.count) }
            for i in 0..<min(sums[fid]!.count, vec.count) { sums[fid]![i] += vec[i] }
        }
        fileCentroids = sums.mapValues { VectorMath.normalized($0) }
        dirty = false
    }

    /// 2つの意味ビューの重み付き和: segment-max cosine + β × 文書セントロイド cosine。
    /// max 結合(C13)は誤文書の単一セグメント spike に弱かったが、和は「両ビューの合意」を報いる。
    /// hybrid の概念クエリ専用(ゲートは呼び出し側)。seg = 最類似セグメント(スニペット/着地用)。
    public func searchSum(_ query: String, beta: Float, limit: Int) -> [(chunkId: Int64, score: Float, seg: Int32)] {
        guard embedder.isAvailable, !query.isEmpty else { return [] }
        guard let qv = embedder.embed(query, kind: .query) else { return [] }
        ensureLoaded()
        var best: [Int64: (score: Float, seg: Int32)] = [:]   // chunk → best segment
        var chunkFile: [Int64: Int64] = [:]
        for (cid, fid, seg, vec) in cache {
            let s = VectorMath.dot(qv, vec)
            if s > (best[cid]?.score ?? -2) { best[cid] = (s, seg) }
            if chunkFile[cid] == nil { chunkFile[cid] = fid }
        }
        var cent: [Int64: Float] = [:]     // file → centroid cosine
        for (fid, c) in fileCentroids { cent[fid] = VectorMath.dot(qv, c) }
        var combined: [Int64: (score: Float, seg: Int32)] = [:]
        for (cid, b) in best {
            combined[cid] = (b.score + beta * (chunkFile[cid].flatMap { cent[$0] } ?? 0), b.seg)
        }
        return combined.sorted { a, b in
            if a.value.score != b.value.score { return a.value.score > b.value.score }
            return a.key < b.key   // 決定的タイブレーク
        }.prefix(limit).map { ($0.key, $0.value.score, $0.value.seg) }
    }

    public func markDirty() { dirty = true }

    /// クエリに意味的に近いチャンクを返す(降順)。1 チャンク内の複数セグメントは最大類似を採る。
    /// seg = 最類似セグメント(スニペット/着地用)。
    public func search(_ query: String, limit: Int) -> [(chunkId: Int64, score: Float, seg: Int32)] {
        guard embedder.isAvailable, !query.isEmpty else { return [] }
        guard let qv = embedder.embed(query, kind: .query) else { return [] }
        ensureLoaded()
        guard !cache.isEmpty else { return [] }
        var best: [Int64: (score: Float, seg: Int32)] = [:]
        for (cid, _, seg, vec) in cache {
            let s = VectorMath.dot(qv, vec)
            if s > (best[cid]?.score ?? -2) { best[cid] = (s, seg) }
        }
        return best.sorted { a, b in
            if a.value.score != b.value.score { return a.value.score > b.value.score }
            return a.key < b.key   // 決定的タイブレーク
        }.prefix(limit).map { ($0.key, $0.value.score, $0.value.seg) }
    }
}
