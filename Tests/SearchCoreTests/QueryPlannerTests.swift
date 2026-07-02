import XCTest
@testable import SearchCore

final class QueryPlannerTests: XCTestCase {

    // 2026-06-30 を基準に固定して相対日付を検証
    private var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 30; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: c)!
    }

    func testLastMonthRange() {
        let q = QueryPlanner.plan("先月書いた認証の下書き", now: now)
        XCTAssertNotNil(q.filters.modifiedAfter)
        XCTAssertNotNil(q.filters.modifiedBefore)
        // 5月の範囲: after=5/1, before=6/1
        let after = Date(timeIntervalSince1970: q.filters.modifiedAfter!)
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.month, from: after), 5)
        // 「先月」は除去され、意味 intent には残らない
        XCTAssertFalse(q.semanticIntent.contains("先月"))
        XCTAssertTrue(q.lexicalTerms.contains { $0.contains("認証") })
    }

    func testRelativeDays() {
        let q = QueryPlanner.plan("過去7日のメモ", now: now)
        XCTAssertNotNil(q.filters.modifiedAfter)
        let after = Date(timeIntervalSince1970: q.filters.modifiedAfter!)
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: after, to: now).day!
        XCTAssertEqual(days, 7)
        XCTAssertFalse(q.semanticIntent.contains("7日"))
    }

    func testTodoExtraction() {
        let q = QueryPlanner.plan("未完了のタスクで API 関連", now: now)
        XCTAssertEqual(q.filters.taskState, .todo)
        // タスク句は除去しない(検索の手がかりとして残す)。日付句は従来通り除去。
        XCTAssertTrue(q.lexicalTerms.contains { $0.contains("未完了") })
    }

    func testCommonWordDoesNotTriggerTaskFilter() {
        // 「やること」のような日常語ではタスクフィルタを発火させない(誤爆防止)
        let q = QueryPlanner.plan("やることリストの作り方", now: now)
        XCTAssertNil(q.filters.taskState)
    }

    func testFacetRemoval() {
        var parsed = QueryPlanner.plan("先月の未完了タスク tag:api", now: now)
        XCTAssertNotNil(parsed.filters.modifiedAfter)
        XCTAssertEqual(parsed.filters.taskState, .todo)
        XCTAssertEqual(parsed.filters.tags, ["api"])
        // タスクチップだけ解除 → 他のフィルタは維持
        parsed = QueryPlanner.removing(parsed, facets: ["タスク:未完了"])
        XCTAssertNil(parsed.filters.taskState)
        XCTAssertNotNil(parsed.filters.modifiedAfter)
        XCTAssertEqual(parsed.filters.tags, ["api"])
        // タグチップも解除
        parsed = QueryPlanner.removing(parsed, facets: ["タグ:api"])
        XCTAssertTrue(parsed.filters.tags.isEmpty)
    }

    func testUserAliasExpansion() {
        // 組み込みに無い vault 固有語もユーザー辞書で展開できる
        let exp = Aliases.expansions(for: "社内検索基盤の設計", extra: [["社内検索基盤", "SDP"]])
        XCTAssertTrue(exp.contains("SDP"))
        // 組み込み辞書も併用される
        let exp2 = Aliases.expansions(for: "サインインの流れ", extra: [["社内検索基盤", "SDP"]])
        XCTAssertTrue(exp2.contains("ログイン"))
        XCTAssertFalse(exp2.contains("SDP"))
    }

    func testExplicitDSLStillWorks() {
        let q = QueryPlanner.plan("tag:api status:draft 認証", now: now)
        XCTAssertEqual(q.filters.tags, ["api"])
        XCTAssertEqual(q.filters.status, ["draft"])
    }

    func testNaturalQueryCombinesDateAndSemantic() {
        // 「先月の認証まわりの下書き」→ 時間軸(先月)+ 意味(認証)。下書きは status とは別語なので semantic 側。
        let q = QueryPlanner.plan("先月 status:draft の認証フロー", now: now)
        XCTAssertNotNil(q.filters.modifiedAfter)
        XCTAssertEqual(q.filters.status, ["draft"])
        XCTAssertTrue(q.semanticIntent.contains("認証") || q.lexicalTerms.contains { $0.contains("認証") })
    }
}

final class InterpretationTests: XCTestCase {
    private var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 30
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    func testFacetsFromNaturalQuery() {
        let i = QueryPlanner.interpret("先月の認証まわり status:draft", now: now)
        XCTAssertTrue(i.facets.contains { $0.kind == .time })
        XCTAssertTrue(i.facets.contains { $0.kind == .structured && $0.value == "draft" })
        XCTAssertTrue(i.facets.contains { $0.kind == .lexsem })
        XCTAssertTrue(i.terms.contains { $0.contains("認証") })
        // 「先月」「status:draft」は語彙(ハイライト語)に残らない
        XCTAssertFalse(i.terms.contains { $0.contains("先月") || $0.contains("draft") })
    }
}
