import Foundation

/// 自然文クエリを構造化フィルタ + 語彙 + 意味 intent に分解する規則ベースプランナ。
///
/// 設計上の制約: on-device LLM(Foundation Models)は macOS 26 必須のため、最小 OS を
/// 上げない方針で規則/ヒューリスティックに留める。高品質な自然文理解は MCP 経由で
/// クライアント側 LLM(Claude)に委譲する(Phase 5)。
/// ここで扱うのは「時間軸」「タスク状態」など普遍的に構造化できる要素のみ。
public enum QueryPlanner {

    public static func plan(_ raw: String, now: Date = Date()) -> ParsedQuery {
        var text = raw
        var after: Double?
        var before: Double?
        var taskState: QueryFilters.TaskState?

        // 1) 相対日付フレーズ(日本語 / 英語)を抽出して除去
        for rule in dateRules {
            if let m = rule.match(in: text, now: now) {
                if after == nil { after = m.after }
                if before == nil { before = m.before }
                text = text.replacingCharacters(in: m.range, with: " ")
            }
        }
        // 「過去N日」「N日以内」「N日前」「last N days」
        if let m = relativeDays(in: text, now: now) {
            if after == nil { after = m.after }
            text = text.replacingCharacters(in: m.range, with: " ")
        }

        // 2) タスク状態の語。
        // 日付と違い、語をクエリから除去しない: タスク句は本文にも現れうる語なので、
        // 除去すると検索の手がかりまで失う(フィルタは付けるが語は lexical/semantic に残す)。
        // 誤解釈は検索パネルの解釈チップをタップして個別に外せる。
        for (phrases, state) in taskPhrases {
            if phrases.contains(where: { text.range(of: $0) != nil }) {
                taskState = state
                break
            }
        }

        // 3) 残りを既存 DSL パーサへ(明示 tag:/status: 等もここで処理)
        var parsed = QueryParser.parse(text, now: now)
        if let after { parsed.filters.modifiedAfter = parsed.filters.modifiedAfter ?? after }
        if let before { parsed.filters.modifiedBefore = parsed.filters.modifiedBefore ?? before }
        if let taskState, parsed.filters.taskState == nil { parsed.filters.taskState = taskState }

        // semantic intent は元の自然文(フィルタ語を除いた残余)を使う
        parsed = ParsedQuery(raw: raw, filters: parsed.filters,
                             lexicalTerms: parsed.lexicalTerms,
                             semanticIntent: parsed.lexicalTerms.joined(separator: " "))
        return parsed
    }

    // MARK: 名前付き期間

    private struct DateRule {
        let phrases: [String]
        let range: (Date) -> (after: Double?, before: Double?)
        func match(in text: String, now: Date) -> (range: Range<String.Index>, after: Double?, before: Double?)? {
            for p in phrases {
                if let r = text.range(of: p) {
                    let (a, b) = range(now)
                    return (r, a, b)
                }
            }
            return nil
        }
    }

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }

    private static let dateRules: [DateRule] = [
        DateRule(phrases: ["今日", "本日", "today"]) { now in
            let s = cal.startOfDay(for: now)
            return (s.timeIntervalSince1970, nil)
        },
        DateRule(phrases: ["昨日", "yesterday"]) { now in
            let today = cal.startOfDay(for: now)
            let y = cal.date(byAdding: .day, value: -1, to: today)!
            return (y.timeIntervalSince1970, today.timeIntervalSince1970)
        },
        DateRule(phrases: ["今週", "this week"]) { now in
            let s = cal.dateInterval(of: .weekOfYear, for: now)!.start
            return (s.timeIntervalSince1970, nil)
        },
        DateRule(phrases: ["先週", "last week", "先週分"]) { now in
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
            let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!
            return (lastWeek.timeIntervalSince1970, thisWeek.timeIntervalSince1970)
        },
        DateRule(phrases: ["今月", "this month"]) { now in
            let s = cal.dateInterval(of: .month, for: now)!.start
            return (s.timeIntervalSince1970, nil)
        },
        DateRule(phrases: ["先月", "last month"]) { now in
            let thisMonth = cal.dateInterval(of: .month, for: now)!.start
            let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth)!
            return (lastMonth.timeIntervalSince1970, thisMonth.timeIntervalSince1970)
        },
        DateRule(phrases: ["今年", "this year"]) { now in
            let s = cal.dateInterval(of: .year, for: now)!.start
            return (s.timeIntervalSince1970, nil)
        },
        DateRule(phrases: ["去年", "昨年", "last year"]) { now in
            let thisYear = cal.dateInterval(of: .year, for: now)!.start
            let lastYear = cal.date(byAdding: .year, value: -1, to: thisYear)!
            return (lastYear.timeIntervalSince1970, thisYear.timeIntervalSince1970)
        },
        DateRule(phrases: ["最近", "recently", "このごろ"]) { now in
            let s = cal.date(byAdding: .day, value: -7, to: now)!
            return (s.timeIntervalSince1970, nil)
        },
    ]

    // MARK: 「N日」系

    private static let daysRegex = try! NSRegularExpression(
        pattern: #"(?:過去|直近)?\s*(\d+)\s*(?:日(?:以内|間|前)?)|last\s+(\d+)\s+days?"#,
        options: [.caseInsensitive])

    private static func relativeDays(in text: String, now: Date)
        -> (range: Range<String.Index>, after: Double?)? {
        let ns = text as NSString
        guard let m = daysRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var n: Int?
        for gi in 1...2 where m.range(at: gi).location != NSNotFound {
            n = Int(ns.substring(with: m.range(at: gi)))
        }
        guard let days = n, let r = Range(m.range, in: text) else { return nil }
        let after = cal.date(byAdding: .day, value: -days, to: now)!.timeIntervalSince1970
        return (r, after)
    }

    // 明示的な語だけに絞る(「やること」のような日常語は誤爆コストが高いため外した)。
    private static let taskPhrases: [(phrases: [String], state: QueryFilters.TaskState)] = [
        (["未完了", "未対応", "やり残し", "todo", "to-do"], .todo),
        (["完了済", "対応済", "済みのタスク", "done のタスク"], .done),
    ]
}
