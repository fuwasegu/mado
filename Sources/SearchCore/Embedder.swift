import Foundation

/// 埋め込む対象の種別。e5 系は "query:" / "passage:" の接頭辞で精度が変わる。
public enum EmbedKind: Sendable { case query, document }

/// 文/チャンクを密ベクトルに変換するエンジン。実装は差し替え可能(zero-dep の NLContextual /
/// 高品質な CoreML e5 など)。意味検索は融合(RRF)の 1 信号として使う。
public protocol Embedder: AnyObject {
    /// モデル識別子。変わったら索引のベクトルを作り直す判断に使う。
    var identifier: String { get }
    var dimension: Int { get }
    var isAvailable: Bool { get }
    /// 失敗時は nil(意味検索のみ無効化し、全文・構造化は継続)。
    func embed(_ text: String, kind: EmbedKind) -> [Float]?
}

public extension Embedder {
    func embed(_ text: String) -> [Float]? { embed(text, kind: .document) }
}

public enum VectorMath {
    /// L2 正規化済みベクトル同士の内積 = cosine。事前正規化しておくと検索が内積だけで済む。
    @inline(__always)
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        var i = 0
        while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm < 1e-9 { return v }
        return v.map { $0 / norm }
    }
}
