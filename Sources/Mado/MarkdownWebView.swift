import SwiftUI
import WebKit

/// Markdown レンダリング面。WKWebView を1枚だけ生成し、
/// 以降の更新は JS 呼び出し(差分パッチ)のみで行う。
struct MarkdownWebView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.renderIfNeeded(
            path: state.selectedFile,
            content: state.currentContent
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply,
        WKNavigationDelegate {
        private let state: AppState
        private var webView: WKWebView?
        private var isReady = false
        private var lastRenderedPath: String?
        private var lastRenderedContent: String?
        private var pending: (path: URL, content: String)?
        private var findObserver: NSObjectProtocol?
        private var navObserver: NSObjectProtocol?
        /// レンダリング完了後に適用する検索結果のジャンプ先(見出し slug + ハイライト語 + 意味フレーズ)。
        private var pendingAnchor: String?
        private var pendingTerms: [String] = []
        private var pendingPhrase: String = ""

        init(state: AppState) {
            self.state = state
        }

        deinit {
            if let findObserver {
                NotificationCenter.default.removeObserver(findObserver)
            }
            if let navObserver {
                NotificationCenter.default.removeObserver(navObserver)
            }
        }

        func makeWebView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "bridge")
            // OpenAPI の外部 $ref 解決用: JS からローカルファイルを読む(Promise で返る)
            config.userContentController.addScriptMessageHandler(
                self, contentWorld: .page, name: "readFile"
            )
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.underPageBackgroundColor = .textBackgroundColor
            webView.allowsMagnification = true
            if #available(macOS 13.3, *) {
                webView.isInspectable = true
            }
            self.webView = webView

            // object に自分の AppState を指定し、フォーカス中ウィンドウの通知だけ受ける
            findObserver = NotificationCenter.default.addObserver(
                forName: .mdvOpenFind, object: state, queue: .main
            ) { [weak webView] _ in
                webView?.evaluateJavaScript("window.__find && window.__find.open()")
            }

            // 検索結果からの遷移: 同一ファイルなら即スクロール、別ファイルなら開いてから。
            navObserver = NotificationCenter.default.addObserver(
                forName: .mdvNavigate, object: state, queue: .main
            ) { [weak self] note in
                // queue: .main で配信されるため main actor 上にいることは保証されている
                MainActor.assumeIsolated {
                    guard let self,
                          let path = note.userInfo?["path"] as? String else { return }
                    let anchor = (note.userInfo?["anchor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    self.pendingAnchor = anchor
                    self.pendingTerms = (note.userInfo?["terms"] as? [String]) ?? []
                    self.pendingPhrase = (note.userInfo?["phrase"] as? String) ?? ""
                    let url = URL(fileURLWithPath: path)
                    if self.lastRenderedPath == path {
                        self.applyPendingLocate()   // 既に表示中 → 再描画せず locate
                    } else if FileManager.default.fileExists(atPath: url.path), FileNode.isViewable(url) {
                        self.state.selectedFile = url   // 描画完了後に applyPendingLocate が走る
                    }
                }
            }

            if let templateURL = Bundle.module.url(
                forResource: "template", withExtension: "html", subdirectory: "Resources"
            ) {
                // ローカル画像をどこからでも読めるよう、読み取り許可はルートに付与(個人用ビューアのため)
                webView.loadFileURL(templateURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            }
            return webView
        }

        func renderIfNeeded(path: URL?, content: String) {
            guard let path else { return }
            if lastRenderedPath == path.path && lastRenderedContent == content { return }
            guard isReady, let webView else {
                pending = (path, content)
                return
            }
            lastRenderedPath = path.path
            lastRenderedContent = content
            var payload: [String: Any] = [
                "path": path.path,
                "dir": path.deletingLastPathComponent().path,
                "content": content,
            ]
            // 検索結果からの遷移なら、描画と同時に該当箇所へ locate(中央寄せ+ハイライト)
            if let anchor = pendingAnchor { payload["anchor"] = anchor }
            if !pendingTerms.isEmpty { payload["terms"] = pendingTerms }
            if !pendingPhrase.isEmpty { payload["phrase"] = pendingPhrase }
            webView.callAsyncJavaScript(
                "window.__render(payload)",
                arguments: ["payload": payload],
                in: nil,
                in: .page
            ) { [weak self] _ in
                // 描画後に確実に適用(payload 経由が効かなかった場合の保険)
                self?.applyPendingLocate()
            }
        }

        /// 保留中の検索ジャンプ先(見出し/一致テキスト)へ中央スクロール+ハイライトし、状態をクリアする。
        private func applyPendingLocate() {
            guard let webView, pendingAnchor != nil || !pendingTerms.isEmpty || !pendingPhrase.isEmpty else { return }
            let anchor = pendingAnchor ?? ""
            let terms = pendingTerms
            let phrase = pendingPhrase
            pendingAnchor = nil
            pendingTerms = []
            pendingPhrase = ""
            webView.callAsyncJavaScript(
                "window.__locate({ anchor: anchor, terms: terms, phrase: phrase })",
                arguments: ["anchor": anchor, "terms": terms, "phrase": phrase], in: nil, in: .page
            ) { _ in }
        }

        // MARK: - JS → Swift

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                if let p = pending {
                    pending = nil
                    renderIfNeeded(path: p.path, content: p.content)
                }
            case "openExternal":
                if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            case "openFile":
                if let pathString = body["path"] as? String {
                    let url = URL(fileURLWithPath: pathString)
                    if FileManager.default.fileExists(atPath: url.path), FileNode.isViewable(url) {
                        state.selectedFile = url
                    }
                }
            default:
                break
            }
        }

        // MARK: - JS → Swift (返信あり: OpenAPI 外部 $ref のファイル読み込み)

        private static let bridgeReadableExtensions: Set<String> = ["yaml", "yml", "json"]

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            guard message.name == "readFile",
                  let body = message.body as? [String: Any],
                  let path = body["path"] as? String else {
                replyHandler(nil, "invalid request")
                return
            }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard Self.bridgeReadableExtensions.contains(url.pathExtension.lowercased()) else {
                replyHandler(nil, "extension not allowed: \(url.lastPathComponent)")
                return
            }
            do {
                replyHandler(try String(contentsOf: url, encoding: .utf8), nil)
            } catch {
                replyHandler(nil, "read failed: \(url.path)")
            }
        }
    }
}
