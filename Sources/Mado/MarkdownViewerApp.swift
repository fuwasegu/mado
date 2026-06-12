import SwiftUI

@main
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
        }
    }
}

extension Notification.Name {
    static let mdvOpenFind = Notification.Name("mdv.openFind")
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
