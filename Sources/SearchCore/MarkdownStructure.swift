import Foundation

/// Markdown 本文から構造化メタデータとチャンクを抽出する。
/// front matter 正規表現と見出し slug は viewer.js(Resources/viewer.js)と整合させる。
public enum MarkdownStructure {

    // MARK: slug(viewer.js:616-631 と同一アルゴリズム)

    /// 見出しテキスト → アンカー id。JS 側 assignHeadingIds と同じ規則:
    /// trim → lowercase → 文字/数字/空白/_/- 以外を除去 → 空白連続を - に。
    public static func slugify(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
            } else if ch == " " || ch == "\t" || ch.isWhitespace {
                out.append(" ")
            }
            // それ以外(記号など)は除去
        }
        // 空白連続 → 単一ハイフン
        let parts = out.split(whereSeparator: { $0 == " " })
        return parts.joined(separator: "-")
    }

    /// slug の一意化(used に対し -1, -2 ... を付与)。viewer.js と同じ。
    private static func uniqueSlug(_ base: String, used: inout Set<String>) -> String {
        var unique = base
        var i = 1
        while used.contains(unique) { unique = "\(base)-\(i)"; i += 1 }
        used.insert(unique)
        return unique
    }

    // MARK: 解析本体

    public static func parse(content: String, fileName: String) -> ParsedDoc {
        var lines = content.components(separatedBy: "\n")
        // \r\n 対応
        for i in lines.indices where lines[i].hasSuffix("\r") { lines[i].removeLast() }

        // --- front matter ---
        var frontMatter: [(key: String, value: String)] = []
        var bodyStartLine = 0  // 0-origin の行 index
        if lines.first == "---" {
            if let end = lines[1...].firstIndex(of: "---") {
                let fmLines = Array(lines[1..<end])
                frontMatter = parseFrontMatter(fmLines)
                bodyStartLine = end + 1
            }
        }

        // --- 本文走査:見出し / タスク / code fence / リンク ---
        var headings: [Heading] = []
        var tasks: [DocTask] = []
        var codeLangs: Set<String> = []
        var links: [DocLink] = []
        var usedSlugs: Set<String> = []
        var headingStack: [(level: Int, text: String)] = []  // breadcrumb 用

        // チャンク境界: (開始行 index, slug, breadcrumb)
        struct Boundary { var startIdx: Int; var slug: String; var path: String }
        var boundaries: [Boundary] = [Boundary(startIdx: bodyStartLine, slug: "", path: "")]

        var inFence = false
        var fenceMarker = ""

        for idx in bodyStartLine..<lines.count {
            let raw = lines[idx]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // code fence の開閉
            if !inFence, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                if !lang.isEmpty { codeLangs.insert(lang.lowercased()) }
                continue
            } else if inFence {
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                continue   // fence 内は見出し等として扱わない
            }

            // 見出し
            if let h = parseHeading(raw, line: idx + 1) {
                // breadcrumb スタック更新
                while let last = headingStack.last, last.level >= h.level { headingStack.removeLast() }
                headingStack.append((h.level, h.text))
                let pathText = headingStack.map { $0.text }.joined(separator: " > ")
                let slug = uniqueSlug(slugify(h.text), used: &usedSlugs)
                let heading = Heading(level: h.level, text: h.text, slug: slug, line: idx + 1, pathText: pathText)
                headings.append(heading)
                boundaries.append(Boundary(startIdx: idx, slug: slug, path: pathText))
                continue
            }

            // タスク
            if let t = parseTask(raw, line: idx + 1) { tasks.append(t) }

            // リンク(本文行のみ)
            links.append(contentsOf: parseLinks(raw))
        }

        // --- チャンク生成(見出し境界で分割) ---
        var chunks: [Chunk] = []
        for (bi, b) in boundaries.enumerated() {
            let endIdx = (bi + 1 < boundaries.count) ? boundaries[bi + 1].startIdx : lines.count
            guard b.startIdx < endIdx else { continue }
            let text = lines[b.startIdx..<endIdx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            chunks.append(Chunk(headingSlug: b.slug, headingPath: b.path,
                                text: text, startLine: b.startIdx + 1, endLine: endIdx))
        }

        // --- title ---
        let fmTitle = frontMatter.first(where: { $0.key.lowercased() == "title" })?.value
        let h1 = headings.first(where: { $0.level == 1 })?.text
        let title = fmTitle?.nilIfEmpty ?? h1?.nilIfEmpty
            ?? (fileName as NSString).deletingPathExtension

        return ParsedDoc(title: title, frontMatter: frontMatter, headings: headings,
                         links: links, tasks: tasks, codeLangs: Array(codeLangs).sorted(), chunks: chunks)
    }

    /// 非 Markdown(yaml/json/toml/mermaid 等)向け: 構造抽出はせず、行窓チャンクで全文索引する。
    /// 巨大ファイル対策として先頭 maxLines 行までに制限。
    public static func plainDoc(content: String, fileName: String,
                                windowLines: Int = 80, maxLines: Int = 4000) -> ParsedDoc {
        var lines = content.components(separatedBy: "\n")
        for i in lines.indices where lines[i].hasSuffix("\r") { lines[i].removeLast() }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }

        var chunks: [Chunk] = []
        var start = 0
        while start < lines.count {
            let end = min(start + windowLines, lines.count)
            let text = lines[start..<end].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // 複数チャンクに分かれる場合のみ行レンジを breadcrumb に出す
                let path = lines.count > windowLines ? "L\(start + 1)–\(end)" : ""
                chunks.append(Chunk(headingSlug: "", headingPath: path,
                                    text: text, startLine: start + 1, endLine: end))
            }
            start = end
        }
        return ParsedDoc(title: fileName, frontMatter: [], headings: [],
                         links: [], tasks: [], codeLangs: [], chunks: chunks)
    }

    // MARK: 個別パーサ

    private static func parseHeading(_ line: String, line lineNo: Int) -> (level: Int, text: String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 7 { level += 1; idx = line.index(after: idx) }
        guard (1...6).contains(level), idx < line.endIndex, line[idx] == " " else { return nil }
        var text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        // 末尾の閉じ # を除去(ATX closing)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        text = stripInlineMarkdown(text)
        return text.isEmpty ? nil : (level, text)
    }

    private static func parseTask(_ line: String, line lineNo: Int) -> DocTask? {
        let t = line.trimmingCharacters(in: .whitespaces)
        // - [ ] / - [x] / * [X] / + [ ]
        guard t.count >= 5, let first = t.first, "-*+".contains(first) else { return nil }
        let after = t.dropFirst().drop(while: { $0 == " " })
        guard after.hasPrefix("[") else { return nil }
        let chars = Array(after)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let mark = chars[1]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        let rest = String(chars[3...]).trimmingCharacters(in: .whitespaces)
        return DocTask(checked: mark != " ", text: stripInlineMarkdown(rest), line: lineNo)
    }

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
    private static let wikiRegex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    private static func parseLinks(_ line: String) -> [DocLink] {
        var result: [DocLink] = []
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        for m in linkRegex.matches(in: line, range: range) {
            let url = ns.substring(with: m.range(at: 1))
            result.append(classifyLink(url))
        }
        for m in wikiRegex.matches(in: line, range: range) {
            let target = ns.substring(with: m.range(at: 1))
            let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(parts[0])
            let anchor = parts.count > 1 ? String(parts[1]) : nil
            result.append(DocLink(targetPath: path, anchor: anchor, kind: "wiki"))
        }
        return result
    }

    private static func classifyLink(_ url: String) -> DocLink {
        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]) : nil
        if path.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return DocLink(targetPath: path, anchor: anchor, kind: "external")
        }
        let kind = path.lowercased().hasSuffix(".md") ? "md" : "asset"
        return DocLink(targetPath: path, anchor: anchor, kind: kind)
    }

    /// 見出し/タスクの表示テキストから簡易にインライン Markdown 記号を除去。
    private static func stripInlineMarkdown(_ s: String) -> String {
        var t = s
        // [text](url) → text
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // 強調/コード記号
        for token in ["**", "__", "`", "*", "_", "~~"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: front matter(簡易 YAML)

    private static func parseFrontMatter(_ fmLines: [String]) -> [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        var currentListKey: String?
        for raw in fmLines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // インデントされた "- item" はリスト要素
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = currentListKey, trimmed.hasPrefix("- ") {
                let v = unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                if !v.isEmpty { pairs.append((key, v)) }
                continue
            }

            // "key: value"
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            let valuePart = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if valuePart.isEmpty {
                // 次行以降がリストかネスト → リストキーとして記憶
                currentListKey = key
                continue
            }
            currentListKey = nil

            // インラインリスト [a, b, c]
            if valuePart.hasPrefix("[") && valuePart.hasSuffix("]") {
                let inner = valuePart.dropFirst().dropLast()
                for item in inner.split(separator: ",") {
                    let v = unquote(item.trimmingCharacters(in: .whitespaces))
                    if !v.isEmpty { pairs.append((key, v)) }
                }
            } else {
                pairs.append((key, unquote(valuePart)))
            }
        }
        return pairs
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
