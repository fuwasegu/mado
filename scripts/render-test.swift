// ヘッドレス WKWebView でレンダリングパイプラインを検証するハーネス
// 使い方: swift scripts/render-test.swift <markdown-file> <output.png>
import AppKit
import WebKit

let mdPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let projectRoot = FileManager.default.currentDirectoryPath
let templateURL = URL(fileURLWithPath: projectRoot)
    .appendingPathComponent("Sources/Mado/Resources/template.html")

let content = try! String(contentsOfFile: mdPath, encoding: .utf8)
let mdURL = URL(fileURLWithPath: mdPath)

final class Harness: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var done = false

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 2800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(
            "return window.__render(payload)",
            arguments: ["payload": [
                "path": mdURL.path,
                "dir": mdURL.deletingLastPathComponent().path,
                "content": content,
            ]],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .failure(let err):
                print("RENDER CALL FAILED: \(err)")
                exit(1)
            case .success(let value):
                let ms = (value as? [String: Any])?["ms"] ?? "?"
                print("RENDER: \(ms)ms")
            }
            // mermaid の非同期描画を待ってから検査
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.inspect() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("NAV FAILED: \(error)")
        exit(1)
    }

    func inspect() {
        let js = """
        JSON.stringify({
            h1: document.querySelector('h1')?.textContent || null,
            codeBlocks: document.querySelectorAll('.code-block pre code').length,
            hljsSpans: document.querySelectorAll('pre code span[class*="hljs"]').length,
            mermaidTotal: document.querySelectorAll('.mermaid').length,
            mermaidSvg: document.querySelectorAll('.mermaid svg').length,
            mermaidErrors: document.querySelectorAll('.mermaid-error').length,
            tables: document.querySelectorAll('table').length,
            taskCheckboxes: document.querySelectorAll('.task-list-item input').length,
            alerts: document.querySelectorAll('blockquote.alert').length,
            headingIds: document.querySelectorAll('h2[id]').length,
            dataRows: document.querySelectorAll('.data-table tbody tr').length,
            dataCols: document.querySelectorAll('.data-table thead th').length,
            findBar: !!document.getElementById('findbar'),
            highlightAPI: typeof Highlight !== 'undefined' && !!CSS.highlights,
            docHeight: document.body.scrollHeight
        })
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error { print("INSPECT FAILED: \(error)"); exit(1) }
            print("INSPECT: \(result as? String ?? "nil")")
            self.snapshot()
        }
    }

    func snapshot() {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(x: 0, y: 0, width: 900, height: 2800)
        webView.takeSnapshot(with: snapConfig) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("SNAPSHOT FAILED: \(error.map(String.init(describing:)) ?? "no image")")
                exit(1)
            }
            try! png.write(to: URL(fileURLWithPath: outPath))
            print("SNAPSHOT: \(outPath)")
            exit(0)
        }
    }
}

let harness = Harness()
// タイムアウト保険
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("TIMEOUT")
    exit(1)
}
RunLoop.main.run()
