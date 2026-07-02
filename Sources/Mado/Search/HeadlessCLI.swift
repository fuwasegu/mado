import Foundation
import SearchCore

/// GUI を起動しないヘッドレス操作。インデックスの事前構築や検証、自動化に使う。
/// GUI が使う SearchIndex actor をそのまま呼ぶため、配線(actor 経路)の検証も兼ねる。
enum HeadlessCLI {

    static func index(path: String) {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else {
            FileHandle.standardError.write(Data("path not found: \(root.path)\n".utf8)); exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        let idx = SearchIndex()
        let t0 = Date()
        Task {
            await idx.openAndReconcile(root: root)
            _ = await idx.embedAllBlocking()   // CLI は埋め込み完了まで待つ
            let s = await idx.indexStats()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("indexed \(s.files) files, \(s.chunks) chunks in \(ms)ms")
            print("db: \(SearchIndex.indexURL(for: root).path)")
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    // MARK: 検索精度評価(--eval <corpus> <queries.json>)

    private struct EvalQuery: Decodable { let query: String; let gold: String; let type: String }

    static func eval(corpus: String, queriesPath: String) {
        let root = URL(fileURLWithPath: (corpus as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard let qdata = try? Data(contentsOf: URL(fileURLWithPath: queriesPath)),
              let queries = try? JSONDecoder().decode([EvalQuery].self, from: qdata) else {
            FileHandle.standardError.write(Data("cannot read queries: \(queriesPath)\n".utf8)); exit(2)
        }
        // 評価インデックスは永続キャッシュ(corpus パス + embedder + schema がキー)。
        // reconcile は content_hash で未変更 skip、埋め込みも既存分 skip → 2回目以降は ~1s。
        let embedder: Embedder = { let e = CoreMLEmbedder(); return e.isAvailable ? e : NLEmbedder(language: .japanese) }()
        let cacheKey = Indexer.contentHash(Data("\(root.path)|\(embedder.identifier)|v\(IndexStore.schemaVersion)".utf8))
        let dbPath = NSTemporaryDirectory() + "mado-eval-cache-\(cacheKey).sqlite"
        guard let store = try? IndexStore(path: dbPath) else { exit(1) }
        if (try? store.embedModelID()) != embedder.identifier {
            try? store.clearAllVectors()
            try? store.setEmbedModelID(embedder.identifier)
        }

        let stats = (try? Indexer.reconcile(root: root, store: store, nowEpoch: Date().timeIntervalSince1970))
        let sem = SemanticStore(store: store, embedder: embedder)
        let t0 = Date()
        while ((try? sem.embedNextBatch(limit: 64)) ?? 0) > 0 {}
        let embedMs = Int(Date().timeIntervalSince(t0) * 1000)
        let svc = QueryService(store: store, semantic: sem,
                               userAliases: Aliases.loadUserGroups(vaultRoot: root))

        print("corpus=\(root.lastPathComponent) files=\(stats?.added ?? 0) chunks=\((try? store.chunkCount()) ?? 0) vectors=\((try? store.vectorCount()) ?? 0)")
        print("embedder=\(embedder.identifier) embedTime=\(embedMs)ms queries=\(queries.count)\n")

        func articleRank(_ hits: [SearchHit], gold: String) -> Int? {
            var seen = Set<String>(); var rank = 0
            for h in hits {
                if seen.contains(h.relPath) { continue }
                seen.insert(h.relPath); rank += 1
                if h.relPath == gold { return rank }
            }
            return nil
        }

        struct Acc { var r1 = 0.0, r5 = 0.0, r10 = 0.0, mrr = 0.0, n = 0
            mutating func add(_ rank: Int?) {
                n += 1
                guard let r = rank else { return }
                if r <= 1 { r1 += 1 }; if r <= 5 { r5 += 1 }; if r <= 10 { r10 += 1 }
                mrr += 1.0 / Double(r)
            }
        }
        let modes: [(String, QueryService.Mode)] = [
            ("lexical", QueryService.Mode.lexical),
            ("semantic", QueryService.Mode.semantic),
            ("hybrid", QueryService.Mode.hybrid),
        ]
        var byModeType: [String: [String: Acc]] = [:]   // mode -> type -> acc
        var byModeAll: [String: Acc] = [:]
        var latencies: [Double] = []

        for q in queries {
            for (mname, mode) in modes {
                let start = Date()
                let hits = svc.search(q.query, limit: 50, mode: mode)
                if mode == .hybrid { latencies.append(Date().timeIntervalSince(start) * 1000) }
                let rank = articleRank(hits, gold: q.gold)
                byModeType[mname, default: [:]][q.type, default: Acc()].add(rank)
                byModeAll[mname, default: Acc()].add(rank)
            }
        }

        let types = Array(Set(queries.map { $0.type })).sorted()
        func fmt(_ a: Acc) -> String {
            guard a.n > 0 else { return "   -" }
            return String(format: "R@1=%.2f R@5=%.2f R@10=%.2f MRR=%.3f (n=%d)",
                          a.r1/Double(a.n), a.r5/Double(a.n), a.r10/Double(a.n), a.mrr/Double(a.n), a.n)
        }
        for (mname, _) in modes {
            print("== \(mname) ==")
            for t in types { if let a = byModeType[mname]?[t] { print(String(format: "  %-10@ %@", t as NSString, fmt(a))) } }
            if let all = byModeAll[mname] { print("  \("ALL".padding(toLength: 10, withPad: " ", startingAt: 0)) \(fmt(all))") }
            print("")
        }
        let sorted = latencies.sorted()
        if !sorted.isEmpty {
            let p = { (q: Double) in sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
            print(String(format: "hybrid latency: p50=%.1fms p95=%.1fms max=%.1fms",
                         p(0.5), p(0.95), sorted.last ?? 0))
        }
        exit(0)
    }

    // MARK: 自動エイリアス採掘(--mine-aliases <corpus> <out.json> [threshold])
    // vault 語彙(ラテン語・カタカナ語)を e5 で埋め込み、近傍語を自動グループ化する実験。
    // 出力は .mado/aliases.json と同形式で、userAliases 経路にそのまま流せる。

    static func mineAliases(corpus: String, output: String, threshold: Float) {
        let root = URL(fileURLWithPath: (corpus as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let embedder = CoreMLEmbedder()
        guard embedder.isAvailable else {
            FileHandle.standardError.write(Data("e5 unavailable\n".utf8)); exit(1)
        }

        // 1) 語彙抽出(DF 付き)。カタカナ連続 3+ / ラテン 3+。
        var df: [String: Int] = [:]
        let kata = try! NSRegularExpression(pattern: "[\\p{Script=Katakana}ー]{3,}")
        let latin = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9.+-]{2,}")
        var fileCount = 0
        for url in Indexer.enumerateIndexable(root: root) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            fileCount += 1
            var seen = Set<String>()
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            for rx in [kata, latin] {
                for m in rx.matches(in: text, range: range) {
                    seen.insert(ns.substring(with: m.range).lowercased())
                }
            }
            for t in seen { df[t, default: 0] += 1 }
        }
        // 選別: 2 ≤ DF ≤ 40% of docs(識別語だが孤語ではない)、頻度順で上位 400
        let maxDF = max(2, Int(Double(fileCount) * 0.4))
        let terms = df.filter { $0.value >= 2 && $0.value <= maxDF }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(400).map { $0.key }
        print("vocab: \(df.count) terms → selected \(terms.count) (files=\(fileCount))")

        // 2) 埋め込み(文テンプレートで e5 に自然な入力を与える)
        var vecs: [[Float]] = []
        for t in terms { vecs.append(embedder.embed("「\(t)」について", kind: .document) ?? []) }

        // 3) 異方性補正(全語平均を引いて再正規化)。e5 の語レベル cosine は素では全て 0.9 前後に
        //    张り付き識別不能。中心化で類似度が広がり、同義ペアだけが高く残る。
        let dim = vecs.first(where: { !$0.isEmpty })?.count ?? 0
        var mean = [Float](repeating: 0, count: dim)
        var cnt = 0
        for v in vecs where !v.isEmpty { for k in 0..<dim { mean[k] += v[k] }; cnt += 1 }
        for k in 0..<dim { mean[k] /= Float(max(1, cnt)) }
        let centered: [[Float]] = vecs.map { v in
            guard !v.isEmpty else { return v }
            var c = v
            for k in 0..<dim { c[k] -= mean[k] }
            return VectorMath.normalized(c)
        }

        // 4) 相互最近傍ペアのみ採用(推移閉包の連鎖崩壊を構造的に防ぐ)。
        var best: [(idx: Int, sim: Float)] = Array(repeating: (-1, -2), count: terms.count)
        for i in 0..<terms.count where !centered[i].isEmpty {
            for j in 0..<terms.count where j != i && !centered[j].isEmpty {
                if terms[i].contains(terms[j]) || terms[j].contains(terms[i]) { continue }
                let s = VectorMath.dot(centered[i], centered[j])
                if s > best[i].sim { best[i] = (j, s) }
            }
        }
        var aliasGroups: [[String]] = []
        var scored: [(Float, String, String)] = []
        for i in 0..<terms.count {
            let (j, s) = best[i]
            guard j > i, best[j].idx == i, s >= threshold else { continue }   // 相互 top-1 のみ
            aliasGroups.append([terms[i], terms[j]])
            scored.append((s, terms[i], terms[j]))
        }
        aliasGroups.sort { $0[0] < $1[0] }

        print("mutual-NN pairs ≥ \(threshold): \(aliasGroups.count)")
        for (s, a, b) in scored.sorted(by: { $0.0 > $1.0 }).prefix(30) {
            print(String(format: "  %.3f  %@ ⇄ %@", s, a, b))
        }
        let data = try! JSONEncoder().encode(aliasGroups)
        try! data.write(to: URL(fileURLWithPath: output))
        print("wrote \(output)")
        exit(0)
    }

    // MARK: 構造化フィルタ検証(--eval-structured <corpus> <structured.json>)

    private struct StructuredQuery: Decodable { let query: String; let gold_set: [String] }

    static func evalStructured(corpus: String, queriesPath: String) {
        let root = URL(fileURLWithPath: (corpus as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard let qdata = try? Data(contentsOf: URL(fileURLWithPath: queriesPath)),
              let queries = try? JSONDecoder().decode([StructuredQuery].self, from: qdata) else {
            FileHandle.standardError.write(Data("cannot read: \(queriesPath)\n".utf8)); exit(2)
        }
        let dbPath = NSTemporaryDirectory() + "mado-evals-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        guard let store = try? IndexStore(path: dbPath) else { exit(1) }
        _ = try? Indexer.reconcile(root: root, store: store, nowEpoch: Date().timeIntervalSince1970)
        let svc = QueryService(store: store)   // 構造化のみなので埋め込み不要

        var allPass = true
        var pSum = 0.0, rSum = 0.0
        for q in queries {
            let hits = svc.search(q.query, limit: 500)
            let returned = Set(hits.map { $0.relPath })
            let gold = Set(q.gold_set)
            let inter = returned.intersection(gold)
            let precision = returned.isEmpty ? (gold.isEmpty ? 1 : 0) : Double(inter.count) / Double(returned.count)
            let recall = gold.isEmpty ? 1 : Double(inter.count) / Double(gold.count)
            pSum += precision; rSum += recall
            let ok = precision == 1.0 && recall == 1.0
            if !ok { allPass = false }
            print(String(format: "  %@ %-16@ P=%.2f R=%.2f (got %d, gold %d)",
                         ok ? "✓" : "✗", q.query as NSString, precision, recall, returned.count, gold.count))
        }
        let n = Double(queries.count)
        print(String(format: "\nstructured: precision=%.3f recall=%.3f  %@",
                     pSum / n, rSum / n, allPass ? "ALL PASS ✅" : "FAIL ❌"))
        exit(allPass ? 0 : 1)
    }

    static func search(path: String, query: String) {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let sem = DispatchSemaphore(value: 0)
        let idx = SearchIndex()
        Task {
            await idx.openAndReconcile(root: root)
            _ = await idx.embedAllBlocking()   // CLI は埋め込み完了まで待つ
            let hits = await idx.search(query, limit: 20)
            print("query: \(query) -> \(hits.count) hits")
            let maxScore = hits.map(\.score).max() ?? 1
            for h in hits.prefix(10) {
                let kinds = h.kinds.map { $0.rawValue }.sorted().joined(separator: ",")
                let rel = maxScore > 0 ? Int((h.score / maxScore * 100).rounded()) : 0
                let cos = h.cosine.map { String(format: " cos %.2f", $0) } ?? ""
                let bm = h.bm25.map { String(format: " bm25 %.1f", $0) } ?? ""
                print(String(format: "  [rel %3d] fused %.4f%@%@ [%@]  %@#%@",
                             rel, h.score, cos, bm, kinds, h.relPath, h.headingSlug))
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
