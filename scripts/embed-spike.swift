// Phase 3 スパイク: Apple NLContextualEmbedding の日本語意味検索品質を実測する。
// 使い方: swift scripts/embed-spike.swift
//  - アセットが利用可能か(�ザロ同梱で動くか)
//  - 次元 / 1 文あたりのエンコード時間
//  - 「言い換え/同義」の類似度が「無関係」より高くランクされるか
import Foundation
import NaturalLanguage

func mean(_ vectors: [[Double]]) -> [Double] {
    guard let first = vectors.first else { return [] }
    var acc = [Double](repeating: 0, count: first.count)
    for v in vectors { for i in v.indices { acc[i] += v[i] } }
    return acc.map { $0 / Double(vectors.count) }
}
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return dot / ((na.squareRoot() * nb.squareRoot()) + 1e-9)
}

guard let emb = NLContextualEmbedding(language: .japanese) else {
    print("✗ NLContextualEmbedding(.japanese) を生成できない"); exit(1)
}
print("dimension: \(emb.dimension), revision: \(emb.revision)")
print("hasAvailableAssets(before load): \(emb.hasAvailableAssets)")

if !emb.hasAvailableAssets {
    print("… アセット未取得。requestAssets を試行(初回のみ DL が要る場合あり)")
    let sem = DispatchSemaphore(value: 0)
    emb.requestAssets { result, error in
        print("requestAssets: \(result.rawValue) error=\(String(describing: error))")
        sem.signal()
    }
    sem.wait()
}

do { try emb.load() } catch { print("✗ load 失敗: \(error)"); exit(1) }
print("✓ load 成功")

func vector(_ text: String) -> [Double]? {
    guard let result = try? emb.embeddingResult(for: text, language: .japanese) else { return nil }
    var toks: [[Double]] = []
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
        toks.append(vec); return true
    }
    return toks.isEmpty ? nil : mean(toks)
}

// 意味的検索の妥当性: クエリに対し「言い換え」が「無関係」より近いか
let query = "ユーザーのログイン認証はどう実装する?"
let paraphrase = "サインインの仕組みとアクセストークンの発行手順"   // 言い換え(語の重なり少)
let unrelated = "CSV ファイルのテーブル表示と行番号の付け方"        // 無関係

let t0 = Date()
guard let qv = vector(query), let pv = vector(paraphrase), let uv = vector(unrelated) else {
    print("✗ ベクトル化に失敗"); exit(1)
}
let ms = Date().timeIntervalSince(t0) * 1000 / 3
let simPara = cosine(qv, pv)
let simUnrel = cosine(qv, uv)
print(String(format: "encode ~%.1fms/文", ms))
print(String(format: "cos(query, 言い換え) = %.3f", simPara))
print(String(format: "cos(query, 無関係)   = %.3f", simUnrel))

let pass = simPara > simUnrel
print(pass ? "\n✅ 言い換え > 無関係 (意味検索として機能)" : "\n❌ 意味ランキングが不正")
exit(pass ? 0 : 1)
