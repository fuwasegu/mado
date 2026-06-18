import Foundation

/// サイドバーのツリー1ノード。Markdown を含むディレクトリと .md ファイルのみ保持する。
struct FileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// ディレクトリなら子ノード(空でも非nil)、ファイルなら nil。OutlineGroup の規約に合わせる。
    let children: [FileNode]?

    var id: String { url.path }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    /// ビューアで開ける拡張子(Markdown + データ/設定ファイル)
    static let viewableExtensions: Set<String> = markdownExtensions.union(
        ["json", "yaml", "yml", "csv", "tsv", "mermaid", "mmd"]
    )

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func isViewable(_ url: URL) -> Bool {
        viewableExtensions.contains(url.pathExtension.lowercased())
    }

    /// サイドバー用 SF Symbol
    var icon: String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "json", "yaml", "yml": return "curlybraces"
        case "csv", "tsv": return "tablecells"
        case "mermaid", "mmd": return "point.3.connected.trianglepath.dotted"
        default: return "doc.text"
        }
    }

    /// 除外するディレクトリ名。dot ディレクトリは原則表示する(.claude/ や .github/ に
    /// Markdown が置かれるため)が、確実にノイズなものだけ名指しで除外する。
    private static let ignoredDirectories: Set<String> = [
        "node_modules", "Pods", "DerivedData", "dist", "build",
        "venv", "__pycache__", "target",
        ".git", ".svn", ".hg", ".build", ".swiftpm", ".venv", ".tox",
        ".cache", ".next", ".nuxt", ".Trash",
    ]

    /// パスが無視ディレクトリ(node_modules / .git 等)配下にあるか。
    /// FSEvents の再走査要否判定に使い、無関係なディレクトリのイベントを早期に捨てる。
    static func isInIgnoredDirectory(path: String) -> Bool {
        for component in (path as NSString).pathComponents where ignoredDirectories.contains(component) {
            return true
        }
        return false
    }

    /// ルート以下を走査し、表示可能ファイルを1つ以上含むサブツリーだけを返す。
    static func scan(root: URL) -> FileNode {
        FileNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: scanChildren(of: root, depth: 0)
        )
    }

    private static func scanChildren(of dir: URL, depth: Int) -> [FileNode] {
        guard depth < 12 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var nodes: [FileNode] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if ignoredDirectories.contains(entry.lastPathComponent) { continue }
                let children = scanChildren(of: entry, depth: depth + 1)
                if !children.isEmpty {
                    nodes.append(FileNode(
                        url: entry,
                        name: entry.lastPathComponent,
                        isDirectory: true,
                        children: children
                    ))
                }
            } else if isViewable(entry) {
                nodes.append(FileNode(
                    url: entry,
                    name: entry.lastPathComponent,
                    isDirectory: false,
                    children: nil
                ))
            }
        }
        // ディレクトリ優先、名前順(エディタ標準の並び)
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
