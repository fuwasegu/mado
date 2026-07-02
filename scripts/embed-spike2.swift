// Phase 3 スパイク②: NLContextualEmbedding を「平均中心化(whitening 簡易版)」で改善し、
// 小規模 JP コーパスでの top-1 検索精度を、中心化あり/なしで比較する。
import Foundation
import NaturalLanguage

func mean(_ vs: [[Double]]) -> [Double] {
    guard let f = vs.first else { return [] }
    var a = [Double](repeating: 0, count: f.count)
    for v in vs { for i in v.indices { a[i] += v[i] } }
    return a.map { $0 / Double(vs.count) }
}
func sub(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map(-) }
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for i in a.indices { d += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
    return d / ((na.squareRoot()*nb.squareRoot()) + 1e-9)
}

let emb = NLContextualEmbedding(language: .japanese)!
try! emb.load()
func vec(_ t: String) -> [Double] {
    var toks: [[Double]] = []
    let r = try! emb.embeddingResult(for: t, language: .japanese)
    r.enumerateTokenVectors(in: t.startIndex..<t.endIndex) { v, _ in toks.append(v); return true }
    return mean(toks)
}

// コーパス(文書セクション想定)
let corpus = [
    "ユーザー登録ではメールアドレスとパスワードを受け取り確認メールを送る",
    "ログイン認証はOAuth2を用い、アクセストークンを発行して有効期限を管理する",
    "リフレッシュトークンを使ってセッションを更新し、ローテーションする",
    "支払い処理はStripeを経由し、Webhookで決済完了を受け取る",
    "CSVファイルはRFC4180準拠でパースし、ヘッダを固定して行番号を付ける",
    "MermaidのコードブロックはSVGに描画してキャッシュする",
    "OpenAPIドキュメントはRedocで表示し、外部$refを解決する",
    "ダークモードに追従してテーマを切り替える",
]
// クエリ → 正解 index(語の重なりを避けた言い換え)
let queries: [(String, Int)] = [
    ("サインインの仕組みとトークンの発行手順は?", 1),
    ("会員のアカウント作成フローを知りたい", 0),
    ("クレジットカード決済の連携方法", 3),
    ("表形式データの読み込みと表示", 4),
    ("図表のレンダリングとキャッシュ", 5),
]

let raw = corpus.map(vec)
let center = mean(raw)
let centered = raw.map { sub($0, center) }

func evaluate(_ docs: [[Double]], centerVec: [Double]?) -> (top1: Int, mrr: Double) {
    var top1 = 0; var mrr = 0.0
    for (q, gold) in queries {
        var qv = vec(q)
        if let c = centerVec { qv = sub(qv, c) }
        let ranked = docs.enumerated().map { ($0.offset, cosine(qv, $0.element)) }
            .sorted { $0.1 > $1.1 }
        if ranked.first?.0 == gold { top1 += 1 }
        if let rank = ranked.firstIndex(where: { $0.0 == gold }) { mrr += 1.0 / Double(rank + 1) }
    }
    return (top1, mrr / Double(queries.count))
}

let plain = evaluate(raw, centerVec: nil)
let cent = evaluate(centered, centerVec: center)
print("中心化なし: top1=\(plain.top1)/\(queries.count)  MRR=\(String(format: "%.3f", plain.mrr))")
print("中心化あり: top1=\(cent.top1)/\(queries.count)  MRR=\(String(format: "%.3f", cent.mrr))")
print(cent.top1 >= plain.top1 ? "→ 中心化で改善または同等" : "→ 中心化で悪化")
