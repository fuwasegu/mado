# Mado 検索 評価スイート

検索精度を回帰なく改善するための固定評価セット。自律改善ループはこれを基準に判定する。

## 実行

```bash
swift build   # release 版レイテンシは: swift build -c release && .build/release/Mado ...

# 意味クエリ(語彙を外した自然文40件・本丸)
.build/debug/Mado --eval eval/zenn-corpus eval/semantic_queries.json

# 既知アイテム(title/heading/sentence 490件・退行防止)
.build/debug/Mado --eval eval/zenn-corpus eval/queries_auto.json
```

各クエリを lexical / semantic / hybrid の3モードで走らせ、記事単位の Recall@1/5/10・MRR@10・レイテンシを出力する。

## 中身

- `zenn-corpus/` — zenn/mizchi 最新100記事(**再配布回避のため gitignore**。`tools/fetch_zenn.py` で再取得)。677K字 / 1019 chunks。
- `semantic_queries.json` — 手作りの意味クエリ40件(**調整用**。過学習回避のため最終判定は held-out で行う)。
- `queries_auto.json` — 自動生成の既知アイテムクエリ490件。
- `eval-baseline.md` — 測定履歴(サイクルごとに追記)。
- `tools/fetch_zenn.py`, `tools/gen_queries.py` — コーパス/クエリ再生成スクリプト(要 Python venv + requests/markdownify)。

## 終了条件(goal)

意味クエリ(held-out, hybrid): R@1≥0.75 / R@5≥0.93 / R@10≥0.95 / MRR≥0.82。
既知アイテム退行なし、全文検索比 R@10≥10倍、hybrid≥各単独信号、p50≤30ms/p95≤80ms(release)。
