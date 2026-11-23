import SwiftUI
import WindDeskCore

struct PanelWatchlist: View {
    @Bindable var store: MarketStore
    let openSettings: () -> Void

    @State private var query = ""
    @State private var submitted = ""
    @State private var editing = false
    @State private var searchPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("按证券名称或代码搜索", text: $query)
                    .textFieldStyle(.plain).onSubmit { search() }
                    .accessibilityLabel("证券名称或代码")
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
                    Text("配置 Wind Alice 后可搜索证券。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("去设置", action: openSettings).controlSize(.small)
                }
            }
            if !submitted.isEmpty && submitted == query.trimmingCharacters(in: .whitespacesAndNewlines) && !searchPending && !store.isSearching {
                if let error = store.searchError {
                    PanelNotice(text: error)
                } else if !store.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("搜索结果").font(.headline)
                        ForEach(store.searchResults) { item in
                            HStack {
                                identity(item)
                                Spacer()
                                let added = store.watchlist.contains { $0.id == item.id }
                                Button(added ? "已添加" : "添加") { store.add(item) }
                                    .controlSize(.small).disabled(added)
                            }
                            if item.id != store.searchResults.last?.id { Divider() }
                        }
                    }
                }
            }

            HStack {
                Text("我的自选股").font(.headline)
                Spacer()
                if !store.watchlist.isEmpty {
                    Button(editing ? "完成" : "编辑") { editing.toggle() }
                        .controlSize(.small).accessibilityLabel(editing ? "完成自选股编辑" : "编辑自选股")
                }
            }
            if store.watchlist.isEmpty {
                Text("搜索证券后，点击「添加」即可加入自选。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let quotesByCode = Dictionary(store.snapshot.stocks.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
                LazyVStack(spacing: 0) {
                    ForEach(store.watchlist) { item in
                        if editing {
                            HStack(spacing: 6) {
                                identity(item)
                                Spacer()
                                action("上移" + item.name, symbol: "chevron.up") { store.move(item, by: -1) }
                                    .disabled(item.id == store.watchlist.first?.id)
                                action("下移" + item.name, symbol: "chevron.down") { store.move(item, by: 1) }
                                    .disabled(item.id == store.watchlist.last?.id)
                                action("移除" + item.name, symbol: "minus.circle") { store.remove(item) }
                            }
                            .padding(.vertical, 5)
                        } else {
                            PanelQuoteRow(item: item, quote: quotesByCode[item.code], isIndex: false)
                        }
                        if item.id != store.watchlist.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
            }
            if let error = store.issues[.stocks] { PanelNotice(text: error) }
        }
        .onChange(of: store.watchlist.isEmpty) { _, empty in if empty { editing = false } }
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
            await store.search(text)
            searchPending = false
        }
    }
}
