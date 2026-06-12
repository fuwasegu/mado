import AppKit
import SwiftUI

/// 既知のターミナルアプリ。arguments が nil ならフォルダを開く(odoc)方式で
/// cd した状態のウィンドウが開く。それ以外は起動引数でカレントディレクトリを渡す。
struct TerminalApp: Identifiable {
    let name: String
    let bundleID: String
    let arguments: (@Sendable (String) -> [String])?

    var id: String { bundleID }

    /// 優先順位順(自動選択はこの順で最初に見つかったもの)
    static let known: [TerminalApp] = [
        TerminalApp(name: "iTerm2", bundleID: "com.googlecode.iterm2", arguments: nil),
        TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable", arguments: nil),
        TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty", arguments: nil),
        TerminalApp(
            name: "WezTerm", bundleID: "com.github.wez.wezterm",
            arguments: { ["start", "--cwd", $0] }
        ),
        TerminalApp(
            name: "kitty", bundleID: "net.kovidgoyal.kitty",
            arguments: { ["--directory", $0] }
        ),
        TerminalApp(
            name: "Alacritty", bundleID: "org.alacritty",
            arguments: { ["--working-directory", $0] }
        ),
        TerminalApp(name: "ターミナル", bundleID: "com.apple.Terminal", arguments: nil),
    ]

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var installed: [TerminalApp] {
        known.filter { $0.appURL != nil }
    }
}

@MainActor
enum TerminalLauncher {
    static let defaultsKey = "terminalBundleID"

    /// 設定で選ばれたターミナル。未設定/未インストールなら優先順位で自動選択。
    static var selected: TerminalApp? {
        let saved = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !saved.isEmpty,
           let app = TerminalApp.known.first(where: { $0.bundleID == saved }),
           app.appURL != nil {
            return app
        }
        return TerminalApp.installed.first
    }

    static func open(folder: URL) {
        guard let app = selected, let appURL = app.appURL else {
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let arguments = app.arguments {
            config.arguments = arguments(folder.path)
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config)
        }
    }
}

struct SettingsView: View {
    @AppStorage(TerminalLauncher.defaultsKey) private var terminalID = ""

    var body: some View {
        Form {
            Picker("ターミナル:", selection: $terminalID) {
                Text("自動(\(TerminalApp.installed.first?.name ?? "なし"))").tag("")
                Divider()
                ForEach(TerminalApp.installed) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            Text("「ターミナルで開く」(⌘⇧T)で使用するアプリ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }
}
