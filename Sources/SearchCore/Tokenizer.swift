import Foundation

/// CJK 対応 n-gram トークナイザ。
///
/// FTS5 の trigram トークナイザは 3 文字未満をマッチできず、「認証」「登録」のような
/// 2 文字日本語語を取りこぼす(Phase 0 スパイクで確認)。そこで CJK 連続を overlapping
/// bigram に、ラテン/数字連続を 1 語トークンに変換し、空白区切りで unicode61 FTS5 に流す。
/// これにより 2 文字日本語語も部分一致でき、bm25 ランキングも機能する。
public enum Tokenizer {

    @inline(__always)
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF,   // ひらがな・カタカナ
             0x3400...0x4DBF,   // CJK 拡張 A
             0x4E00...0x9FFF,   // CJK 統合漢字
             0xF900...0xFAFF,   // CJK 互換漢字
             0xFF66...0xFF9D:   // 半角カナ
            return true
        default:
            return false
        }
    }

    /// テキストを n-gram トークン列に変換する。
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        var cjkRun: [Character] = []

        func flushLatin() {
            if !latin.isEmpty { tokens.append(latin); latin = "" }
        }
        func flushCJK() {
            if cjkRun.isEmpty { return }
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else {
                for i in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[i]) + String(cjkRun[i + 1]))
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for ch in text {
            guard let scalar = ch.unicodeScalars.first else { continue }
            if isCJK(scalar) {
                flushLatin()
                cjkRun.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latin += ch.lowercased()
            } else {
                flushLatin(); flushCJK()
            }
        }
        flushLatin(); flushCJK()
        return tokens
    }

    /// インデックス格納用の空白区切り n-gram 文字列。
    public static func indexString(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    /// FTS5 MATCH 式。各トークンを引用符で囲んで暗黙 AND。
    /// 空クエリでは nil(呼び出し側で全文検索をスキップ)。
    public static func matchExpression(_ query: String) -> String? {
        let toks = tokens(query)
        if toks.isEmpty { return nil }
        return toks.map { "\"\(escapeForFTS($0))\"" }.joined(separator: " ")
    }

    /// 緩和一致(OR)式。長い自然文クエリでは全トークン AND がほぼ必ず空振りするため、
    /// トークンの OR + BM25 で「稀少トークン(固有名詞等)の一致」を IDF 重みで拾う。
    /// 頻出トークン(助詞のビグラム等)は IDF が低くノイズになりにくい。
    /// トークンが 1 個以下なら AND と同義なので nil。
    public static func orMatchExpression(_ query: String, maxTokens: Int = 32) -> String? {
        var seen = Set<String>()
        var toks: [String] = []
        for t in tokens(query) where !seen.contains(t) {
            seen.insert(t)
            toks.append(t)
            if toks.count >= maxTokens { break }
        }
        guard toks.count >= 2 else { return nil }
        return toks.map { "\"\(escapeForFTS($0))\"" }.joined(separator: " OR ")
    }

    /// FTS5 文字列リテラル内のダブルクォートをエスケープ。
    private static func escapeForFTS(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
