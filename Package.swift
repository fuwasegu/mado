// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mado",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 高品質な多言語埋め込み(multilingual-e5)の CoreML 実行に必要なトークナイザ。
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [
        // 検索ロジック(SQLite/解析/トークナイズ/クエリ/融合/埋め込み)。
        // UI を含まず、Mado(アプリ)と MadoSearchMCP の両方から再利用する。
        // e5 CoreML モデル + トークナイザをリソースとして同梱。
        .target(
            name: "SearchCore",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Mado",
            dependencies: ["SearchCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SearchCoreTests",
            dependencies: ["SearchCore"]
        )
    ]
)
