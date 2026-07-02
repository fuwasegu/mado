// Phase 0 スパイク: Pure Swift で SQLite + FTS5 trigram が使えるか検証する。
// 使い方: swift scripts/sqlite-spike.swift
// 検証項目:
//   1. `import SQLite3` が SPM 外の素の swift でも解決できる(= SDK module map 経由で利用可)
//   2. FTS5 拡張がビルドされた sqlite3 か(CREATE VIRTUAL TABLE ... USING fts5 が通る)
//   3. trigram トークナイザで日本語の部分一致 + bm25() ランキングが機能する
import Foundation
import SQLite3

// SQLITE_TRANSIENT: バインドした文字列を sqlite 側にコピーさせる(Swift String の寿命対策)
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print((cond ? "  ✓ " : "  ✗ ") + label)
    if !cond { failures += 1 }
}

func sqliteVersion() -> String {
    String(cString: sqlite3_libversion())
}

print("SQLite version: \(sqliteVersion())")

var db: OpaquePointer?
guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
    print("  ✗ failed to open in-memory db"); exit(1)
}
defer { sqlite3_close(db) }

func exec(_ sql: String) -> Bool {
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &err)
    if rc != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        print("    SQL error (\(rc)): \(msg)  -- \(sql.prefix(60))")
        sqlite3_free(err)
        return false
    }
    return true
}

// --- CJK 対応 n-gram トークナイザ(Swift 側) ---
// CJK 連続は overlapping bigram に、ラテン/数字連続は小文字の語トークンにする。
// これを空白区切りで FTS5(unicode61)に流すことで、2 文字の日本語語(例: 認証)もマッチできる。
func isCJK(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3040...0x30FF,            // ひらがな・カタカナ
         0x3400...0x4DBF,            // CJK 拡張A
         0x4E00...0x9FFF,            // CJK 統合漢字
         0xF900...0xFAFF,            // CJK 互換漢字
         0xFF66...0xFF9D:            // 半角カナ
        return true
    default:
        return false
    }
}

func ngramTokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var latin = ""
    func flushLatin() {
        if !latin.isEmpty { tokens.append(latin); latin = "" }
    }
    var cjkRun: [Character] = []
    func flushCJK() {
        if cjkRun.isEmpty { return }
        if cjkRun.count == 1 {
            tokens.append(String(cjkRun[0]))
        } else {
            for i in 0..<(cjkRun.count - 1) {
                tokens.append(String(cjkRun[i]) + String(cjkRun[i + 1]))
            }
        }
        cjkRun = []
    }
    for ch in text {
        let scalar = ch.unicodeScalars.first!
        if isCJK(scalar) {
            flushLatin()
            cjkRun.append(ch)
        } else if ch.isLetter || ch.isNumber {
            flushCJK()
            latin.append(Character(ch.lowercased()))
        } else {
            flushLatin(); flushCJK()
        }
    }
    flushLatin(); flushCJK()
    return tokens
}

func ngramIndexString(_ text: String) -> String {
    ngramTokens(text).joined(separator: " ")
}

func ngramMatchExpr(_ query: String) -> String {
    // 各トークンを "..." で囲んで AND(空白区切り = FTS5 の暗黙 AND)
    ngramTokens(query).map { "\"\($0)\"" }.joined(separator: " ")
}

// --- 2. FTS5 を作る。text は事前 n-gram 済み文字列を入れる(tokenize は unicode61 既定) ---
let createOK = exec("""
CREATE VIRTUAL TABLE fts_chunks USING fts5(
    text,
    tokenize = 'unicode61 remove_diacritics 2'
);
""")
check(createOK, "FTS5 virtual table(unicode61)を作成できる")

// --- 日本語チャンクを投入 ---
let samples = [
    "認証フローは OAuth2 のauthorization code grant を使う。アクセストークンの有効期限は3600秒。",
    "ユーザ登録APIはメールアドレスとパスワードを受け取り、確認メールを送信する。",
    "OpenAPI 3.1 のスキーマ定義では webhooks がトップレベルに追加された。",
    "支払い処理は Stripe を経由し、Webhook で完了通知を受け取る設計とする。",
    "ログイン状態の保持にはリフレッシュトークンを用い、ローテーションを行う。",
]
var insertOK = true
for (i, s) in samples.enumerated() {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO fts_chunks(rowid, text) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else {
        insertOK = false; break
    }
    sqlite3_bind_int64(stmt, 1, Int64(i + 1))
    sqlite3_bind_text(stmt, 2, ngramIndexString(s), -1, SQLITE_TRANSIENT)
    if sqlite3_step(stmt) != SQLITE_DONE { insertOK = false }
    sqlite3_finalize(stmt)
    if !insertOK { break }
}
check(insertOK, "日本語テキストを INSERT できる")

// --- 3. 部分一致クエリ + bm25 ランキング ---
func query(_ word: String) -> [(rowid: Int64, score: Double, text: String)] {
    var stmt: OpaquePointer?
    let sql = "SELECT rowid, bm25(fts_chunks) FROM fts_chunks WHERE fts_chunks MATCH ? ORDER BY bm25(fts_chunks) LIMIT 10;"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("    prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        return []
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, ngramMatchExpr(word), -1, SQLITE_TRANSIENT)
    var rows: [(Int64, Double, String)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let rowid = sqlite3_column_int64(stmt, 0)
        let score = sqlite3_column_double(stmt, 1)
        rows.append((rowid, score, String(samples[Int(rowid) - 1])))
    }
    return rows
}

// n-gram 方式なら 2 文字の日本語語でもマッチするはず。
let q1 = query("認証")
check(!q1.isEmpty && q1.contains { $0.rowid == 1 }, "「認証」(2文字)で rowid=1 がヒット")

let q2 = query("トークン")
let hitRows = Set(q2.map { $0.rowid })
check(hitRows.contains(1) && hitRows.contains(5), "「トークン」で複数文書(1,5)がヒット")

let q3 = query("webhook")
check(q3.contains { $0.rowid == 4 }, "「webhook」で英字部分一致がヒット(大小無視)")

let q4 = query("登録")
check(q4.contains { $0.rowid == 2 } && !q4.contains { $0.rowid == 1 }, "「登録」(2文字)は rowid=2 のみ(誤ヒットなし)")

print("--- bm25 ranking for 「トークン」 ---")
for r in q2 { print("  rowid=\(r.rowid) score=\(String(format: "%.3f", r.score))  \(r.text.prefix(28))…") }

print(failures == 0 ? "\nPHASE0 SPIKE: PASS ✅" : "\nPHASE0 SPIKE: \(failures) FAILURE(S) ❌")
exit(failures == 0 ? 0 : 1)
