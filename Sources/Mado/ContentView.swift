import SwiftUI

struct ContentView: View {
    /// ウィンドウごとに独立した状態。新規ウィンドウ(⌘N)は空で始まる。
    @StateObject private var state = AppState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            HStack(spacing: 0) {
                if state.isSearchPresented {
                    SearchPanel()
                        .frame(width: 430)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                // リーダーは既存の WKWebView(実際のレンダリング)を再利用。検索パネルの開閉で作り直さない。
                Group {
                    if state.selectedFile != nil {
                        MarkdownWebView()
                            .ignoresSafeArea(edges: .bottom)
                    } else {
                        EmptyDetailView()
                    }
                }
            }
            .animation(.easeOut(duration: 0.16), value: state.isSearchPresented)
        }
        .environmentObject(state)
        .focusedSceneObject(state) // メニューコマンド(⌘O/⌘R/⌘F)の作用先になる
        .onOpenURL { url in state.openPath(url) } // CLI / Finder / `open -a` からのパス
        .onAppear { state.restoreLastFolderIfNeeded() }
        .navigationTitle(state.selectedFile?.lastPathComponent ?? "Mado")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    state.toggleSearch()
                } label: {
                    Label("Search in Files", systemImage: "magnifyingglass")
                }
                .disabled(state.rootURL == nil)
                .help("フォルダ横断検索 (⌘⇧F)")
            }
            ToolbarItem {
                Button {
                    state.openInTerminal()
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .disabled(state.rootURL == nil)
                .help("プロジェクトをターミナルで開く (⌘⇧T)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.promptOpenFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open Folder (⌘O)")
            }
        }
    }

    private var subtitle: String {
        guard let root = state.rootURL, let file = state.selectedFile else { return "" }
        let relative = file.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path, with: root.lastPathComponent)
        return relative
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let root = state.rootNode {
                List(selection: selectionBinding) {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        if node.isDirectory {
                            Label(node.name, systemImage: node.icon)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(node.name, systemImage: node.icon)
                                .tag(node.url)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Button("Open Folder…") { state.promptOpenFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// ディレクトリ行は選択対象にしない
    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { state.selectedFile },
            set: { url in
                if let url, FileNode.isViewable(url) {
                    state.selectedFile = url
                }
            }
        )
    }
}

struct EmptyDetailView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            if state.rootURL == nil {
                Text("フォルダを開いてください")
                    .foregroundStyle(.secondary)
                Button("Open Folder… (⌘O)") { state.promptOpenFolder() }
            } else {
                Text("サイドバーから Markdown を選択")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
