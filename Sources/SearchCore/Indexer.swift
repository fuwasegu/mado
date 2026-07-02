import Foundation
import CryptoKit

/// ファイル走査 → 解析 → IndexStore への upsert を担う。
/// UI ツリー(Mado の FileNode)とは独立した、検索専用の列挙器。
/// 無視ディレクトリ集合は FileNode と意図的に一致させている。
public enum Indexer {

    public static let ignoredDirectories: Set<String> = [
        "node_modules", "Pods", "DerivedData", "dist", "build",
        "venv", "__pycache__", "target",
        ".git", ".svn", ".hg", ".build", ".swiftpm", ".venv", ".tox",
        ".cache", ".next", ".nuxt", ".Trash",
    ]

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Markdown 以外で全文索引する拡張子(構造抽出はせず行窓チャンクで索引)。
    public static let plainTextExtensions: Set<String> = ["yaml", "yml", "json", "toml", "mermaid", "mmd"]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isIndexable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExtensions.contains(ext) || plainTextExtensions.contains(ext)
    }

    /// content_hash 用の安定ハッシュ(MD5 hex)。暗号用途ではない。
    public static func contentHash(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ルート配下の索引対象ファイルを再帰列挙する(無視ディレクトリを除外、深さ制限あり)。
    public static func enumerateIndexable(root: URL, maxDepth: Int = 12) -> [URL] {
        var result: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth < maxDepth else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if ignoredDirectories.contains(entry.lastPathComponent) { continue }
                    walk(entry, depth: depth + 1)
                } else if isIndexable(entry) {
                    result.append(entry)
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    public struct ReconcileStats: Sendable {
        public var added = 0
        public var updated = 0
        public var removed = 0
        public var skipped = 0
    }

    /// ルート全体をインデックスと同期する(初回 / 起動時 reconcile)。
    /// 未変更ファイル(content_hash 一致)は skip。消えたファイルは削除。
    @discardableResult
    public static func reconcile(root: URL, store: IndexStore,
                                 nowEpoch: Double) throws -> ReconcileStats {
        try store.setRoot(root.path)
        var stats = ReconcileStats()
        let existing = try store.hashes()
        var seen = Set<String>()

        for url in enumerateIndexable(root: root) {
            seen.insert(url.path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let hash = contentHash(data)
            if existing[url.path] == hash { stats.skipped += 1; continue }
            let isNew = existing[url.path] == nil
            try indexOne(url: url, root: root, data: data, hash: hash, store: store, nowEpoch: nowEpoch)
            if isNew { stats.added += 1 } else { stats.updated += 1 }
        }

        // インデックスに在るがファイルシステムから消えたもの
        for path in existing.keys where !seen.contains(path) {
            try store.deleteFile(path: path)
            stats.removed += 1
        }

        try store.resolveLinkTargets()
        return stats
    }

    /// 単一ファイルのインデックス更新(増分用)。data/hash 未指定なら読み直す。
    public static func indexOne(url: URL, root: URL, data: Data? = nil, hash: String? = nil,
                                store: IndexStore, nowEpoch: Double) throws {
        let bytes: Data
        if let data { bytes = data } else {
            guard let d = try? Data(contentsOf: url) else { return }
            bytes = d
        }
        let content = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .shiftJIS) ?? ""
        let h = hash ?? contentHash(bytes)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? nowEpoch
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(bytes.count)

        let rel = relativePath(of: url, root: root)
        let dir = (rel as NSString).deletingLastPathComponent
        // Markdown は構造抽出、それ以外(yaml/json 等)は行窓チャンクで全文索引
        let parsed = isMarkdown(url)
            ? MarkdownStructure.parse(content: content, fileName: url.lastPathComponent)
            : MarkdownStructure.plainDoc(content: content, fileName: url.lastPathComponent)
        let docDate = frontMatterDate(parsed.frontMatter) ?? mtime
        let file = IndexedFile(
            path: url.path, relPath: rel, dir: dir,
            ext: url.pathExtension.lowercased(), mtime: mtime, size: size,
            contentHash: h, title: parsed.title, docDate: docDate)
        try store.upsert(file: file, parsed: parsed, indexedAt: nowEpoch)
    }

    /// 増分更新: 存在すれば(未変更なら skip して)index、無ければ削除。index が変化したら true。
    @discardableResult
    public static func updatePath(_ url: URL, root: URL, store: IndexStore, nowEpoch: Double) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path), isIndexable(url) {
            guard let data = try? Data(contentsOf: url) else { return false }
            let hash = contentHash(data)
            if try store.hash(forPath: url.path) == hash { return false }   // 未変更
            try indexOne(url: url, root: root, data: data, hash: hash, store: store, nowEpoch: nowEpoch)
            try store.resolveLinkTargets()
            return true
        } else {
            // 削除 or 非対象(未インデックスなら no-op)
            try store.deleteFile(path: url.path)
            return true
        }
    }

    private static let dateKeys: Set<String> = ["date", "published", "published_at", "created", "created_at", "updated"]
    /// front matter から日付を epoch 秒で取り出す(yyyy-MM-dd / yyyy-MM / yyyy / ISO8601)。
    static func frontMatterDate(_ fm: [(key: String, value: String)]) -> Double? {
        guard let raw = fm.first(where: { dateKeys.contains($0.key.lowercased()) })?.value, !raw.isEmpty else { return nil }
        let s = String(raw.prefix(10))   // "2026-06-30T..." → "2026-06-30"
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current
        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM", "yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    public static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) { return String(url.path.dropFirst(rootPath.count)) }
        return url.lastPathComponent
    }
}
