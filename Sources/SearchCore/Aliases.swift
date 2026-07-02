import Foundation

/// 日本語技術文書向けの同義語・表記ゆれテーブル。
/// 緩和語彙(OR-BM25)の展開にのみ使う: OR は BM25 の IDF 重みで効くため、
/// 多少の過剰展開はノイズになりにくい(厳密 AND には決して使わない)。
public enum Aliases {
    static let groups: [[String]] = [
        ["ログイン", "サインイン", "認証", "auth", "login"],
        ["登録", "サインアップ", "signup", "アカウント作成"],
        ["検索", "サーチ", "search"],
        ["埋め込み", "ベクトル", "embedding"],
        ["高速化", "パフォーマンス", "performance", "最適化", "速い"],
        ["図", "ダイアグラム", "チャート", "図表", "diagram", "mermaid"],
        ["画像", "イメージ", "image", "スクリーンショット"],
        ["非同期", "async", "並行", "並列"],
        ["テスト", "test", "アサーション", "検証"],
        ["データベース", "DB", "database", "SQL"],
        ["設定", "config", "コンフィグ", "構成"],
        ["生成AI", "LLM", "AI", "エージェント"],
        ["フロントエンド", "frontend", "フロント"],
        ["ビルド", "build", "コンパイル", "compile", "コンパイラ"],
        ["リファクタリング", "refactor", "リファクタ", "改修"],
        ["移行", "マイグレーション", "migration", "モダナイズ", "刷新"],
        ["重複", "duplicate", "コピペ", "similarity"],
        ["決済", "支払い", "payment", "課金", "stripe"],
        ["圧縮", "compress", "gzip"],
        ["計測", "測定", "metrics", "lighthouse"],
        ["定期実行", "cron", "スケジューラ"],
        ["キュー", "queue", "ジョブ"],
        ["キャッシュ", "cache"],
        ["描画", "レンダリング", "render", "レンダラ", "レイアウト"],
        ["エディタ", "editor", "vscode"],
        ["ターミナル", "terminal", "CLI", "コマンドライン"],
        ["正規表現", "regex"],
        ["例外", "exception", "エラー処理", "エラーハンドリング", "try"],
        ["環境構築", "セットアップ", "setup", "初期設定", "環境"],
        ["書き捨て", "スクラップ", "使い捨て"],
        ["履歴", "バージョン管理", "git", "コミット"],
        ["言語サーバ", "LSP", "language server"],
        ["リソース管理", "リソース解放", "using", "dispose"],
        ["文字起こし", "音声認識", "transcribe"],
        ["雛形", "テンプレート", "template", "スターター", "starter", "ボイラープレート"],
        ["自作", "スクラッチ", "作ってみた", "自前"],
        ["監視", "watch", "モニタリング", "オブザーバ"],
        ["通知", "notification", "webhook"],
        ["要約", "サマリ", "summary"],
        ["翻訳", "translate", "i18n"],
        ["並べ替え", "ソート", "sort", "ランキング"],
        ["ストレージ", "storage", "永続化", "保存"],
        ["トークン", "token"],
        ["型", "type", "型定義"],
        ["補完", "サジェスト", "オートコンプリート"],
    ]

    /// クエリ表層に substring 一致した語群の「残りの語」を展開語として返す。
    public static func expansions(for query: String) -> [String] {
        let lower = query.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        for g in groups where g.contains(where: { lower.contains($0.lowercased()) }) {
            for w in g where !lower.contains(w.lowercased()) && !seen.contains(w) {
                seen.insert(w)
                out.append(w)
            }
        }
        return out
    }
}
