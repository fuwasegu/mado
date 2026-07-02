import Foundation
import SQLite3

public enum IndexError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)
    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .sql(let m): return "sqlite error: \(m)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 全文・構造化インデックスの SQLite ストア。
/// スレッド安全ではない(呼び出し側で直列化する。アプリは actor、MCP は単一スレッド)。
public final class IndexStore {
    private var db: OpaquePointer?
    public static let schemaVersion = 2   // v2: segment_vectors.text(ベストセグメント本文)

    /// 1 件のレキシカル検索結果(チャンク粒度)。
    public struct LexicalRow: Sendable {
        public var chunkId: Int64
        public var fileId: Int64
        public var bm25: Double
        public var path: String
        public var relPath: String
        public var title: String
        public var headingSlug: String
        public var headingPath: String
        public var text: String
    }

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            throw IndexError.open(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 3000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
            try migrate()
        }
    }

    deinit { if db != nil { sqlite3_close(db) } }

    // MARK: 低レベルヘルパ

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw IndexError.sql(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw IndexError.sql("prepare: \(String(cString: sqlite3_errmsg(db))) [\(sql.prefix(80))]")
        }
        return stmt!
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    // MARK: スキーマ

    private func tableExists(_ name: String) throws -> Bool {
        let s = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;")
        defer { sqlite3_finalize(s) }
        bindText(s, 1, name)
        return sqlite3_step(s) == SQLITE_ROW
    }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        let s = try prepare("SELECT 1 FROM pragma_table_info(?) WHERE name=?;")
        defer { sqlite3_finalize(s) }
        bindText(s, 1, table); bindText(s, 2, column)
        return sqlite3_step(s) == SQLITE_ROW
    }

    private func migrate() throws {
        // v1 → v2: segment_vectors に text 列を追加。旧テーブルは作り直す(ベクトルは背景で再生成)。
        if try tableExists("segment_vectors"), !(try columnExists("segment_vectors", "text")) {
            try exec("DROP TABLE IF EXISTS segment_vectors;")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);

        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE NOT NULL,
            rel_path TEXT NOT NULL,
            dir TEXT NOT NULL,
            ext TEXT NOT NULL,
            mtime REAL NOT NULL,
            size INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            title TEXT NOT NULL,
            indexed_at REAL NOT NULL,
            doc_date REAL NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS frontmatter(
            file_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_fm_kv ON frontmatter(key, value);
        CREATE INDEX IF NOT EXISTS idx_fm_file ON frontmatter(file_id);

        CREATE TABLE IF NOT EXISTS headings(
            file_id INTEGER NOT NULL, level INTEGER, text TEXT, slug TEXT, line INTEGER, path_text TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_h_file ON headings(file_id);

        CREATE TABLE IF NOT EXISTS links(
            src_file_id INTEGER NOT NULL, target_path TEXT, target_rel TEXT,
            target_file_id INTEGER, anchor TEXT, kind TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_links_src ON links(src_file_id);
        CREATE INDEX IF NOT EXISTS idx_links_tgt ON links(target_file_id);

        CREATE TABLE IF NOT EXISTS tasks(
            file_id INTEGER NOT NULL, checked INTEGER, text TEXT, line INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_file ON tasks(file_id);

        CREATE TABLE IF NOT EXISTS code_blocks(
            file_id INTEGER NOT NULL, lang TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_cb_file ON code_blocks(file_id);

        CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL,
            heading_slug TEXT, heading_path TEXT,
            text TEXT, ngram TEXT, start_line INTEGER, end_line INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);

        -- 意味検索は段落/文(セグメント)単位で埋め込む(1 チャンクに複数ベクトル)。
        -- 長い節を丸ごと平均するとベクトルがぼやけるため、細かい単位で持ち検索時に最大類似を採る。
        -- text = セグメント原文(意味ヒットのスニペット/着地に使う。埋め込み入力の文脈前置は含まない)
        CREATE TABLE IF NOT EXISTS segment_vectors(
            chunk_id INTEGER NOT NULL, seg INTEGER NOT NULL, dim INTEGER, vec BLOB, text TEXT,
            PRIMARY KEY(chunk_id, seg)
        );
        CREATE INDEX IF NOT EXISTS idx_seg_chunk ON segment_vectors(chunk_id);

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_chunks USING fts5(
            ngram, content='chunks', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO fts_chunks(rowid, ngram) VALUES (new.id, new.ngram);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO fts_chunks(fts_chunks, rowid, ngram) VALUES('delete', old.id, old.ngram);
        END;
        """)
        try exec("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '\(Self.schemaVersion)');")
    }

    public func setRoot(_ path: String) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES ('root', ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        _ = sqlite3_step(stmt)
    }

    // MARK: reconcile 用クエリ

    /// path → content_hash の対応(差分判定用)。
    public func hashes() throws -> [String: String] {
        let stmt = try prepare("SELECT path, content_hash FROM files;")
        defer { sqlite3_finalize(stmt) }
        var map: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            map[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return map
    }

    // MARK: ベクトル(意味検索)

    /// チャンクのセグメント(ベクトル+原文)群を保存(既存を置き換え)。空なら「処理済み」の番兵行。
    public func setSegments(chunkId: Int64, segments: [(vec: [Float], text: String)]) throws {
        let del = try prepare("DELETE FROM segment_vectors WHERE chunk_id=?;")
        sqlite3_bind_int64(del, 1, chunkId); _ = sqlite3_step(del); sqlite3_finalize(del)
        if segments.isEmpty {
            let s = try prepare("INSERT INTO segment_vectors(chunk_id, seg, dim, vec, text) VALUES (?,0,0,x'',NULL);")
            sqlite3_bind_int64(s, 1, chunkId); _ = sqlite3_step(s); sqlite3_finalize(s)
            return
        }
        for (i, segment) in segments.enumerated() {
            let s = try prepare("INSERT INTO segment_vectors(chunk_id, seg, dim, vec, text) VALUES (?,?,?,?,?);")
            sqlite3_bind_int64(s, 1, chunkId)
            sqlite3_bind_int(s, 2, Int32(i))
            sqlite3_bind_int(s, 3, Int32(segment.vec.count))
            segment.vec.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(s, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
            bindText(s, 5, segment.text)
            _ = sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// ベストセグメントの原文(意味ヒットのスニペット/着地用)。
    public func segmentText(chunkId: Int64, seg: Int32) throws -> String? {
        let s = try prepare("SELECT text FROM segment_vectors WHERE chunk_id=? AND seg=?;")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, chunkId)
        sqlite3_bind_int(s, 2, seg)
        guard sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: c)
    }

    /// まだベクトル化されていないチャンク(id, text, context)を取得。
    /// context = 記事タイトル + 見出し breadcrumb(埋め込みに話題語を載せるため)。
    public func chunksMissingVectors(limit: Int) throws -> [(id: Int64, text: String, context: String)] {
        let s = try prepare("""
            SELECT c.id, c.text, c.heading_path, f.title FROM chunks c
            JOIN files f ON f.id = c.file_id
            LEFT JOIN segment_vectors v ON v.chunk_id = c.id
            WHERE v.chunk_id IS NULL LIMIT ?;
            """)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(limit))
        var out: [(Int64, String, String)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(s, 1))
            let hpath = sqlite3_column_text(s, 2).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(s, 3).map { String(cString: $0) } ?? ""
            let context = hpath.isEmpty ? title : "\(title) ▸ \(hpath)"
            out.append((sqlite3_column_int64(s, 0), text, context))
        }
        return out
    }

    /// 全セグメントベクトルをメモリへロード(brute-force cosine 用、1 チャンクに複数、file_id/seg 付き)。
    public func allVectors() throws -> [(chunkId: Int64, fileId: Int64, seg: Int32, vec: [Float])] {
        let s = try prepare("""
            SELECT v.chunk_id, c.file_id, v.seg, v.dim, v.vec FROM segment_vectors v
            JOIN chunks c ON c.id = v.chunk_id WHERE v.dim > 0;
            """)
        defer { sqlite3_finalize(s) }
        var out: [(Int64, Int64, Int32, [Float])] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let id = sqlite3_column_int64(s, 0)
            let fid = sqlite3_column_int64(s, 1)
            let seg = sqlite3_column_int(s, 2)
            let dim = Int(sqlite3_column_int(s, 3))
            guard dim > 0, let blob = sqlite3_column_blob(s, 4) else { continue }
            let bytes = Int(sqlite3_column_bytes(s, 4))
            guard bytes == dim * MemoryLayout<Float>.size else { continue }
            let buf = UnsafeRawBufferPointer(start: blob, count: bytes)
            out.append((id, fid, seg, Array(buf.bindMemory(to: Float.self))))
        }
        return out
    }

    public func vectorCount() throws -> Int {
        let s = try prepare("SELECT COUNT(DISTINCT chunk_id) FROM segment_vectors WHERE dim > 0;")
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    /// まだ埋め込まれていないチャンク数(進捗表示用)。
    public func pendingVectorCount() throws -> Int {
        let s = try prepare("""
            SELECT COUNT(*) FROM chunks c
            LEFT JOIN segment_vectors v ON v.chunk_id = c.id WHERE v.chunk_id IS NULL;
            """)
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    /// 埋め込みモデルが変わった場合に既存ベクトルを破棄する(次元/意味空間が変わるため)。
    public func embedModelID() throws -> String? {
        let s = try prepare("SELECT value FROM meta WHERE key='embed_model';")
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? String(cString: sqlite3_column_text(s, 0)) : nil
    }
    public func setEmbedModelID(_ id: String) throws {
        let s = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES ('embed_model', ?);")
        defer { sqlite3_finalize(s) }
        bindText(s, 1, id); _ = sqlite3_step(s)
    }
    public func clearAllVectors() throws {
        try exec("DELETE FROM segment_vectors;")
    }

    /// チャンク行を取得(意味検索ヒットの整形に使う)。
    public func chunkRows(ids: [Int64]) throws -> [Int64: LexicalRow] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let s = try prepare("""
            SELECT c.id, c.file_id, 0.0, f.path, f.rel_path, f.title,
                   c.heading_slug, c.heading_path, c.text
            FROM chunks c JOIN files f ON f.id = c.file_id
            WHERE c.id IN (\(placeholders));
            """)
        defer { sqlite3_finalize(s) }
        for (i, id) in ids.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), id) }
        var map: [Int64: LexicalRow] = [:]
        for row in try collectRows(s) { map[row.chunkId] = row }
        return map
    }

    /// 指定ファイルの指定見出しセクション本文を返す(slug 省略で先頭/全文の代表)。
    public func section(relPath: String, slug: String?) throws -> LexicalRow? {
        let sql: String
        if let slug, !slug.isEmpty {
            sql = """
            SELECT c.id, c.file_id, 0.0, f.path, f.rel_path, f.title, c.heading_slug, c.heading_path, c.text
            FROM chunks c JOIN files f ON f.id=c.file_id
            WHERE f.rel_path=? AND c.heading_slug=? LIMIT 1;
            """
        } else {
            sql = """
            SELECT c.id, c.file_id, 0.0, f.path, f.rel_path, f.title, c.heading_slug, c.heading_path, c.text
            FROM chunks c JOIN files f ON f.id=c.file_id
            WHERE f.rel_path=? ORDER BY c.start_line LIMIT 1;
            """
        }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        bindText(s, 1, relPath)
        if let slug, !slug.isEmpty { bindText(s, 2, slug) }
        return try collectRows(s).first
    }

    public struct Backlink: Sendable {
        public var relPath: String
        public var title: String
        public var anchor: String?
    }

    /// 指定ファイルへリンクしているファイル一覧(バックリンク)。
    public func backlinks(toRelPath relPath: String) throws -> [Backlink] {
        let s = try prepare("""
            SELECT src.rel_path, src.title, l.anchor
            FROM links l
            JOIN files tgt ON tgt.rel_path = ?
            JOIN files src ON src.id = l.src_file_id
            WHERE l.target_file_id = tgt.id
            ORDER BY src.rel_path;
            """)
        defer { sqlite3_finalize(s) }
        bindText(s, 1, relPath)
        var out: [Backlink] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let anchor = sqlite3_column_text(s, 2).map { String(cString: $0) }
            out.append(Backlink(relPath: String(cString: sqlite3_column_text(s, 0)),
                                title: String(cString: sqlite3_column_text(s, 1)),
                                anchor: anchor))
        }
        return out
    }

    public func hash(forPath path: String) throws -> String? {
        let stmt = try prepare("SELECT content_hash FROM files WHERE path = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        return sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
    }

    public func fileCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM files;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func chunkCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM chunks;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: 書き込み

    public func deleteFile(path: String) throws {
        let idStmt = try prepare("SELECT id FROM files WHERE path = ?;")
        bindText(idStmt, 1, path)
        var fileId: Int64?
        if sqlite3_step(idStmt) == SQLITE_ROW { fileId = sqlite3_column_int64(idStmt, 0) }
        sqlite3_finalize(idStmt)
        guard let fid = fileId else { return }
        try deleteDependents(fileId: fid)
        let del = try prepare("DELETE FROM files WHERE id = ?;")
        defer { sqlite3_finalize(del) }
        sqlite3_bind_int64(del, 1, fid)
        _ = sqlite3_step(del)
    }

    private func deleteDependents(fileId: Int64) throws {
        for table in ["frontmatter", "headings", "tasks", "code_blocks"] {
            let s = try prepare("DELETE FROM \(table) WHERE file_id = ?;")
            sqlite3_bind_int64(s, 1, fileId)
            _ = sqlite3_step(s); sqlite3_finalize(s)
        }
        // links は src_file_id 列
        let lk = try prepare("DELETE FROM links WHERE src_file_id = ?;")
        sqlite3_bind_int64(lk, 1, fileId); _ = sqlite3_step(lk); sqlite3_finalize(lk)
        // segment_vectors は chunks 削除前に
        let v = try prepare("DELETE FROM segment_vectors WHERE chunk_id IN (SELECT id FROM chunks WHERE file_id = ?);")
        sqlite3_bind_int64(v, 1, fileId); _ = sqlite3_step(v); sqlite3_finalize(v)
        let c = try prepare("DELETE FROM chunks WHERE file_id = ?;")  // トリガで fts も削除
        sqlite3_bind_int64(c, 1, fileId); _ = sqlite3_step(c); sqlite3_finalize(c)
    }

    /// 1 ファイルを upsert(既存なら全依存行を作り直す)。トランザクション内で実行。
    public func upsert(file: IndexedFile, parsed: ParsedDoc, indexedAt: Double) throws {
        try exec("BEGIN;")
        do {
            try deleteFile(path: file.path)
            let ins = try prepare("""
                INSERT INTO files(path, rel_path, dir, ext, mtime, size, content_hash, title, indexed_at, doc_date)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """)
            bindText(ins, 1, file.path); bindText(ins, 2, file.relPath); bindText(ins, 3, file.dir)
            bindText(ins, 4, file.ext); sqlite3_bind_double(ins, 5, file.mtime)
            sqlite3_bind_int64(ins, 6, file.size); bindText(ins, 7, file.contentHash)
            bindText(ins, 8, parsed.title); sqlite3_bind_double(ins, 9, indexedAt)
            sqlite3_bind_double(ins, 10, file.docDate > 0 ? file.docDate : file.mtime)
            guard sqlite3_step(ins) == SQLITE_DONE else {
                sqlite3_finalize(ins); throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(ins)
            let fileId = sqlite3_last_insert_rowid(db)

            for (k, v) in parsed.frontMatter {
                let s = try prepare("INSERT INTO frontmatter(file_id, key, value) VALUES (?,?,?);")
                sqlite3_bind_int64(s, 1, fileId); bindText(s, 2, k.lowercased()); bindText(s, 3, v)
                _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            for h in parsed.headings {
                let s = try prepare("INSERT INTO headings(file_id, level, text, slug, line, path_text) VALUES (?,?,?,?,?,?);")
                sqlite3_bind_int64(s, 1, fileId); sqlite3_bind_int(s, 2, Int32(h.level))
                bindText(s, 3, h.text); bindText(s, 4, h.slug); sqlite3_bind_int(s, 5, Int32(h.line))
                bindText(s, 6, h.pathText); _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            for l in parsed.links {
                let s = try prepare("INSERT INTO links(src_file_id, target_path, target_rel, target_file_id, anchor, kind) VALUES (?,?,?,?,?,?);")
                sqlite3_bind_int64(s, 1, fileId); bindText(s, 2, l.targetPath)
                bindText(s, 3, "")  // target_rel は resolveLinkTargets で埋める
                sqlite3_bind_null(s, 4)
                if let a = l.anchor { bindText(s, 5, a) } else { sqlite3_bind_null(s, 5) }
                bindText(s, 6, l.kind); _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            for t in parsed.tasks {
                let s = try prepare("INSERT INTO tasks(file_id, checked, text, line) VALUES (?,?,?,?);")
                sqlite3_bind_int64(s, 1, fileId); sqlite3_bind_int(s, 2, t.checked ? 1 : 0)
                bindText(s, 3, t.text); sqlite3_bind_int(s, 4, Int32(t.line))
                _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            for lang in parsed.codeLangs {
                let s = try prepare("INSERT INTO code_blocks(file_id, lang) VALUES (?,?);")
                sqlite3_bind_int64(s, 1, fileId); bindText(s, 2, lang)
                _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            for c in parsed.chunks {
                let s = try prepare("INSERT INTO chunks(file_id, heading_slug, heading_path, text, ngram, start_line, end_line) VALUES (?,?,?,?,?,?,?);")
                sqlite3_bind_int64(s, 1, fileId); bindText(s, 2, c.headingSlug); bindText(s, 3, c.headingPath)
                bindText(s, 4, c.text); bindText(s, 5, Tokenizer.indexString(c.text))
                sqlite3_bind_int(s, 6, Int32(c.startLine)); sqlite3_bind_int(s, 7, Int32(c.endLine))
                _ = sqlite3_step(s); sqlite3_finalize(s)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// links.target_file_id / target_rel を rel_path 照合で解決(全ファイル indexing 後に 1 回)。
    public func resolveLinkTargets() throws {
        // 相対リンクを「リンク元 dir + target_path」で正規化して files.rel_path と突き合わせる。
        try exec("""
        UPDATE links SET
            target_rel = (
                SELECT f.rel_path FROM files f
                WHERE f.rel_path = links.target_path
                   OR f.rel_path = (SELECT dir FROM files WHERE id = links.src_file_id) || '/' || links.target_path
                LIMIT 1
            )
        WHERE kind IN ('md','wiki');
        UPDATE links SET target_file_id = (SELECT id FROM files WHERE rel_path = links.target_rel LIMIT 1)
        WHERE target_rel IS NOT NULL AND target_rel <> '';
        """)
    }

    // MARK: レキシカル検索

    private enum Bind { case text(String); case double(Double); case int(Int64) }

    /// QueryFilters → (SQL 述語フラグメント, バインド値)。述語は files エイリアス `f` を参照する。
    private func predicates(_ filters: QueryFilters) -> (sql: [String], binds: [Bind]) {
        var sql: [String] = []
        var binds: [Bind] = []
        for tag in filters.tags {
            sql.append("EXISTS (SELECT 1 FROM frontmatter fm WHERE fm.file_id=f.id AND fm.key IN ('tags','tag') AND fm.value=?)")
            binds.append(.text(tag))
        }
        for s in filters.status {
            sql.append("EXISTS (SELECT 1 FROM frontmatter fm WHERE fm.file_id=f.id AND fm.key='status' AND fm.value=?)")
            binds.append(.text(s))
        }
        for pair in filters.frontMatter {
            sql.append("EXISTS (SELECT 1 FROM frontmatter fm WHERE fm.file_id=f.id AND fm.key=? AND fm.value=?)")
            binds.append(.text(pair.key)); binds.append(.text(pair.value))
        }
        for p in filters.pathContains {
            sql.append("f.rel_path LIKE ?")
            binds.append(.text("%\(p)%"))
        }
        if !filters.exts.isEmpty {
            sql.append("f.ext IN (\(filters.exts.map { _ in "?" }.joined(separator: ",")))")
            filters.exts.forEach { binds.append(.text($0)) }
        }
        for lang in filters.langs {
            sql.append("EXISTS (SELECT 1 FROM code_blocks cb WHERE cb.file_id=f.id AND cb.lang=?)")
            binds.append(.text(lang))
        }
        // 時間軸フィルタは文書の日付(front matter date、無ければ mtime)に対して効かせる
        if let after = filters.modifiedAfter {
            sql.append("f.doc_date >= ?"); binds.append(.double(after))
        }
        if let before = filters.modifiedBefore {
            sql.append("f.doc_date < ?"); binds.append(.double(before))
        }
        if let ts = filters.taskState {
            switch ts {
            case .any:  sql.append("EXISTS (SELECT 1 FROM tasks t WHERE t.file_id=f.id)")
            case .todo: sql.append("EXISTS (SELECT 1 FROM tasks t WHERE t.file_id=f.id AND t.checked=0)")
            case .done: sql.append("EXISTS (SELECT 1 FROM tasks t WHERE t.file_id=f.id AND t.checked=1)")
            }
        }
        return (sql, binds)
    }

    private func bind(_ stmt: OpaquePointer, _ binds: [Bind], startingAt: Int32) {
        var i = startingAt
        for b in binds {
            switch b {
            case .text(let s): bindText(stmt, i, s)
            case .double(let d): sqlite3_bind_double(stmt, i, d)
            case .int(let n): sqlite3_bind_int64(stmt, i, n)
            }
            i += 1
        }
    }

    /// 構造化フィルタを満たすファイル id 集合(意味検索を同じ条件で絞るため)。
    public func fileIds(matching filters: QueryFilters) throws -> Set<Int64> {
        let (preds, fbinds) = predicates(filters)
        var sql = "SELECT f.id FROM files f"
        if !preds.isEmpty { sql += " WHERE " + preds.joined(separator: " AND ") }
        let stmt = try prepare(sql + ";")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, fbinds, startingAt: 1)
        var ids = Set<Int64>()
        while sqlite3_step(stmt) == SQLITE_ROW { ids.insert(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    /// 全文 + 構造化フィルタのハイブリッド検索。matchExpr が nil なら構造化のみ(ファイル粒度)。
    public func search(matchExpr: String?, filters: QueryFilters, limit: Int) throws -> [LexicalRow] {
        let (preds, fbinds) = predicates(filters)
        if let matchExpr {
            var sql = """
            SELECT c.id, c.file_id, bm25(fts_chunks), f.path, f.rel_path, f.title,
                   c.heading_slug, c.heading_path, c.text
            FROM fts_chunks
            JOIN chunks c ON c.id = fts_chunks.rowid
            JOIN files f ON f.id = c.file_id
            WHERE fts_chunks MATCH ?
            """
            if !preds.isEmpty { sql += " AND " + preds.joined(separator: " AND ") }
            sql += " ORDER BY bm25(fts_chunks) LIMIT ?;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, matchExpr)
            bind(stmt, fbinds, startingAt: 2)
            sqlite3_bind_int(stmt, Int32(2 + fbinds.count), Int32(limit))
            return try collectRows(stmt)
        } else {
            // 構造化のみ: ファイル → 代表チャンク(先頭)を 1 件返す
            var sql = """
            SELECT c.id, f.id, 0.0, f.path, f.rel_path, f.title,
                   c.heading_slug, c.heading_path, c.text
            FROM files f
            LEFT JOIN chunks c ON c.id = (SELECT id FROM chunks WHERE file_id=f.id ORDER BY start_line LIMIT 1)
            """
            if !preds.isEmpty { sql += " WHERE " + preds.joined(separator: " AND ") }
            sql += " ORDER BY f.mtime DESC LIMIT ?;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, fbinds, startingAt: 1)
            sqlite3_bind_int(stmt, Int32(1 + fbinds.count), Int32(limit))
            return try collectRows(stmt)
        }
    }

    private func collectRows(_ stmt: OpaquePointer) throws -> [LexicalRow] {
        var rows: [LexicalRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func textCol(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            rows.append(LexicalRow(
                chunkId: sqlite3_column_int64(stmt, 0),
                fileId: sqlite3_column_int64(stmt, 1),
                bm25: sqlite3_column_double(stmt, 2),
                path: textCol(3), relPath: textCol(4), title: textCol(5),
                headingSlug: textCol(6), headingPath: textCol(7), text: textCol(8)))
        }
        return rows
    }

    public func searchLexical(matchExpr: String, limit: Int) throws -> [LexicalRow] {
        let sql = """
        SELECT c.id, c.file_id, bm25(fts_chunks), f.path, f.rel_path, f.title,
               c.heading_slug, c.heading_path, c.text
        FROM fts_chunks
        JOIN chunks c ON c.id = fts_chunks.rowid
        JOIN files f ON f.id = c.file_id
        WHERE fts_chunks MATCH ?
        ORDER BY bm25(fts_chunks)
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, matchExpr)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [LexicalRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(LexicalRow(
                chunkId: sqlite3_column_int64(stmt, 0),
                fileId: sqlite3_column_int64(stmt, 1),
                bm25: sqlite3_column_double(stmt, 2),
                path: String(cString: sqlite3_column_text(stmt, 3)),
                relPath: String(cString: sqlite3_column_text(stmt, 4)),
                title: String(cString: sqlite3_column_text(stmt, 5)),
                headingSlug: String(cString: sqlite3_column_text(stmt, 6)),
                headingPath: String(cString: sqlite3_column_text(stmt, 7)),
                text: String(cString: sqlite3_column_text(stmt, 8))))
        }
        return rows
    }
}
