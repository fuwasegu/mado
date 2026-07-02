import Foundation
import CoreML
import Tokenizers
import Hub

/// multilingual-e5-small(CoreML, int8)による高品質な多言語文埋め込み。
/// mean-pooling + L2 正規化はモデルに焼き込み済み。tokenize → predict で 384 次元を得る。
/// e5 の作法に従い query は "query: "、文書は "passage: " を前置する。
public final class CoreMLEmbedder: Embedder {
    // ベンチ用オーバーライド(製品では未設定): MADO_E5_MODEL=<mlpackage path> / MADO_E5_COMPUTE=all|cpu / MADO_E5_ID=<suffix>
    private static let env = ProcessInfo.processInfo.environment

    public var identifier: String { "e5-small-int8-384-seq256-ctx1" + (Self.env["MADO_E5_ID"] ?? "") }
    public let dimension = 384
    private let seqLen = 256
    private let padTokenID: Int32 = 1   // XLM-R の <pad>

    private var model: MLModel?
    private var tokenizer: (any Tokenizers.Tokenizer)?
    private var loaded = false
    private var loadFailed = false

    public init() {}

    public var isAvailable: Bool { ensureLoaded(); return loaded }

    private func ensureLoaded() {
        guard !loaded, !loadFailed else { return }
        do {
            guard let bundled = Bundle.module.url(forResource: "MultilingualE5Small-int8",
                                                  withExtension: "mlpackage", subdirectory: "Resources"),
                  let tokURL = Bundle.module.url(forResource: "tokenizer", withExtension: "json",
                                                 subdirectory: "Resources/e5-tokenizer"),
                  let cfgURL = Bundle.module.url(forResource: "tokenizer_config", withExtension: "json",
                                                 subdirectory: "Resources/e5-tokenizer")
            else { throw Err.missingResource }
            let mlURL = Self.env["MADO_E5_MODEL"].map { URL(fileURLWithPath: $0) } ?? bundled

            let compiled = try compiledModelURL(for: mlURL)
            let mc = MLModelConfiguration()
            // GPU(MPSGraph)は int8 mlprogram で "MLIR pass manager failed" になり得るため
            // CPU + Neural Engine に限定(埋め込みは背景処理なので速度より堅牢性を優先)。
            switch Self.env["MADO_E5_COMPUTE"] {
            case "all": mc.computeUnits = .all
            case "cpu": mc.computeUnits = .cpuOnly
            default: mc.computeUnits = .cpuAndNeuralEngine
            }
            model = try MLModel(contentsOf: compiled, configuration: mc)

            let tokConfig = try JSONDecoder().decode(Config.self, from: Data(contentsOf: cfgURL))
            let tokData = try JSONDecoder().decode(Config.self, from: Data(contentsOf: tokURL))
            tokenizer = try AutoTokenizer.from(tokenizerConfig: tokConfig, tokenizerData: tokData)

            loaded = true
        } catch {
            loadFailed = true
            NSLog("[CoreMLEmbedder] load failed: \(error)")
        }
    }

    /// .mlpackage をコンパイルし、Application Support にキャッシュして再利用する。
    private func compiledModelURL(for mlpackage: URL) throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Mado/models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cached = dir.appendingPathComponent(mlpackage.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if fm.fileExists(atPath: cached.path) { return cached }
        let compiled = try MLModel.compileModel(at: mlpackage)
        if fm.fileExists(atPath: cached.path) { try? fm.removeItem(at: cached) }
        try fm.copyItem(at: compiled, to: cached)
        return cached
    }

    public func embed(_ text: String, kind: EmbedKind) -> [Float]? {
        ensureLoaded()
        guard loaded, let model, let tokenizer else { return nil }
        let prefixed = (kind == .query ? "query: " : "passage: ") + text
        var ids = tokenizer.encode(text: prefixed)         // 特殊トークン込み(<s> … </s>)
        if ids.count > seqLen {
            ids = Array(ids.prefix(seqLen - 1)) + [ids.last ?? 2]   // 末尾 </s> を残して切り詰め
        }
        let n = ids.count
        guard let inputIds = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        else { return nil }
        for i in 0..<seqLen {
            inputIds[i] = NSNumber(value: i < n ? Int32(ids[i]) : padTokenID)
            mask[i] = NSNumber(value: i < n ? 1 : 0)
        }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["input_ids": inputIds, "attention_mask": mask]),
              let out = try? model.prediction(from: provider),
              let emb = out.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }

        // 出力 dtype(fp16/fp32)に依存しない安全な読み出し
        var vec = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { vec[i] = emb[i].floatValue }
        return vec   // モデル内で正規化済み
    }

    private enum Err: Error { case missingResource }
}
