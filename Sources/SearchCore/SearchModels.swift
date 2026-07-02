import Foundation

/// インデックス済みファイルの 1 レコード。
public struct IndexedFile: Sendable {
    public var id: Int64
    public var path: String          // 絶対パス
    public var relPath: String       // ルートからの相対パス
    public var dir: String           // 親ディレクトリ(相対)
    public var ext: String           // 拡張子(小文字, ドットなし)
    public var mtime: Double         // 最終更新(epoch 秒)
    public var size: Int64
    public var contentHash: String   // 内容ハッシュ(未変更スキップ用)
    public var title: String         // 表示用タイトル(先頭 H1 or front matter title or ファイル名)
    public var docDate: Double       // 文書の日付(front matter date、無ければ mtime)。時間軸フィルタ用

    public init(id: Int64 = 0, path: String, relPath: String, dir: String, ext: String,
                mtime: Double, size: Int64, contentHash: String, title: String, docDate: Double = 0) {
        self.id = id; self.path = path; self.relPath = relPath; self.dir = dir
        self.ext = ext; self.mtime = mtime; self.size = size
        self.contentHash = contentHash; self.title = title; self.docDate = docDate
    }
}

public struct Heading: Sendable {
    public var level: Int            // 1...6
    public var text: String
    public var slug: String          // viewer.js と同一アルゴリズムの id
    public var line: Int             // 1-origin
    public var pathText: String      // "H1 > H2 > H3" breadcrumb
    public init(level: Int, text: String, slug: String, line: Int, pathText: String) {
        self.level = level; self.text = text; self.slug = slug; self.line = line; self.pathText = pathText
    }
}

public struct DocLink: Sendable {
    public var targetPath: String    // リンク先(相対 or 絶対、解決前)
    public var anchor: String?       // #fragment
    public var kind: String          // "md" | "wiki" | "external" | "asset"
    public init(targetPath: String, anchor: String?, kind: String) {
        self.targetPath = targetPath; self.anchor = anchor; self.kind = kind
    }
}

public struct DocTask: Sendable {
    public var checked: Bool
    public var text: String
    public var line: Int
    public init(checked: Bool, text: String, line: Int) {
        self.checked = checked; self.text = text; self.line = line
    }
}

/// 見出しセクション単位の本文チャンク(全文・意味検索の最小単位)。
public struct Chunk: Sendable {
    public var headingSlug: String   // 所属見出しの slug("" = front matter 前の前文)
    public var headingPath: String   // breadcrumb
    public var text: String          // 本文(見出しテキスト含む)
    public var startLine: Int
    public var endLine: Int
    public init(headingSlug: String, headingPath: String, text: String, startLine: Int, endLine: Int) {
        self.headingSlug = headingSlug; self.headingPath = headingPath
        self.text = text; self.startLine = startLine; self.endLine = endLine
    }
}

/// 1 ファイルを解析した構造化結果。
public struct ParsedDoc: Sendable {
    public var title: String
    public var frontMatter: [(key: String, value: String)]
    public var headings: [Heading]
    public var links: [DocLink]
    public var tasks: [DocTask]
    public var codeLangs: [String]
    public var chunks: [Chunk]
    public init(title: String, frontMatter: [(key: String, value: String)], headings: [Heading],
                links: [DocLink], tasks: [DocTask], codeLangs: [String], chunks: [Chunk]) {
        self.title = title; self.frontMatter = frontMatter; self.headings = headings
        self.links = links; self.tasks = tasks; self.codeLangs = codeLangs; self.chunks = chunks
    }
}

public enum MatchKind: String, Sendable {
    case lexical    // 全文(BM25)
    case semantic   // 埋め込み類似
    case structured // 構造化フィルタ一致
}

/// 検索結果 1 件(チャンク粒度)。
public struct SearchHit: Sendable, Identifiable, Hashable {
    public var id: String { "\(path)#\(headingSlug)" }
    public var path: String          // 絶対パス
    public var relPath: String
    public var title: String         // ファイルタイトル
    public var headingPath: String   // セクション breadcrumb
    public var headingSlug: String   // ジャンプ先 slug
    public var snippet: String       // ハイライト用スニペット
    public var score: Double         // 融合スコア(RRF、降順)
    public var bm25: Double?         // 全文の生スコア(負値ほど良い)。無ければ nil
    public var cosine: Double?       // 意味の類似度(0–1)。無ければ nil
    public var bestPassage: String?  // 最類似セグメント原文(意味ヒットの着地・スニペット用)
    public var kinds: Set<MatchKind>
    public init(path: String, relPath: String, title: String, headingPath: String,
                headingSlug: String, snippet: String, score: Double,
                bm25: Double? = nil, cosine: Double? = nil,
                bestPassage: String? = nil, kinds: Set<MatchKind>) {
        self.path = path; self.relPath = relPath; self.title = title
        self.headingPath = headingPath; self.headingSlug = headingSlug
        self.snippet = snippet; self.score = score
        self.bm25 = bm25; self.cosine = cosine
        self.bestPassage = bestPassage; self.kinds = kinds
    }

    /// 着地用フレーズ: bestPassage からインライン記号を含まない最長の連続部分を切り出す。
    /// viewer 側の DOM テキスト検索(indexOf)で見つかるよう、Markdown 記法を避けた素の文片にする。
    public var landingPhrase: String? {
        guard let passage = bestPassage else { return nil }
        let forbidden: Set<Character> = ["`", "*", "_", "[", "]", "(", ")", "#", "|", "<", ">", "\n"]
        var best = "", cur = ""
        for ch in passage {
            if forbidden.contains(ch) {
                if cur.count > best.count { best = cur }
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if cur.count > best.count { best = cur }
        let t = best.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return nil }
        return String(t.prefix(28))
    }
}
