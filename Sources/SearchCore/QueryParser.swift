import Foundation

/// 構造化フィルタの集合。RAG が苦手な「条件・関係・時間軸」を表す層。
public struct QueryFilters: Sendable, Equatable {
    public var tags: [String] = []
    public var status: [String] = []
    public var pathContains: [String] = []
    public var exts: [String] = []
    public var langs: [String] = []
    public var frontMatter: [FMPair] = []     // 汎用 fm.key:value
    public var modifiedAfter: Double?         // epoch 秒(>= )
    public var modifiedBefore: Double?        // epoch 秒(<  )
    public var taskState: TaskState?

    public struct FMPair: Sendable, Equatable { public var key: String; public var value: String }
    public enum TaskState: String, Sendable { case any, todo, done }

    public init() {}

    public var isEmpty: Bool {
        tags.isEmpty && status.isEmpty && pathContains.isEmpty && exts.isEmpty
            && langs.isEmpty && frontMatter.isEmpty
            && modifiedAfter == nil && modifiedBefore == nil && taskState == nil
    }
}

/// パース済みクエリ: 構造化フィルタ + 全文用語彙 + 意味検索 intent。
public struct ParsedQuery: Sendable {
    public var raw: String
    public var filters: QueryFilters
    public var lexicalTerms: [String]   // 全文(FTS)用の語/フレーズ
    public var semanticIntent: String   // 意味検索用(Phase 3 で使用)

    public var lexicalString: String { lexicalTerms.joined(separator: " ") }
}

/// `tag:api status:draft modified:>2026-06-01 path:docs "完全一致" 自由語` を分解する。
public enum QueryParser {

    public static func parse(_ raw: String, now: Date = Date()) -> ParsedQuery {
        var filters = QueryFilters()
        var lexical: [String] = []

        for token in tokenize(raw) {
            if let (key, value) = splitField(token) {
                apply(key: key, value: value, into: &filters, lexical: &lexical, now: now)
            } else {
                lexical.append(token)
            }
        }

        // 意味検索 intent: フィールド指定を除いた自然文(語彙語の連結)。
        let intent = lexical.joined(separator: " ")
        return ParsedQuery(raw: raw, filters: filters, lexicalTerms: lexical, semanticIntent: intent)
    }

    // MARK: フィールド適用

    private static func apply(key: String, value: String,
                              into filters: inout QueryFilters, lexical: inout [String], now: Date) {
        let k = key.lowercased()
        let v = value
        guard !v.isEmpty else { return }
        switch k {
        case "tag", "tags":      filters.tags.append(v)
        case "status":           filters.status.append(v)
        case "path", "in":       filters.pathContains.append(v)
        case "ext":              filters.exts.append(v.lowercased().replacingOccurrences(of: ".", with: ""))
        case "lang", "code":     filters.langs.append(v.lowercased())
        case "is":
            switch v.lowercased() {
            case "task": filters.taskState = .any
            case "todo", "open", "unchecked": filters.taskState = .todo
            case "done", "checked", "closed": filters.taskState = .done
            default: break
            }
        case "modified", "updated", "mtime", "date":
            applyDate(v, into: &filters, now: now)
        default:
            // 汎用 front matter フィルタ
            filters.frontMatter.append(.init(key: k, value: v))
        }
    }

    /// `>2026-06-01` `>=2026-06` `<2026` `2026-06`(その月)などを解釈。
    private static func applyDate(_ value: String, into filters: inout QueryFilters, now: Date) {
        var op = ""
        var rest = value
        for prefix in [">=", "<=", ">", "<"] where value.hasPrefix(prefix) {
            op = prefix; rest = String(value.dropFirst(prefix.count)); break
        }
        guard let (lower, upper) = dateRange(rest) else { return }
        switch op {
        case ">", ">=":  filters.modifiedAfter = lower
        case "<", "<=":  filters.modifiedBefore = upper
        default:
            // 範囲指定(その日/月/年)
            filters.modifiedAfter = lower
            filters.modifiedBefore = upper
        }
    }

    /// "2026-06-01" / "2026-06" / "2026" を [開始, 終了) の epoch 秒に。
    private static func dateRange(_ s: String) -> (Double, Double)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return nil }
        var comp = DateComponents()
        comp.year = year
        if parts.count >= 2 { comp.month = parts[1] }
        if parts.count >= 3 { comp.day = parts[2] }
        comp.month = comp.month ?? 1
        comp.day = comp.day ?? 1
        guard let start = cal.date(from: comp) else { return nil }
        let unit: Calendar.Component = parts.count >= 3 ? .day : (parts.count == 2 ? .month : .year)
        guard let end = cal.date(byAdding: unit, value: 1, to: start) else { return nil }
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    // MARK: トークナイズ(引用符対応)

    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" {
                inQuote.toggle()
                continue
            }
            if ch == " " && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// `key:value` を分解。スキーム付き URL(http:）等は誤検出しないよう、key が単純語のときだけ。
    private static func splitField(_ token: String) -> (String, String)? {
        if token.contains("://") { return nil }   // URL を field 誤検出しない
        guard let idx = token.firstIndex(of: ":") else { return nil }
        let key = String(token[..<idx])
        let value = String(token[token.index(after: idx)...])
        guard !key.isEmpty, !value.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (key, value)
    }
}
