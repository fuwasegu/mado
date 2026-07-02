import Foundation
import NaturalLanguage

/// Apple NaturalLanguage の NLContextualEmbedding を使う zero-dependency 埋め込み(macOS 14+)。
/// モデル同梱不要・オフライン動作。トークンベクトルの平均を文ベクトルとし、L2 正規化して返す。
/// 単独の意味精度は弱いため(スパイクで確認)、必ず融合の 1 信号として用いる。
public final class NLEmbedder: Embedder {
    private let language: NLLanguage
    private var embedding: NLContextualEmbedding?
    private var loaded = false
    private var loadFailed = false

    public init(language: NLLanguage = .japanese) {
        self.language = language
        self.embedding = NLContextualEmbedding(language: language)
    }

    public var identifier: String { "nl-contextual-\(dimension)" }
    public var dimension: Int { embedding?.dimension ?? 0 }

    public var isAvailable: Bool {
        ensureLoaded()
        return loaded
    }

    private func ensureLoaded() {
        guard !loaded, !loadFailed, let embedding else { return }
        do {
            try embedding.load()
            loaded = true
        } catch {
            loadFailed = true
        }
    }

    public func embed(_ text: String, kind: EmbedKind) -> [Float]? {
        ensureLoaded()
        guard loaded, let embedding else { return nil }
        let trimmed = text.count > 2000 ? String(text.prefix(2000)) : text
        guard let result = try? embedding.embeddingResult(for: trimmed, language: language) else { return nil }
        var sum: [Float] = []
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
            for i in 0..<min(sum.count, vector.count) { sum[i] += Float(vector[i]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        for i in sum.indices { sum[i] /= Float(count) }
        return VectorMath.normalized(sum)
    }
}
