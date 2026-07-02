import Foundation

/// MCP tools/list で公開するツール定義(JSON Schema)。
enum Tools {
    static let list: [[String: Any]] = [
        [
            "name": "search",
            "description": "Mado のドキュメントを横断検索(全文 BM25 + 意味 + 構造化フィルタの融合)。"
                + "自然文でも DSL でも可: 例 'tag:api status:draft 認証フロー' / '先月書いた認証まわりの下書き'。"
                + "結果はチャンク(見出しセクション)粒度で relPath / headingSlug / snippet を返す。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "検索クエリ(自然文 or DSL)"],
                    "limit": ["type": "integer", "description": "最大件数(既定 20)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "structured_query",
            "description": "構造化条件のみで絞り込む(全文なし)。タグ・ステータス・パス・言語・更新日時・タスク状態。"
                + "条件・時間軸の明示的な問い合わせに使う。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "status": ["type": "array", "items": ["type": "string"]],
                    "path": ["type": "string", "description": "rel_path の部分一致"],
                    "ext": ["type": "string"],
                    "lang": ["type": "array", "items": ["type": "string"], "description": "コードブロック言語"],
                    "modified_after": ["type": "string", "description": "YYYY-MM-DD / YYYY-MM / YYYY"],
                    "modified_before": ["type": "string", "description": "YYYY-MM-DD / YYYY-MM / YYYY"],
                    "is_task": ["type": "string", "enum": ["todo", "done", "any"]],
                    "limit": ["type": "integer"],
                ],
            ],
        ],
        [
            "name": "get_section",
            "description": "指定ファイルの指定見出しセクション本文を取得する。search の headingSlug をそのまま渡す。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "rel_path"],
                    "slug": ["type": "string", "description": "見出し slug(省略で先頭セクション)"],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "list_backlinks",
            "description": "指定ファイルへリンクしているファイル一覧(バックリンク)。ドキュメント間の関係を辿る。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "rel_path"],
                ],
                "required": ["path"],
            ],
        ],
    ]
}
