import XCTest
@testable import SearchCore

final class MarkdownStructureTests: XCTestCase {

    func testSlugifyMatchesViewerJS() {
        // viewer.js assignHeadingIds と同じ規則
        XCTAssertEqual(MarkdownStructure.slugify("Hello World"), "hello-world")
        XCTAssertEqual(MarkdownStructure.slugify("  Trim  Me  "), "trim-me")
        XCTAssertEqual(MarkdownStructure.slugify("API: 認証フロー"), "api-認証フロー")
        XCTAssertEqual(MarkdownStructure.slugify("C++ & Rust"), "c-rust")
        XCTAssertEqual(MarkdownStructure.slugify("snake_case-kebab"), "snake_case-kebab")
    }

    func testHeadingHierarchyAndChunks() {
        let md = """
        ---
        title: テスト文書
        tags: [api, auth]
        status: draft
        ---
        # 概要
        前文。
        ## 認証
        OAuth2 を使う。
        ### トークン
        有効期限は 3600 秒。
        ## 登録
        メールで確認。
        """
        let doc = MarkdownStructure.parse(content: md, fileName: "test.md")
        XCTAssertEqual(doc.title, "テスト文書")
        XCTAssertEqual(doc.headings.map { $0.text }, ["概要", "認証", "トークン", "登録"])
        XCTAssertEqual(doc.headings.map { $0.level }, [1, 2, 3, 2])
        // breadcrumb
        let tokenHeading = doc.headings.first { $0.text == "トークン" }!
        XCTAssertEqual(tokenHeading.pathText, "概要 > 認証 > トークン")
        // front matter
        XCTAssertTrue(doc.frontMatter.contains { $0.key == "tags" && $0.value == "api" })
        XCTAssertTrue(doc.frontMatter.contains { $0.key == "tags" && $0.value == "auth" })
        XCTAssertTrue(doc.frontMatter.contains { $0.key == "status" && $0.value == "draft" })
        // 見出しごとに 1 チャンク(空の前文チャンクは生成されない)
        XCTAssertEqual(doc.chunks.count, 4)
        XCTAssertTrue(doc.chunks.contains { $0.headingSlug == "認証" && $0.text.contains("OAuth2") })
    }

    func testTasksAndLinks() {
        let md = """
        # TODO
        - [ ] 未完了タスク
        - [x] 完了タスク
        通常リンク [仕様](./spec.md) と [外部](https://example.com) と [[wiki ページ]]。
        """
        let doc = MarkdownStructure.parse(content: md, fileName: "todo.md")
        XCTAssertEqual(doc.tasks.count, 2)
        XCTAssertTrue(doc.tasks.contains { $0.checked && $0.text == "完了タスク" })
        XCTAssertTrue(doc.tasks.contains { !$0.checked && $0.text == "未完了タスク" })
        XCTAssertTrue(doc.links.contains { $0.kind == "md" && $0.targetPath == "./spec.md" })
        XCTAssertTrue(doc.links.contains { $0.kind == "external" })
        XCTAssertTrue(doc.links.contains { $0.kind == "wiki" && $0.targetPath == "wiki ページ" })
    }

    func testHeadingsInsideCodeFenceIgnored() {
        let md = """
        # 本物の見出し
        ```
        # これは見出しではない
        ```
        本文。
        """
        let doc = MarkdownStructure.parse(content: md, fileName: "fence.md")
        XCTAssertEqual(doc.headings.map { $0.text }, ["本物の見出し"])
    }

    func testCodeLangExtraction() {
        let md = """
        # コード
        ```swift
        let x = 1
        ```
        ```python
        x = 1
        ```
        """
        let doc = MarkdownStructure.parse(content: md, fileName: "code.md")
        XCTAssertEqual(Set(doc.codeLangs), ["swift", "python"])
    }
}
