<p align="center">
  <img src="assets/icon-1024.png" width="128" height="128" alt="Mado icon">
</p>

<h1 align="center">Mado(窓)</h1>

<p align="center">
  Mac 専用の軽量 Markdown ビューア。<br>
  爆速起動・高速レンダリング・ライブリロード。Mermaid / OpenAPI もそのまま美しく。
</p>

<p align="center">
  <a href="https://github.com/fuwasegu/mado/releases/latest">Download</a>
</p>

## インストール

```bash
brew tap fuwasegu/tap
brew install --cask mado
```

## 特徴

- **ネイティブシェル**: SwiftUI + WKWebView。Electron 不使用で起動は一瞬
- **美しいレンダリング**: markdown-it + highlight.js + Mermaid(全てローカルバンドル、オフライン動作)
- **ライブリロード**: FSEvents による再帰監視。Claude Code がターミナルから書いた変更を即反映
- **チラつかない更新**: morphdom による DOM 差分パッチ。スクロール位置と描画済み Mermaid 図(SVG キャッシュ)を保持
- **エディタライクなサイドバー**: ディレクトリツリー表示、トグル可(⌘⌥S / ツールバー)
- ダーク/ライトモード自動追従(Mermaid テーマも切替)
- GitHub アラート(`> [!NOTE]` 等)、タスクリスト、front matter 折りたたみ表示
- コードブロックの言語バッジ + ホバーでコピーボタン
- 相対リンクの `.md` はアプリ内遷移、外部リンクはブラウザで開く
- **Markdown 以外も表示可能**:
  - `.json` / `.yaml` / `.yml` — シンタックスハイライト付き全文表示(1行に潰された JSON は自動整形)
  - `.mermaid` / `.mmd` — ファイル全体を図としてレンダリング
  - `.csv` / `.tsv` — sticky ヘッダ+行番号付きテーブル表示(RFC4180 準拠: クォート・セル内改行対応)
- **OpenAPI ドキュメントモード** — `.yaml`/`.json` の先頭に `openapi:`/`swagger:` キーがあれば自動で Redoc 表示(送信機能なしのリファレンス UI)。右下のボタンでソース表示と切替
  - OpenAPI 3.1 対応(webhooks 含む)、Redoc 2.5 をローカルバンドル
  - **外部ファイル $ref を解決**: `./schemas/common.yaml#/...` 形式を Swift ブリッジ経由で読み込み、循環参照は内部 $ref に変換してバンドル
  - Redoc(1.1MB)は OpenAPI ファイルを開いた時のみ遅延ロード(Markdown 表示速度に影響なし)
- **⌘F 文字列検索** — CSS Custom Highlight API 使用。DOM を変更せずハイライトするため巨大文書でも高速(337KB / 2346 マッチで 49ms)。↩ / ⇧↩ / ⌘G で移動、esc で閉じる

## ビルドと実行

```bash
# 開発実行(フォルダ指定可)
swift run Mado ~/path/to/docs

# .app バンドルを作成
./scripts/build-app.sh
cp -R build/Mado.app /Applications/

# インストール後にターミナルから開く
open -a Mado ~/path/to/docs
```

> [!WARNING]
> `open -n App.app --args <path>` という渡し方だけは使わないこと。
> AppKit が argv のパスを起動時の「ファイルを開く」イベントに変換し、
> SwiftUI が初期ウィンドウを生成しなくなる(プロセスは起動するがウィンドウが出ない)。
> 直接実行(`swift run` / バイナリ直叩き)と `open -a App <path>` は正常。

### 検証ハーネス

```bash
# ヘッドレス WKWebView でレンダリング検証(Mermaid/ハイライト/構造チェック + スナップショット)
swift scripts/render-test.swift Samples/README.md /tmp/out.png

# 差分更新の検証(スクロール位置・描画済み Mermaid SVG ノードの保持)
swift scripts/rerender-test.swift Samples/README.md

# OpenAPI モードの検証(Redoc 描画・外部/循環 $ref 解決)
swift scripts/openapi-test.swift Samples/api/petstore.yaml /tmp/api.png
```

## 操作

| キー | 動作 |
|------|------|
| ⌘O | フォルダを開く |
| ⌘R | 強制リロード |
| ⌘F | 文書内検索(↩ 次へ / ⇧↩ 前へ / esc 閉じる) |
| ⌘⌥S | サイドバー トグル |

## パフォーマンス指標(実測)

| 項目 | 実測値 |
|------|--------|
| 起動 → ウィンドウ表示 | ~0.4s(リリースビルド) |
| 337KB Markdown(コード120 + テーブル120)のレンダリング | 33ms |
| 2346 件マッチの全文検索 + ハイライト | 49ms |
| ファイル再描画時の Mermaid | ソース不変ならキャッシュ命中で 0ms(SVG ノード保持) |

パーサの WASM 化(MoonBit / Rust 等)は検討の上**見送り**。レンダリング総時間 33ms のうち
markdown-it のパース自体は数 ms で支配項ではなく、実際のボトルネックは WebKit のレイアウトと
Mermaid の図描画(どちらも WASM では速くならない)。JS↔WASM の文字列往復コストを考えると
現状の規模では逆効果になり得る。ファイル切替時は morphdom をスキップして innerHTML 一括差し替え、
巨大ファイル(>400KB)はハイライトをスキップ、CSV は 5000 行でキャップ、という工夫で対応している。

起動時は空の状態で始まる。CLI 引数や `open -a Mado <path>` でパスを渡したときだけそれを開く。

## 構成

```
Sources/Mado/
├── MarkdownViewerApp.swift   # エントリポイント
├── AppState.swift            # フォルダ/選択/監視の状態管理
├── ContentView.swift         # NavigationSplitView + サイドバー
├── MarkdownWebView.swift     # WKWebView ブリッジ
├── FileNode.swift            # ツリー走査(.md を含むサブツリーのみ)
├── FSEventsWatcher.swift     # 再帰ファイル監視
└── Resources/
    ├── template.html / style.css / viewer.js
    └── vendor/               # markdown-it, highlight.js, mermaid, morphdom
```
