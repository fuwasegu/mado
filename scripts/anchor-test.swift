// 検索結果 handoff の JS 側(payload.anchor / window.__gotoAnchor)をヘッドレス検証する。
// 使い方: swift scripts/anchor-test.swift
import AppKit
import WebKit

let projectRoot = FileManager.default.currentDirectoryPath
let templateURL = URL(fileURLWithPath: projectRoot)
    .appendingPathComponent("Sources/Mado/Resources/template.html")

// 長い文書: 多数の見出し。後半の見出しへスクロールできるか見る。
var md = "# 先頭\n"
for i in 1...40 { md += "\n## セクション\(i)\n" + String(repeating: "本文行。\n", count: 8) }
md += "\n## 認証フロー\nここが目的地。\n" + String(repeating: "末尾。\n", count: 20)
let targetSlug = "認証フロー"   // slugify('認証フロー')

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print((cond ? "  ✓ " : "  ✗ ") + label); if !cond { failures += 1 }
}

final class Harness: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
        // 1) payload.anchor + terms でレンダリング → 一致テキストを中央に寄せてハイライトするはず
        webView.callAsyncJavaScript(
            "return window.__render(payload)",
            arguments: ["payload": ["path": "/tmp/anchor.md", "dir": "/tmp", "content": md,
                                    "anchor": targetSlug, "terms": ["目的地"]]],
            in: nil, in: .page
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.checkScrolledDown() }
        }
    }

    func checkScrolledDown() {
        webView.evaluateJavaScript("JSON.stringify({y: window.scrollY, hasLocate: typeof window.__locate === 'function', flashWrap: !!document.querySelector('.mdv-flash[data-mdv-wrap=\"1\"]'), flashText: document.querySelector('.mdv-flash')?.textContent || ''})") { result, _ in
            let s = result as? String ?? "{}"
            let data = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
            let y = (data["y"] as? NSNumber)?.doubleValue ?? 0
            check(data["hasLocate"] as? Bool == true, "window.__locate が存在する")
            check(y > 100, "一致テキストへ中央スクロールした (scrollY=\(Int(y)))")
            check(data["flashWrap"] as? Bool == true, "一致テキストが span で包まれてハイライトされる")
            check((data["flashText"] as? String)?.contains("目的地") == true, "ハイライト対象が一致語(目的地)")
            self.checkGotoTop()
        }
    }

    func checkGotoTop() {
        // 2) 先頭へ戻し、__gotoAnchor で再度ジャンプできるか
        webView.evaluateJavaScript("window.scrollTo(0,0);") { _, _ in
            self.webView.callAsyncJavaScript("window.__gotoAnchor(slug); return true;",
                arguments: ["slug": targetSlug], in: nil, in: .page) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.webView.evaluateJavaScript("window.scrollY") { r, _ in
                        let y = (r as? NSNumber)?.doubleValue ?? 0
                        check(y > 100, "__gotoAnchor で再ジャンプできた (scrollY=\(Int(y)))")
                        self.checkPhrase()
                    }
                }
            }
        }
    }

    func checkPhrase() {
        // 3) 一致語が無い意味ヒットは phrase(最類似セグメントの文片)で着地できるか
        webView.evaluateJavaScript("window.scrollTo(0,0);") { _, _ in
            self.webView.callAsyncJavaScript(
                "window.__locate({ anchor: slug, terms: ['存在しない語XYZ'], phrase: 'ここが目的地' }); return true;",
                arguments: ["slug": targetSlug], in: nil, in: .page) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.webView.evaluateJavaScript("JSON.stringify({y: window.scrollY, text: document.querySelector('.mdv-flash')?.textContent || ''})") { r, _ in
                        let s = r as? String ?? "{}"
                        let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
                        let y = (d["y"] as? NSNumber)?.doubleValue ?? 0
                        check(y > 100, "phrase で着地できた (scrollY=\(Int(y)))")
                        check((d["text"] as? String)?.contains("目的地") == true, "phrase の実文がハイライトされる")
                        print(failures == 0 ? "\nANCHOR TEST: PASS ✅" : "\nANCHOR TEST: \(failures) FAIL ❌")
                        exit(failures == 0 ? 0 : 1)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        print("NAV FAILED: \(error)"); exit(1)
    }
}

let harness = Harness()
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("TIMEOUT"); exit(1) }
RunLoop.main.run()
