import Foundation

/// インデックスファイルの保存場所。アプリ(SearchIndex actor)と MCP サーバが
/// 同じフォルダ→同じ .sqlite を指すよう、ここで一元化する。
public enum IndexLocation {
    /// ~/Library/Application Support/Mado/index/<folder-path-hash>.sqlite
    public static func url(forRoot root: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Mado/index", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Indexer.contentHash(Data(root.resolvingSymlinksInPath().path.utf8))
        return dir.appendingPathComponent("\(key).sqlite")
    }
}
