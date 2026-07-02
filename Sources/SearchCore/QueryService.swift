import Foundation

/// パース → フィルタ付き検索 → 3 信号(構造化 / 全文 BM25 / 意味 cosine)を RRF 融合し、
/// ランク付き SearchHit を返す高レベル API。アプリの SearchIndex actor と MCP が共有する。
public final class QueryService {
    private let store: IndexStore
    private let semantic: SemanticStore?

    public init(store: IndexStore, semantic: SemanticStore? = nil) {
        self.store = store
        self.semantic = semantic
    }

    /// 評価用に信号を切り替える。既定は hybrid(製品挙動)。
    public enum Mode: Sendable { case hybrid, lexical, semantic }

    public func search(_ raw: String, limit: Int = 50, mode: Mode = .hybrid) -> [SearchHit] {
        // 自然文プランナで時間軸・タスク状態を抽出し、残りを DSL/語彙/意味に。
        let parsed = QueryPlanner.plan(raw)
        if parsed.lexicalTerms.isEmpty && parsed.filters.isEmpty { return [] }

        let candidatePool = max(limit, 200)
        let matchExpr = Tokenizer.matchExpression(parsed.lexicalString)
        let useLexical = mode != .semantic
        let useSemantic = mode != .lexical

        // --- 全文(BM25): 語彙語があるときだけ。フィルタは SQL 側で適用済み ---
        let lexicalRows = (useLexical && matchExpr != nil)
            ? ((try? store.search(matchExpr: matchExpr, filters: parsed.filters, limit: candidatePool)) ?? [])
            : []
        let lexicalList = lexicalRows.map { $0.chunkId }

        // 概念クエリ判定: 厳密 AND がほぼ空振り = 既知アイテムではない。
        // 既知アイテム系(厳密一致が効く)では追加信号を全て無効化し、退行リスクをゼロにする。
        let conceptQuery = lexicalRows.count < 3

        // --- 緩和全文(OR-BM25 + 同義語展開, hybrid のみ): 自然文クエリ用の第2語彙信号 ---
        // 「語彙を外した」クエリでも本文には固有名詞等の識別語が残ることが多い。
        // 同義語(サインイン⇄ログイン等)は OR 側にのみ展開: IDF 重みでノイズになりにくい。
        // dev A/B: alias 追加で R@1 0.70→0.75(C17)。
        var relaxedRows: [IndexStore.LexicalRow] = []
        if mode == .hybrid, conceptQuery {
            var relaxedQuery = parsed.lexicalString
            let exp = Aliases.expansions(for: relaxedQuery)
            if !exp.isEmpty { relaxedQuery += " " + exp.joined(separator: " ") }
            if let orExpr = Tokenizer.orMatchExpression(relaxedQuery) {
                relaxedRows = (try? store.search(matchExpr: orExpr, filters: parsed.filters, limit: candidatePool)) ?? []
            }
        }
        let relaxedList = relaxedRows.map { $0.chunkId }

        // --- 構造化のみ(語彙なし): ファイル粒度の候補。.lexical は付けない ---
        let structuredRows = (matchExpr == nil && !parsed.filters.isEmpty)
            ? ((try? store.search(matchExpr: nil, filters: parsed.filters, limit: candidatePool)) ?? [])
            : []
        let structuredList = structuredRows.map { $0.chunkId }

        // --- 意味(cosine)。構造化フィルタを満たすファイルに限定する ---
        var semanticList: [Int64] = []
        var semanticRows: [Int64: IndexStore.LexicalRow] = [:]
        var cosByChunk: [Int64: Double] = [:]
        var bestSegByChunk: [Int64: Int32] = [:]
        if useSemantic, let semantic, semantic.isAvailable, !parsed.semanticIntent.isEmpty {
            let allowed: Set<Int64>? = parsed.filters.isEmpty
                ? nil : (try? store.fileIds(matching: parsed.filters))
            // 単独 semantic 信号(評価ベースライン)は常に segment-max。
            // hybrid の概念クエリは segment-max + 0.5·文書セントロイドの和(C16: 両ビューの合意を報いる。
            // max 結合は誤文書の単一セグメント spike に弱く C13 で失敗、和は dev R@1/MRR を改善)。
            let top: [(chunkId: Int64, score: Float, seg: Int32)] = (mode == .hybrid && conceptQuery)
                ? semantic.searchSum(parsed.semanticIntent, beta: 0.5, limit: candidatePool)
                : semantic.search(parsed.semanticIntent, limit: candidatePool)
            let ids = top.map { $0.chunkId }
            let rows = (try? store.chunkRows(ids: ids)) ?? [:]
            for (cid, sc, seg) in top {
                guard let row = rows[cid] else { continue }
                if let allowed, !allowed.contains(row.fileId) { continue }
                semanticList.append(cid)
                semanticRows[cid] = row
                cosByChunk[cid] = Double(sc)
                bestSegByChunk[cid] = seg
            }
        }

        if lexicalList.isEmpty && semanticList.isEmpty && structuredList.isEmpty { return [] }

        // チャンク行のマージ
        var rowById: [Int64: IndexStore.LexicalRow] = semanticRows
        for r in structuredRows { rowById[r.chunkId] = r }
        for r in relaxedRows { rowById[r.chunkId] = r }
        for r in lexicalRows { rowById[r.chunkId] = r }
        let strictLexSet = Set(lexicalList)
        let lexSet = strictLexSet.union(relaxedList)
        let semSet = Set(semanticList)

        // --- RRF 融合(厳密全文 / 意味 / 構造化 / 緩和全文)---
        // 緩和 OR-BM25 は C2〜C13 の失敗信号(タイトル語一致・密ビュー追加等)と異なり、
        // 密検索と誤りが相関しない独立の語彙証拠。概念クエリで dense の #1 誤りを救う。
        // (セントロイドの RRF リスト追加(C16-rrf)は sum 結合に劣ったため不採用)
        let fused = Fusion.rrf([lexicalList, semanticList, structuredList, relaxedList],
                               weights: [2.0, 1.0, 1.0, 1.0])
        let bm25ByChunk = Dictionary(lexicalRows.map { ($0.chunkId, $0.bm25) }) { a, _ in a }

        let scored: [(chunkId: Int64, hit: SearchHit)] = fused.compactMap { (chunkId, score) in
            guard let row = rowById[chunkId] else { return nil }
            var kinds: Set<MatchKind> = []
            if lexSet.contains(chunkId) { kinds.insert(.lexical) }
            if semSet.contains(chunkId) { kinds.insert(.semantic) }
            if !parsed.filters.isEmpty { kinds.insert(.structured) }
            return (chunkId, SearchHit(
                path: row.path, relPath: row.relPath, title: row.title,
                headingPath: row.headingPath, headingSlug: row.headingSlug,
                snippet: Snippet.make(from: row.text, terms: parsed.lexicalTerms),
                score: score,
                bm25: bm25ByChunk[chunkId], cosine: cosByChunk[chunkId],
                kinds: kinds))
        }
        // 決定的な順序付け: スコア降順 → 同点は cosine 降順 → さらに id 昇順(実行間で安定)。
        // (cross-encoder 再ランクは C11 で R@1 悪化 + レイテンシ超過のため不採用)
        let ordered = scored.sorted { a, b in
            if a.hit.score != b.hit.score { return a.hit.score > b.hit.score }
            let ca = a.hit.cosine ?? -1, cb = b.hit.cosine ?? -1
            if ca != cb { return ca > cb }
            return a.hit.id < b.hit.id
        }

        // 上位ヒットに最類似セグメントを付与(C18)。
        // 意味で引っかかったヒットは「まさにその文」をスニペット/着地に使う。
        // 厳密一致もあるヒットは従来の語中心スニペットを維持。
        return ordered.prefix(limit).map { (cid, hit) in
            var h = hit
            if h.kinds.contains(.semantic), let seg = bestSegByChunk[cid],
               let passage = (try? store.segmentText(chunkId: cid, seg: seg)) ?? nil {
                h.bestPassage = passage
                if !strictLexSet.contains(cid) {
                    h.snippet = Snippet.make(from: passage, terms: parsed.lexicalTerms)
                }
            }
            return h
        }
    }
}

/// 検索語の最初の出現位置を中心にしたスニペットを作る。
enum Snippet {
    static func make(from text: String, terms: [String], window: Int = 120) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        let lower = flat.lowercased()
        var hitIndex: String.Index?
        for term in terms where !term.isEmpty {
            if let r = lower.range(of: term.lowercased()) { hitIndex = r.lowerBound; break }
        }
        guard let hit = hitIndex else { return String(flat.prefix(window)) }

        let half = window / 2
        let start = flat.index(hit, offsetBy: -half, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(hit, offsetBy: half, limitedBy: flat.endIndex) ?? flat.endIndex
        var snip = String(flat[start..<end])
        if start > flat.startIndex { snip = "…" + snip }
        if end < flat.endIndex { snip += "…" }
        return snip
    }
}
