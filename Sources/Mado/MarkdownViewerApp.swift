import SwiftUI

/// エントリポイント。`--index <path>` / `--search <path> -- <query>` のヘッドレス CLI を
/// SwiftUI 起動前に捌き、それ以外は通常の GUI アプリを起動する。
@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--index"), i + 1 < args.count {
            HeadlessCLI.index(path: args[i + 1]); return
        }
        if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
            let query = args.firstIndex(of: "--").map { args[($0 + 1)...].joined(separator: " ") } ?? ""
            HeadlessCLI.search(path: args[i + 1], query: query); return
        }
        if let i = args.firstIndex(of: "--eval"), i + 2 < args.count {
            HeadlessCLI.eval(corpus: args[i + 1], queriesPath: args[i + 2]); return
        }
        if let i = args.firstIndex(of: "--eval-structured"), i + 2 < args.count {
            HeadlessCLI.evalStructured(corpus: args[i + 1], queriesPath: args[i + 2]); return
        }
        if let i = args.firstIndex(of: "--mine-aliases"), i + 2 < args.count {
            let tau = (i + 3 < args.count) ? (Float(args[i + 3]) ?? 0.9) : 0.9
            HeadlessCLI.mineAliases(corpus: args[i + 1], output: args[i + 2], threshold: tau); return
        }
        MarkdownViewerApp.main()
    }
}

struct MarkdownViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        Settings {
            SettingsView()
        }
        // ファイル/フォルダを開くイベントでもこの WindowGroup にウィンドウを作らせる。
        // AppKit は argv のパスを open イベントに変換するため、
        // 受け口が無いと初期ウィンドウ自体が生成されない点に注意。
        .handlesExternalEvents(matching: ["*"])
        .windowToolbarStyle(.unified)
        .commands {
            MadoCommands()
            SidebarCommands()
        }
    }
}

/// フォーカス中のウィンドウの AppState に作用するメニューコマンド群。
/// (AppState はウィンドウごとに独立 — 新規ウィンドウは空で開く)
struct MadoCommands: Commands {
    @FocusedObject private var state: AppState?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { state?.promptOpenFolder() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(state == nil)
            Button("Reload") { state?.reloadCurrentFile(force: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state == nil)
            Button("Open in Terminal") { state?.openInTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(state?.rootURL == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                if let state {
                    NotificationCenter.default.post(name: .mdvOpenFind, object: state)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(state == nil)

            Button("Search in Files…") { state?.toggleSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state?.rootURL == nil)
        }
    }
}

extension Notification.Name {
    static let mdvOpenFind = Notification.Name("mdv.openFind")
    /// 検索結果 → 表示面への遷移(userInfo: path, anchor)
    static let mdvNavigate = Notification.Name("mdv.navigate")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run`(バンドル外)実行時もGUIアプリとして前面に出す
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
