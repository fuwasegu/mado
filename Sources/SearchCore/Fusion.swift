import Foundation

/// 複数のランク付き結果リストを Reciprocal Rank Fusion で統合する。
/// score(item) = Σ 1 / (k + rank)。rank は各リスト内 0-origin。
/// 全文(BM25)・意味(cosine)・構造化など、スケールの異なる信号を順位だけで公平に混ぜられる。
public enum Fusion {
    public static func rrf(_ lists: [[Int64]], weights: [Double]? = nil, k: Double = 60) -> [Int64: Double] {
        var scores: [Int64: Double] = [:]
        for (i, list) in lists.enumerated() {
            let w = weights?[i] ?? 1.0
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += w / (k + Double(rank))
            }
        }
        return scores
    }
}
