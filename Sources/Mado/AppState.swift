import AppKit
import SwiftUI
import SearchCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var rootNode: FileNode?
    @Published var selectedFile: URL? {
        didSet {
            guard oldValue != selectedFile else { return }
            loadSelectedFile()
        }
    }
    /// 現在表示中ファイルの中身。WebView 側はこれと selectedFile の組で再描画判定する。
    @Published private(set) var currentContent: String = ""

    private var watcher: FSEventsWatcher?
    private var rescanWorkItem: DispatchWorkItem?

    /// 検索インデックス(バックグラウンド)。表示パスとは独立して動く。
    let searchIndex = SearchIndex()
    private var searchWorkItem: DispatchWorkItem?
    private var pendingSearchPaths: Set<String> = []

    // MARK: - 検索パネル(表示面とは別 view)
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchHit] = []
    @Published private(set) var searchFacets: [QueryFacet] = []
    @Published private(set) var searchTerms: [String] = []
    @Published private(set) var isSearching = false
    /// 意味索引の構築進捗(done/total)。total>0 かつ done<total の間だけ表示。
    @Published private(set) var embedDone = 0
    @Published private(set) var embedTotal = 0
    var isEmbeddingIndex: Bool { embedTotal > 0 && embedDone < embedTotal }
    /// 現在ハイライト中の結果(由来フッタ/選択表示用)。ナビゲーションは openResult で別途行う。
    @Published var highlightedHitID: SearchHit.ID?
    private var searchTask: Task<Void, Never>?

    func openSearch() { isSearchPresented = true }
    func closeSearch() { isSearchPresented = false }
    func toggleSearch() { isSearchPresented.toggle() }

    /// 入力に応じて背景 actor で検索を実行(逐次キャンセル)。UI スレッドは触らせない。
    func runSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !q.isEmpty else {
            searchResults = []; searchFacets = []; searchTerms = []
            highlightedHitID = nil; isSearching = false; return
        }
        isSearching = true
        let interp = searchIndex.interpret(q)   // 軽量・nonisolated
        searchFacets = interp.facets
        searchTerms = interp.terms
        searchTask = Task { [searchIndex] in
            let hits = await searchIndex.search(q, limit: 80)
            if Task.isCancelled { return }
            await MainActor.run {
                self.searchResults = hits
                self.highlightedHitID = hits.first?.id
                self.isSearching = false
            }
        }
    }

    /// 検索結果を開く: ファイルを表示面に渡し、該当見出しへスクロール(handoff)。
    func openResult(_ hit: SearchHit) {
        NotificationCenter.default.post(
            name: .mdvNavigate, object: self,
            userInfo: ["path": hit.path, "anchor": hit.headingSlug,
                       "terms": searchTerms, "phrase": hit.landingPhrase ?? ""])
    }

    // MARK: - Open / Restore

    /// パスを開く(フォルダ→そのまま、.md→親フォルダを開いて選択)。
    /// onOpenURL(CLI引数 / Finder / open -a)の着地点。
    func openPath(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            openFolder(url)
        } else if FileNode.isViewable(url) {
            openFolder(url.deletingLastPathComponent())
            selectedFile = url
        }
    }

    /// CLI 引数の処理は最初のウィンドウだけ。
    private static var didProcessArguments = false

    /// 起動時はパスが明示的に渡されたとき(CLI 引数)だけ開き、それ以外は空で始める。
    /// (バンドル外実行では open イベントが来ないことがあるため argv は自前で見る)
    func restoreLastFolderIfNeeded() {
        guard rootURL == nil, !Self.didProcessArguments else { return }
        Self.didProcessArguments = true
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                openPath(url)
                return
            }
        }
    }

    /// 開いているプロジェクトのルートでターミナルを開く
    func openInTerminal() {
        guard let rootURL else { return }
        TerminalLauncher.open(folder: rootURL)
    }

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        // FSEvents はシンボリックリンク解決済みパス(/tmp → /private/tmp 等)で
        // イベントを報告するため、比較が一致するよう最初から解決しておく
        let url = url.resolvingSymlinksInPath()
        rootURL = url
        // 初回スキャンはフォルダを開いた瞬間の一度きりなので同期実行(既定選択に必要)。
        // 以降の監視中の再走査はバックグラウンドに逃がす(rescanTree 参照)。
        let tree = FileNode.scan(root: url)
        rootNode = tree
        startWatching(url)

        // 検索インデックスは起動/切替をブロックしない。背景で開いて差分照合する。
        // (起動 0.4s を守るため UI スレッド・初回 FileNode.scan とは別経路)
        Task.detached(priority: .utility) { [weak self, searchIndex] in
            await searchIndex.setProgressHandler { done, total in
                Task { @MainActor in
                    self?.embedDone = done
                    self?.embedTotal = total
                }
            }
            await searchIndex.openAndReconcile(root: url)
        }

        // 既定の選択: 前回の選択がツリー内に残っていれば維持、なければ README → 最初の .md
        if let selected = selectedFile, selected.path.hasPrefix(url.path),
           FileManager.default.fileExists(atPath: selected.path) {
            loadSelectedFile()
        } else {
            selectedFile = defaultFile(in: tree)
        }
    }

    private func defaultFile(in node: FileNode?) -> URL? {
        guard let node else { return nil }
        var firstMarkdown: URL?
        var firstFile: URL?
        var queue: [FileNode] = node.children ?? []
        var index = 0
        while index < queue.count {
            let n = queue[index]
            index += 1
            if n.isDirectory {
                queue.append(contentsOf: n.children ?? [])
            } else {
                if n.name.lowercased().hasPrefix("readme") { return n.url }
                if firstMarkdown == nil, FileNode.isMarkdown(n.url) { firstMarkdown = n.url }
                if firstFile == nil { firstFile = n.url }
            }
        }
        return firstMarkdown ?? firstFile
    }

    // MARK: - Watching

    private func startWatching(_ url: URL) {
        watcher?.stop()
        watcher = FSEventsWatcher(path: url.path) { [weak self] events in
            Task { @MainActor in
                self?.handleFileSystemEvents(events)
            }
        }
    }

    /// サイドバーのツリー構造を変えうるフラグ(作成・削除・リネーム)。
    /// 内容変更(Modified)は表示名に影響しないため再走査の対象外。
    private static let structuralFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
    )

    private func handleFileSystemEvents(_ events: [FSEvent]) {
        // 検索インデックスは「内容変更」も拾う必要がある(ツリー再走査は Modified を無視するのと対照的)。
        // .md を触るイベントを集めてデバウンスし、背景 actor に増分反映する。
        queueSearchIndexUpdate(events)

        // 表示中ファイルに触れたイベントは即リロード(atomic rename は親ディレクトリのイベントになる場合もある)
        if let current = selectedFile {
            let dir = current.deletingLastPathComponent().path
            if events.contains(where: { $0.path == current.path || $0.path == dir }) {
                reloadCurrentFile()
            }
        }
        // FS イベントの大半はファイル内容の変更(Claude Code の書き込み等)で、ツリーは変わらない。
        // 構造を変えうる作成/削除/リネームが、無視ディレクトリの外で起きた時だけ再走査する。
        // これにより、書き込みの嵐の最中でもフルツリー走査が走らずスクロールが詰まらない。
        let treeMayHaveChanged = events.contains {
            $0.flags & Self.structuralFlags != 0 && !FileNode.isInIgnoredDirectory(path: $0.path)
        }
        guard treeMayHaveChanged else { return }

        // ツリーは連続イベントをデバウンスして再走査
        rescanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rescanTree()
            // 表示中のファイルが消えたらクリア
            if let current = self.selectedFile,
               !FileManager.default.fileExists(atPath: current.path) {
                self.selectedFile = nil
                self.currentContent = ""
            }
        }
        rescanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// .md を触る FS イベントを集約し、0.3s デバウンスして検索インデックスへ増分反映する。
    private func queueSearchIndexUpdate(_ events: [FSEvent]) {
        let mdPaths = events.lazy
            .map { $0.path }
            .filter { !FileNode.isInIgnoredDirectory(path: $0)
                && Indexer.isIndexable(URL(fileURLWithPath: $0)) }
        guard !mdPaths.isEmpty else { return }
        pendingSearchPaths.formUnion(mdPaths)

        searchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingSearchPaths)
            self.pendingSearchPaths.removeAll()
            Task.detached(priority: .utility) { [searchIndex = self.searchIndex] in
                await searchIndex.apply(paths: paths)
            }
        }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// 監視中の再走査はバックグラウンドで行い、差分があった時だけメインに反映する。
    /// (大きなツリーの contentsOfDirectory 再帰と深い構造比較を UI スレッドから外し、
    ///  スクロールのカクつきを防ぐ)
    private func rescanTree() {
        guard let rootURL else { return }
        let previous = rootNode
        Task.detached(priority: .utility) {
            let newTree = FileNode.scan(root: rootURL)
            guard newTree != previous else { return }
            await MainActor.run { [weak self] in
                // 走査中にフォルダが切り替わっていたら、古いツリーで上書きしない
                guard let self, self.rootURL == rootURL else { return }
                self.rootNode = newTree
            }
        }
    }

    // MARK: - Content

    private func loadSelectedFile() {
        guard let url = selectedFile else {
            currentContent = ""
            return
        }
        currentContent = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .shiftJIS))
            ?? ""
    }

    func reloadCurrentFile(force: Bool = false) {
        guard let url = selectedFile else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if force || content != currentContent {
            currentContent = content
        }
    }
}
