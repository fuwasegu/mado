import Foundation
import SearchCore

/// 最小限の MCP サーバ実装(JSON-RPC 2.0 / newline-delimited / stdio)。
final class MCPServer {
    private let root: URL
    private let store: IndexStore
    private let semantic: SemanticStore
    private let query: QueryService
    private let stdout = FileHandle.standardOutput

    init(root: URL) {
        self.root = root
        let path = IndexLocation.url(forRoot: root).path
        // 書き込みは best-effort: アプリが同じ index を書いている最中(単一 writer 規約)や
        // 権限問題で RW を握れない場合は read-only にフォールバックし、検索だけは必ず提供する。
        var opened: IndexStore?
        var writable = ProcessInfo.processInfo.environment["MADO_MCP_READONLY"] != "1"
        if writable {
            do {
                let rw = try IndexStore(path: path)
                // 起動時に同期(アプリ未起動でも自己完結する)。ログは stderr へ。
                let stats = try Indexer.reconcile(root: root, store: rw, nowEpoch: Date().timeIntervalSince1970)
                MCPServer.log("reconcile +\(stats.added) ~\(stats.updated) -\(stats.removed) =\(stats.skipped)")
                opened = rw
            } catch {
                MCPServer.log("write path unavailable (\(error)) → read-only fallback")
                writable = false
            }
        }
        if opened == nil {
            do {
                opened = try IndexStore(path: path, readOnly: true)
            } catch {
                FileHandle.standardError.write(Data("index open failed: \(error)\n".utf8))
                exit(1)
            }
        }
        store = opened!
        let embedder: Embedder = {
            let e5 = CoreMLEmbedder()
            return e5.isAvailable ? e5 : NLEmbedder(language: .japanese)
        }()
        semantic = SemanticStore(store: store, embedder: embedder)
        if writable {
            if (try? store.embedModelID()) != embedder.identifier {
                try? store.clearAllVectors(); try? store.setEmbedModelID(embedder.identifier)
            }
            if let n = try? semantic.embedPending(), n > 0 { MCPServer.log("embedded \(n) chunks") }
        }
        query = QueryService(store: store, semantic: semantic)
        MCPServer.log("ready\(writable ? "" : " (read-only)"): \(root.path)  files=\((try? store.fileCount()) ?? 0) vectors=\((try? store.vectorCount()) ?? 0)")
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("[MadoSearchMCP] \(s)\n".utf8)) }

    // MARK: ループ

    func run() {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }
            handle(data)
        }
    }

    private func handle(_ data: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = msg["method"] as? String else { return }
        let id = msg["id"]   // 無い = 通知(応答しない)
        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "mado-search", "version": "0.1.0"],
            ])
        case "notifications/initialized", "initialized":
            break
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": Tools.list])
        case "tools/call":
            handleToolCall(id, msg["params"] as? [String: Any] ?? [:])
        default:
            if id != nil { replyError(id, -32601, "method not found: \(method)") }
        }
    }

    // MARK: tools/call

    private func handleToolCall(_ id: Any?, _ params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "search":          toolSearch(id, args)
        case "structured_query": toolStructured(id, args)
        case "get_section":     toolGetSection(id, args)
        case "list_backlinks":  toolBacklinks(id, args)
        default:                replyError(id, -32602, "unknown tool: \(name)")
        }
    }

    private func toolSearch(_ id: Any?, _ args: [String: Any]) {
        let q = args["query"] as? String ?? ""
        let limit = (args["limit"] as? Int) ?? 20
        let hits = query.search(q, limit: limit)
        replyContent(id, jsonText(hits.map(hitDict)))
    }

    private func toolStructured(_ id: Any?, _ args: [String: Any]) {
        var f = QueryFilters()
        f.tags = stringArray(args["tags"])
        f.status = stringArray(args["status"])
        f.langs = stringArray(args["lang"]) + stringArray(args["langs"])
        if let p = args["path"] as? String { f.pathContains = [p] }
        if let e = args["ext"] as? String { f.exts = [e.lowercased()] }
        if let a = args["modified_after"] as? String, let d = isoDate(a) { f.modifiedAfter = d }
        if let b = args["modified_before"] as? String, let d = isoDate(b) { f.modifiedBefore = d }
        switch (args["is_task"] as? String)?.lowercased() {
        case "todo", "open": f.taskState = .todo
        case "done": f.taskState = .done
        case "any", "true": f.taskState = .any
        default: break
        }
        let limit = (args["limit"] as? Int) ?? 50
        let rows = (try? store.search(matchExpr: nil, filters: f, limit: limit)) ?? []
        let out = rows.map { row -> [String: Any] in
            ["relPath": row.relPath, "title": row.title,
             "headingPath": row.headingPath, "headingSlug": row.headingSlug,
             "snippet": String(row.text.prefix(200))]
        }
        replyContent(id, jsonText(out))
    }

    private func toolGetSection(_ id: Any?, _ args: [String: Any]) {
        guard let path = args["path"] as? String else { return replyError(id, -32602, "path required") }
        let slug = args["slug"] as? String
        let row = (try? store.section(relPath: path, slug: slug)).flatMap { $0 }
        if let row {
            replyContent(id, "# \(row.headingPath.isEmpty ? row.title : row.headingPath)\n\n\(row.text)")
        } else {
            replyContent(id, "(section not found: \(path)#\(slug ?? ""))")
        }
    }

    private func toolBacklinks(_ id: Any?, _ args: [String: Any]) {
        guard let path = args["path"] as? String else { return replyError(id, -32602, "path required") }
        let links = (try? store.backlinks(toRelPath: path)) ?? []
        let out = links.map { ["relPath": $0.relPath, "title": $0.title, "anchor": $0.anchor ?? ""] }
        replyContent(id, jsonText(out))
    }

    // MARK: 整形

    private func hitDict(_ h: SearchHit) -> [String: Any] {
        ["relPath": h.relPath, "title": h.title, "headingPath": h.headingPath,
         "headingSlug": h.headingSlug, "snippet": h.snippet,
         "kinds": h.kinds.map { $0.rawValue }.sorted(),
         "score": (h.score * 10000).rounded() / 10000]
    }

    private func stringArray(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String { return [s] }
        return []
    }

    private func isoDate(_ s: String) -> Double? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current
        for fmt in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }

    private func jsonText(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // MARK: JSON-RPC 応答

    private func replyContent(_ id: Any?, _ text: String) {
        reply(id, ["content": [["type": "text", "text": text]]])
    }

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }   // 通知には応答しない
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any?, _ code: Int, _ message: String) {
        guard let id else { return }
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        stdout.write(data)
        stdout.write(Data("\n".utf8))
    }
}
