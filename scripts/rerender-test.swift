// 差分更新の検証: 同一ファイルの再レンダリングで
// - 描画済み Mermaid SVG ノードが保持される(再描画なし)
// - スクロール位置が保持される
// 使い方: swift scripts/rerender-test.swift <markdown-file>
import AppKit
import WebKit

let mdPath = CommandLine.arguments[1]
let projectRoot = FileManager.default.currentDirectoryPath
let templateURL = URL(fileURLWithPath: projectRoot)
    .appendingPathComponent("Sources/Mado/Resources/template.html")

let content = try! String(contentsOfFile: mdPath, encoding: .utf8)
let mdURL = URL(fileURLWithPath: mdPath)

func payload(_ body: String) -> [String: String] {
    ["path": mdURL.path, "dir": mdURL.deletingLastPathComponent().path, "content": body]
}

final class Harness: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        render(content) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.afterFirstRender() }
        }
    }

    func render(_ body: String, then: @escaping () -> Void) {
        webView.callAsyncJavaScript(
            "window.__render(payload)", arguments: ["payload": payload(body)], in: nil, in: .page
        ) { result in
            if case .failure(let err) = result { print("RENDER FAILED: \(err)"); exit(1) }
            then()
        }
    }

    func afterFirstRender() {
        // SVG ノードに目印を付け、スクロールしてから末尾に1行足して再レンダリング
        let js = """
        window.scrollTo(0, 800);
        document.querySelectorAll('.mermaid svg').forEach(s => s.__marker = true);
        'ok'
        """
        webView.evaluateJavaScript(js) { _, _ in
            self.render(content + "\n\n追記された段落です。\n") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.verify() }
            }
        }
    }

    func verify() {
        let js = """
        JSON.stringify({
            scrollY: window.scrollY,
            mermaidSvg: document.querySelectorAll('.mermaid svg').length,
            markersKept: [...document.querySelectorAll('.mermaid svg')].filter(s => s.__marker).length,
            appended: document.body.textContent.includes('追記された段落です')
        })
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error { print("VERIFY FAILED: \(error)"); exit(1) }
            print("VERIFY: \(result as? String ?? "nil")")
            exit(0)
        }
    }
}

let harness = Harness()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("TIMEOUT"); exit(1) }
RunLoop.main.run()
