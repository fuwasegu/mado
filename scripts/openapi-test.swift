// OpenAPI ドキュメントモードの検証ハーネス
// - Redoc の DOM が生成されること
// - 外部ファイル $ref が完全に解決されること(バンドル後スペックに外部参照が残らない)
// 使い方: swift scripts/openapi-test.swift <spec.yaml> <output.png>
import AppKit
import WebKit

let specPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let projectRoot = FileManager.default.currentDirectoryPath
let templateURL = URL(fileURLWithPath: projectRoot)
    .appendingPathComponent("Sources/Mado/Resources/template.html")

let content = try! String(contentsOfFile: specPath, encoding: .utf8)
let specURL = URL(fileURLWithPath: specPath).resolvingSymlinksInPath()

final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 2400), configuration: config)
        super.init()
        // アプリ本体と同じ readFile ブリッジ
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "readFile")
        webView.navigationDelegate = self
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func userContentController(
        _ ucc: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let path = body["path"] as? String else {
            replyHandler(nil, "invalid request")
            return
        }
        do {
            replyHandler(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), nil)
        } catch {
            replyHandler(nil, "read failed: \(path)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(
            "return window.__render(payload)",
            arguments: ["payload": [
                "path": specURL.path,
                "dir": specURL.deletingLastPathComponent().path,
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
                print("RENDER: \((value as? [String: Any]) ?? [:])")
            }
            // Redoc の遅延ロード + 描画を待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.inspect() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("NAV FAILED: \(error)")
        exit(1)
    }

    func inspect() {
        let js = """
        (() => {
            const spec = JSON.stringify(window.__lastBundledSpec || {});
            return JSON.stringify({
                redocRendered: !!document.querySelector('#redoc-root .api-content'),
                menuItems: document.querySelectorAll('#redoc-root [role="menuitem"]').length,
                operations: (spec.match(/"operationId"/g) || []).length,
                externalRefsLeft: (spec.match(/\\.ya?ml#|\\.json#/g) || []).length,
                hasPageToken: spec.includes('pageToken'),
                errorDetailInlined: spec.includes('"reason"'),
                circularInlined: spec.includes('循環参照を含むカテゴリツリー'), cycleAsInternalRef: /"\\$ref":"#\\//.test(spec),
                parseError: document.querySelector('.openapi-error')?.textContent || null,
                toggleVisible: !document.getElementById('api-toggle').hidden
            });
        })()
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error { print("INSPECT FAILED: \(error)"); exit(1) }
            print("INSPECT: \(result as? String ?? "nil")")
            self.styleCheck()
        }
    }

    // ダークモードで h5 (QUERY PARAMETERS 等) が読める色になっているか
    func styleCheck() {
        let js = """
        (() => {
            const h5 = document.querySelector('#redoc-root h5');
            return JSON.stringify({
                h5Color: h5 ? getComputedStyle(h5).color : null,
                darkMode: matchMedia('(prefers-color-scheme: dark)').matches,
            });
        })()
        """
        webView.evaluateJavaScript(js) { result, error in
            print("STYLE: \(result as? String ?? "nil")")
            self.toggleTest()
        }
    }

    // ソース表示 ⇄ ドキュメント表示の切替が機能するか
    func toggleTest() {
        webView.evaluateJavaScript("document.getElementById('api-toggle').click()") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let js = """
                JSON.stringify({
                    sourceShown: !!document.querySelector('#content .code-block.file-view'),
                    redocGone: !document.querySelector('#redoc-root'),
                    hljsSpans: document.querySelectorAll('#content pre code span[class*="hljs"]').length,
                })
                """
                self.webView.evaluateJavaScript(js) { result, _ in
                    print("TOGGLE→SOURCE: \(result as? String ?? "nil")")
                    self.webView.evaluateJavaScript("document.getElementById('api-toggle').click()") { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.webView.evaluateJavaScript(
                                "JSON.stringify({redocBack: !!document.querySelector('#redoc-root .api-content')})"
                            ) { result, _ in
                                print("TOGGLE→DOC: \(result as? String ?? "nil")")
                                self.snapshot()
                            }
                        }
                    }
                }
            }
        }
    }

    func snapshot() {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(x: 0, y: 0, width: 1400, height: 2400)
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
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    print("TIMEOUT")
    exit(1)
}
RunLoop.main.run()
