import Foundation

/// クエリの「解釈」を UI に見せるためのチップ 1 つ。
/// 検索窓に打った語そのものではなく、それがどう分解されたか(時間軸 / 条件 / 全文+意味)。
public struct QueryFacet: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case time, structured, lexsem }
    public var id: String { "\(kindLabel):\(value)" }
    public var kind: Kind
    public var kindLabel: String   // 時間軸 / タグ / 状態 / 全文+意味 …
    public var value: String
    public init(kind: Kind, kindLabel: String, value: String) {
        self.kind = kind; self.kindLabel = kindLabel; self.value = value
    }
}

public struct SearchInterpretation: Sendable {
    public var facets: [QueryFacet]
    public var terms: [String]      // 全文/意味でハイライトすべき語
    public init(facets: [QueryFacet], terms: [String]) { self.facets = facets; self.terms = terms }
}

public extension QueryPlanner {
    /// 検索パネルの「解釈」チップとハイライト語を生成する。
    static func interpret(_ raw: String, now: Date = Date()) -> SearchInterpretation {
        let p = plan(raw, now: now)
        var f: [QueryFacet] = []
        if let after = p.filters.modifiedAfter {
            f.append(.init(kind: .time, kindLabel: "時間軸",
                           value: dateRangeLabel(after, p.filters.modifiedBefore)))
        }
        for t in p.filters.tags    { f.append(.init(kind: .structured, kindLabel: "タグ", value: t)) }
        for s in p.filters.status  { f.append(.init(kind: .structured, kindLabel: "状態", value: s)) }
        for pc in p.filters.pathContains { f.append(.init(kind: .structured, kindLabel: "パス", value: pc)) }
        for e in p.filters.exts    { f.append(.init(kind: .structured, kindLabel: "拡張子", value: e)) }
        for l in p.filters.langs   { f.append(.init(kind: .structured, kindLabel: "言語", value: l)) }
        if let ts = p.filters.taskState {
            f.append(.init(kind: .structured, kindLabel: "タスク", value: ts == .done ? "完了" : "未完了"))
        }
        for fm in p.filters.frontMatter { f.append(.init(kind: .structured, kindLabel: fm.key, value: fm.value)) }
        if !p.lexicalTerms.isEmpty {
            f.append(.init(kind: .lexsem, kindLabel: "全文+意味", value: p.lexicalTerms.joined(separator: " ")))
        }
        return SearchInterpretation(facets: f, terms: p.lexicalTerms)
    }

    /// 解釈チップの個別解除: 指定 facet id に対応するフィルタだけを外した ParsedQuery を返す。
    /// プランナの誤解釈(タスク句の誤爆等)を、語彙の網羅ではなく UI 操作で回収するための API。
    static func removing(_ parsed: ParsedQuery, facets ids: Set<String>) -> ParsedQuery {
        guard !ids.isEmpty else { return parsed }
        var p = parsed
        func off(_ label: String, _ value: String) -> Bool { ids.contains("\(label):\(value)") }
        if let after = p.filters.modifiedAfter,
           off("時間軸", dateRangeLabel(after, p.filters.modifiedBefore)) {
            p.filters.modifiedAfter = nil
            p.filters.modifiedBefore = nil
        }
        p.filters.tags.removeAll { off("タグ", $0) }
        p.filters.status.removeAll { off("状態", $0) }
        p.filters.pathContains.removeAll { off("パス", $0) }
        p.filters.exts.removeAll { off("拡張子", $0) }
        p.filters.langs.removeAll { off("言語", $0) }
        if let ts = p.filters.taskState, off("タスク", ts == .done ? "完了" : "未完了") {
            p.filters.taskState = nil
        }
        p.filters.frontMatter.removeAll { off($0.key, $0.value) }
        return p
    }

    private static func dateRangeLabel(_ after: Double, _ before: Double?) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian); fmt.timeZone = .current
        let a = Date(timeIntervalSince1970: after)
        guard let before else { fmt.dateFormat = "yyyy-MM-dd"; return "\(fmt.string(from: a)) 以降" }
        let b = Date(timeIntervalSince1970: before)
        let span = before - after
        if span <= 32 * 86400 {            // ほぼ 1 か月以内 → 月表記
            fmt.dateFormat = "yyyy-MM"; return fmt.string(from: a)
        }
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: a))–\(fmt.string(from: b))"
    }
}
