import Foundation
import SearchCore

// MadoSearchMCP — Mado の検索インデックスを Claude Code から叩く MCP サーバ。
// JSON-RPC 2.0 / newline-delimited / stdio。Pure Swift・追加依存なし。
// 使い方: MadoSearchMCP <folder>
//   起動時にインデックスを reconcile(アプリと同じ .sqlite を共有)し、stdin で待ち受ける。

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data("usage: MadoSearchMCP <folder>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: (argv[1] as NSString).expandingTildeInPath).resolvingSymlinksInPath()
guard FileManager.default.fileExists(atPath: root.path) else {
    FileHandle.standardError.write(Data("folder not found: \(root.path)\n".utf8))
    exit(2)
}

let server = MCPServer(root: root)
server.run()
