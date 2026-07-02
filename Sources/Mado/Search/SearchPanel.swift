import SwiftUI
import SearchCore

/// フォルダ横断検索のネイティブパネル(⌘⇧F)。
/// 本文(抜粋)を主役に、信号(全文/意味/条件)はティックと由来フッタで控えめに示す。
/// 結果クリックで右の WKWebView(実際のレンダリング)が該当見出しへ遷移する。
struct SearchPanel: View {
    @EnvironmentObject var state: AppState
    @FocusState private var queryFocused: Bool

    private var groups: [(file: String, title: String, hits: [SearchHit])] {
        var order: [String] = []
        var map: [String: [SearchHit]] = [:]
        for h in state.searchResults {
            if map[h.relPath] == nil { order.append(h.relPath) }
            map[h.relPath, default: []].append(h)
        }
        return order.map { ($0, map[$0]?.first?.title ?? $0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(SC.rule)
            if state.searchResults.isEmpty {
                emptyState
            } else {
                resultsList
                if let hit = highlighted { ProvenanceFooter(hit: hit) }
            }
            if state.isEmbeddingIndex {
                EmbeddingStrip(done: state.embedDone, total: state.embedTotal)
            }
        }
        .background(SC.bg)
        .onAppear { queryFocused = true }
        .onExitCommand { state.closeSearch() }
        .onMoveCommand { dir in moveHighlight(dir) }
    }

    private var highlighted: SearchHit? {
        state.searchResults.first { $0.id == state.highlightedHitID } ?? state.searchResults.first
    }
    private var maxScore: Double { state.searchResults.map(\.score).max() ?? 1 }

    // MARK: header (検索窓 + 解釈)

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("MADO 窓 検索")
                .font(.system(size: 11, weight: .bold)).tracking(4)
                .foregroundStyle(SC.faint)

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(SC.sec).font(.system(size: 15))
                TextField("検索 — tag:api 認証 / 先月書いた下書き …", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.custom("Hiragino Mincho ProN", size: 19))
                    .foregroundStyle(SC.ink)
                    .focused($queryFocused)
                    .onSubmit { openHighlighted() }
                    .onChange(of: state.searchQuery) { state.runSearch() }
                if state.isSearching { ProgressView().controlSize(.small) }
                Text("\(state.searchResults.count) 件")
                    .font(.system(size: 12)).foregroundStyle(SC.faint).monospacedDigit()
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11).fill(SC.field))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                queryFocused ? SC.focus : SC.rule, lineWidth: queryFocused ? 1.5 : 1))

            if !state.searchFacets.isEmpty {
                InterpretationBar(facets: state.searchFacets)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 13)
    }

    // MARK: results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.file) { g in
                        Section {
                            ForEach(g.hits) { hit in
                                ResultRow(hit: hit,
                                          terms: state.searchTerms,
                                          relevance: maxScore > 0 ? hit.score / maxScore : 0,
                                          selected: hit.id == state.highlightedHitID)
                                    .id(hit.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(hit) }
                            }
                        } header: {
                            FileHeader(file: g.file, count: g.hits.count)
                        }
                    }
                }
            }
            .onChange(of: state.highlightedHitID) {
                if let id = state.highlightedHitID {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(state.searchQuery.isEmpty ? "検索語またはフィルタを入力" : "一致なし")
                .foregroundStyle(SC.sec).font(.custom("Hiragino Mincho ProN", size: 14))
            Text("例:  tag:api 認証   ·   is:todo lang:swift   ·   先月の設計")
                .font(.system(size: 11)).foregroundStyle(SC.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions

    private func open(_ hit: SearchHit) {
        state.highlightedHitID = hit.id
        state.openResult(hit)
    }
    private func openHighlighted() { if let h = highlighted { open(h) } }

    private func moveHighlight(_ dir: MoveCommandDirection) {
        let ids = state.searchResults.map { $0.id }
        guard !ids.isEmpty else { return }
        let cur = ids.firstIndex(of: state.highlightedHitID ?? "") ?? 0
        switch dir {
        case .up:   state.highlightedHitID = ids[max(0, cur - 1)]
        case .down: state.highlightedHitID = ids[min(ids.count - 1, cur + 1)]
        default: break
        }
    }
}

// MARK: - 解釈バー

private struct InterpretationBar: View {
    @EnvironmentObject var state: AppState
    let facets: [QueryFacet]
    var body: some View {
        HStack(spacing: 8) {
            Text("解釈").font(.system(size: 9, weight: .semibold)).tracking(2)
                .foregroundStyle(SC.faint)
            Text("›").foregroundStyle(SC.faint).font(.system(size: 11))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(facets) { facet in
                        // 全文+意味はクエリ本体なので解除不可。フィルタ系はタップで個別に外せる。
                        if facet.kind == .lexsem {
                            FacetChip(facet: facet, disabled: false)
                        } else {
                            FacetChip(facet: facet, disabled: state.disabledFacets.contains(facet.id))
                                .contentShape(Capsule())
                                .onTapGesture { state.toggleFacet(facet.id) }
                                .help("タップでこの解釈を無効化/再有効化")
                        }
                    }
                }
            }
        }
    }
}

private struct FacetChip: View {
    let facet: QueryFacet
    let disabled: Bool
    var body: some View {
        HStack(spacing: 7) {
            SignalDot(kind: facet.kind)
            Text(facet.kindLabel).font(.system(size: 8.5, weight: .semibold)).tracking(1.2)
                .foregroundStyle(SC.faint).textCase(.uppercase)
            Text(facet.value).font(.system(size: 12.5))
                .foregroundStyle(disabled ? SC.faint : SC.sec)
                .strikethrough(disabled, color: SC.faint)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(SC.rule.opacity(0.6), lineWidth: 0.5))
        .opacity(disabled ? 0.55 : 1)
    }
}

private struct SignalDot: View {
    let kind: QueryFacet.Kind
    var body: some View {
        Group {
            if kind == .lexsem {
                // 全文+意味 = 二色
                HStack(spacing: 0) {
                    Rectangle().fill(SC.lex); Rectangle().fill(SC.sem)
                }.frame(width: 8, height: 8).clipShape(Circle())
            } else {
                Circle().fill(kind == .time ? SC.str : SC.str).frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - ファイル見出し

private struct FileHeader: View {
    let file: String; let count: Int
    private var dir: String { (file as NSString).deletingLastPathComponent }
    private var name: String { (file as NSString).lastPathComponent }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(dir.isEmpty ? "" : dir + "/").foregroundStyle(SC.faint)
             + Text(name).foregroundStyle(SC.ink))
                .font(.system(size: 11, design: .monospaced))
            Spacer()
            Text("\(count) 箇所").font(.system(size: 11)).foregroundStyle(SC.faint)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SC.bg)
    }
}

// MARK: - 結果 1 行(本文抜粋が主役)

private struct ResultRow: View {
    let hit: SearchHit
    let terms: [String]
    let relevance: Double     // 0–1(この検索内での相対関連度)
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左余白の極小ティック(信号)
            VStack(spacing: 3) {
                ForEach(orderedKinds, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1).fill(color(k)).frame(width: 3, height: 10)
                }
            }
            .frame(width: 12, alignment: .leading).padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.headingPath.isEmpty ? hit.title : hit.headingPath)
                        .font(.system(size: 11.5)).foregroundStyle(SC.faint).lineLimit(1)
                    Spacer(minLength: 6)
                    RelevanceGauge(relevance: relevance)
                }
                Text(highlightedExcerpt)
                    .font(.custom("Hiragino Mincho ProN", size: 15))
                    .foregroundStyle(SC.body).lineSpacing(3).lineLimit(3)
            }
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? SC.sel : .clear)
        .overlay(Rectangle().fill(SC.rule.opacity(0.5)).frame(height: 0.5), alignment: .bottom)
    }

    private var orderedKinds: [MatchKind] {
        [.lexical, .semantic, .structured].filter { hit.kinds.contains($0) }
    }
    private func color(_ k: MatchKind) -> Color {
        switch k { case .lexical: SC.lex; case .semantic: SC.sem; case .structured: SC.str }
    }

    private var highlightedExcerpt: AttributedString {
        var s = AttributedString(hit.snippet)
        let lower = hit.snippet.lowercased()
        for term in terms where term.count >= 2 {
            var from = lower.startIndex
            let t = term.lowercased()
            while let r = lower.range(of: t, range: from..<lower.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: s),
                   let hi = AttributedString.Index(r.upperBound, within: s) {
                    s[lo..<hi].foregroundColor = SC.lex
                    s[lo..<hi].font = .custom("Hiragino Mincho ProN", size: 15).weight(.semibold)
                }
                from = r.upperBound
            }
        }
        return s
    }
}

// MARK: - 意味索引 構築中ストリップ

private struct EmbeddingStrip: View {
    let done: Int
    let total: Int
    private var frac: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text("意味索引を構築中").font(.system(size: 11)).foregroundStyle(SC.sec)
                Spacer()
                Text("\(done) / \(total)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(SC.rule).frame(height: 3)
                GeometryReader { geo in
                    Capsule().fill(SC.sem).frame(width: geo.size.width * frac, height: 3)
                }.frame(height: 3)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(Rectangle().fill(SC.rule).frame(height: 1), alignment: .top)
    }
}

// MARK: - 関連度ゲージ(行ごと・相対)

private struct RelevanceGauge: View {
    let relevance: Double     // 全体の関連度(融合スコアの相対値)。特定の信号ではない。
    private var pct: Int { Int((relevance * 100).rounded()) }
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(SC.rule).frame(width: 40, height: 3)
                Capsule().fill(SC.sec.opacity(0.75)).frame(width: max(2, 40 * relevance), height: 3)
            }
            Text("\(pct)").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SC.faint).frame(width: 22, alignment: .trailing)
        }
        .help("関連度(全体)— 全文・意味・条件を融合した相対スコア")
    }
}

// MARK: - 由来フッタ(脚注扱い)

private struct ProvenanceFooter: View {
    let hit: SearchHit
    var body: some View {
        HStack(spacing: 15) {
            ForEach(ordered, id: \.self) { k in
                HStack(spacing: 6) {
                    Circle().fill(color(k)).frame(width: 6, height: 6)
                    Text(label(k)).font(.system(size: 11)).foregroundStyle(SC.sec)
                    if let v = value(k) {
                        Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
                    }
                }
            }
            Spacer()
            Text("融合 \(hit.score, specifier: "%.4f")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
        .overlay(Rectangle().fill(SC.rule).frame(height: 1), alignment: .top)
    }
    private var ordered: [MatchKind] { [.lexical, .semantic, .structured].filter { hit.kinds.contains($0) } }
    private func color(_ k: MatchKind) -> Color { k == .lexical ? SC.lex : k == .semantic ? SC.sem : SC.str }
    private func label(_ k: MatchKind) -> String { k == .lexical ? "全文" : k == .semantic ? "意味" : "条件" }
    private func value(_ k: MatchKind) -> String? {
        switch k {
        case .semantic: hit.cosine.map { String(format: "cos %.2f", $0) }
        case .lexical:  hit.bm25.map { String(format: "bm25 %.1f", $0) }
        case .structured: "✓"
        }
    }
}

// MARK: - パレット(温かい墨 × 紙白 × 顔料3色)

enum SC {
    static let bg    = Color(hex: 0x1A1815)
    static let field = Color(hex: 0x211F1A)
    static let sel   = Color(hex: 0x262219)
    static let ink   = Color(hex: 0xE9E3D6)
    static let body  = Color(hex: 0xD2CBBB)
    static let sec   = Color(hex: 0xA79E8C)
    static let faint = Color(hex: 0x6E6657)
    static let rule  = Color(hex: 0x322D25)
    static let focus = Color(hex: 0x4A5F78)
    static let lex   = Color(hex: 0xD5A551)   // 全文 黄土
    static let sem   = Color(hex: 0x88AEDB)   // 意味 藍
    static let str   = Color(hex: 0x9BB173)   // 条件 苔
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
