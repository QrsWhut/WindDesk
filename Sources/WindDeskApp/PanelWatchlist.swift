import SwiftUI
import WindDeskCore

struct PanelWatchlist: View {
    @Bindable var store: MarketStore
    let kind: WatchlistKind
    let openSettings: () -> Void

    @State private var query = ""
    @State private var submitted = ""
    @State private var editing = false
    @State private var searchPending = false

    private var isIndex: Bool { kind == .indices }
    private var items: [WatchItem] { isIndex ? store.indexWatchlist : store.watchlist }
    private var instrumentLabel: String { isIndex ? "指数" : "证券" }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("按\(instrumentLabel)名称或代码搜索", text: $query)
                    .textFieldStyle(.plain).onSubmit { search() }
                    .accessibilityLabel("\(instrumentLabel)名称或代码")
                if !query.isEmpty {
                    Button {
                        query = ""
                        submitted = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("清空搜索")
                }
                Button(store.isSearching || searchPending ? "搜索中…" : "搜索") { search() }
                    .controlSize(.small).disabled(!canSearch)
            }
            .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
            if !store.hasKey {
                HStack {
                    Text("配置 Wind Alice 后可搜索\(instrumentLabel)。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("去设置", action: openSettings).controlSize(.small)
                }
            }
            if !submitted.isEmpty && submitted == query.trimmingCharacters(in: .whitespacesAndNewlines) && !searchPending && !store.isSearching {
                if let error = store.searchError {
                    PanelNotice(text: error)
                } else if !store.searchResults.isEmpty {
                    let selected = Set(items.map(\.code))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("搜索结果").font(.headline)
                        ForEach(store.searchResults) { item in
                            HStack {
                                identity(item)
                                Spacer()
                                let added = selected.contains(item.code)
                                Button(added ? "已添加" : "添加") { store.add(item, to: kind) }
                                    .controlSize(.small).disabled(added)
                                    .help("添加后随下次行情刷新获取报价")
                            }
                            if item.id != store.searchResults.last?.id { Divider() }
                        }
                    }
                }
            }

            HStack {
                Text(isIndex ? "我的指数" : "我的自选股").font(.headline)
                Spacer()
                if !items.isEmpty {
                    Button(editing ? "完成" : "编辑") { editing.toggle() }
                        .controlSize(.small)
                        .accessibilityLabel((editing ? "完成编辑" : "编辑") + (isIndex ? "指数" : "自选股"))
                }
            }
            if items.isEmpty {
                Text(isIndex ? "搜索指数名称或代码后，点击「添加」。" : "搜索证券后，点击「添加」即可加入自选。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("桌面小组件按列表顺序显示，可在设置中调整显示数量。")
                    .font(.caption).foregroundStyle(.secondary)
                let quotes = isIndex ? store.snapshot.indices : store.snapshot.stocks
                let quotesByCode = Dictionary(quotes.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        if editing {
                            HStack(spacing: 6) {
                                identity(item)
                                Spacer()
                                action("上移" + item.name, symbol: "chevron.up") { store.move(item, by: -1, in: kind) }
                                    .disabled(item.id == items.first?.id)
                                action("下移" + item.name, symbol: "chevron.down") { store.move(item, by: 1, in: kind) }
                                    .disabled(item.id == items.last?.id)
                                action("移除" + item.name, symbol: "minus.circle") { store.remove(item, from: kind) }
                            }
                            .padding(.vertical, 5)
                        } else {
                            PanelQuoteRow(item: item, quote: quotesByCode[item.code], isIndex: isIndex)
                        }
                        if item.id != items.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
            }
            if let error = store.issues[isIndex ? .indices : .stocks] { PanelNotice(text: error) }
        }
        .onChange(of: items.isEmpty) { _, empty in if empty { editing = false } }
    }

    private func identity(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
            Text([item.code, item.market].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 20, height: 22) }
            .buttonStyle(.borderless).accessibilityLabel(title).help(title)
    }

    private var canSearch: Bool {
        store.hasKey && !store.isCheckingWindGold && !store.isRefreshing && !store.isSearching
            && !searchPending && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func search() {
        guard canSearch else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = text
        searchPending = true
        Task {
            await store.search(text, in: kind)
            searchPending = false
        }
    }
}
