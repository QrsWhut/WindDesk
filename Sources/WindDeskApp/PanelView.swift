import AppKit
import SwiftUI
import WindDeskCore

private enum PanelTab: String, CaseIterable {
    case markets = "行情"
    case watchlist = "自选"
    case settings = "设置"
}

struct PanelView: View {
    @Bindable var store: MarketStore
    @State private var tab = PanelTab.markets

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 29, height: 29)
                        .background(Color(red: 0.12, green: 0.33, blue: 0.31), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    Text("WindDesk").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        HStack(spacing: 5) {
                            if store.isRefreshing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                            Text(store.isRefreshing ? "刷新中" : "刷新")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.hasKey || store.isRefreshing || store.isCheckingWindGold || store.isSearching)
                    .help("刷新行情（⌘R）")
                }
                Picker("面板页面", selection: $tab) {
                    ForEach(PanelTab.allCases, id: \.self) { page in Text(page.rawValue).tag(page) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 11)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    switch tab {
                    case .markets:
                        overview
                    case .watchlist:
                        PanelWatchlist(store: store, openSettings: { tab = .settings })
                    case .settings:
                        PanelSettings(store: store, showMarkets: { tab = .markets })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(tab)
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 428, height: 550)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var overview: some View {
        if !store.hasKey {
            HStack {
                Label("配置 Wind Alice 后可刷新行情", systemImage: "key")
                Spacer()
                Button("去设置") { tab = .settings }.controlSize(.small)
            }
            .font(.callout)
        }
        GoldQuoteCard(snapshot: store.snapshot)
        VStack(alignment: .leading, spacing: 6) {
            Text("市场指数").font(.headline)
            quoteList(WatchItem.indices, quotes: store.snapshot.indices, isIndex: true)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("自选股").font(.headline)
                Spacer()
                Button(store.watchlist.isEmpty ? "添加" : "查看全部（\(store.watchlist.count)）") {
                    tab = .watchlist
                }
                .controlSize(.small)
            }
            if !store.watchlist.isEmpty {
                quoteList(Array(store.watchlist.prefix(3)), quotes: store.snapshot.stocks, isIndex: false)
            }
        }
        if !store.issues.isEmpty || store.widgetError != nil {
            DisclosureGroup(store.issues.isEmpty ? "小组件更新提示" : "\(store.issues.count) 项行情有更新提示") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([QuoteSection.gold, .goldCNY, .fx, .indices, .stocks], id: \.self) { section in
                        if let error = store.issues[section] {
                            PanelNotice(text: "\(sectionTitle(section)) · \(error)")
                        }
                    }
                    if let error = store.widgetError { PanelNotice(text: error) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .font(.callout)
        }
    }

    private func quoteList(_ items: [WatchItem], quotes: [WindQuote], isIndex: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                PanelQuoteRow(item: item, quote: quotes.first { $0.code == item.code }, isIndex: isIndex)
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
    }

    private func sectionTitle(_ section: QuoteSection) -> String {
        switch section {
        case .gold: "美元金价"
        case .goldCNY: "人民币金价"
        case .fx: "汇率"
        case .indices: "指数"
        case .stocks: "自选股"
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").accessibilityHidden(true)
            if store.isRefreshing {
                Text(store.refreshStage.map { "正在更新\($0)…" } ?? "正在获取最新行情…")
            } else if let last = store.lastRefresh {
                Text("上次取数 " + last.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))
                    .help(last.formatted(date: .complete, time: .standard))
            } else {
                Text("尚无成功取数记录")
            }
            Spacer()
            Menu {
                Button("退出 WindDesk") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("更多操作")
            .help("更多操作")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

private struct GoldQuoteCard: View {
    let snapshot: MarketSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("伦敦金现货").font(.headline)
                Spacer()
                Text("Wind Alice").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                goldValue(snapshot.gold?.price, unit: "美元 / 金衡盎司",
                          percentage: snapshot.gold?.changePercent, time: snapshot.gold?.quotedAt,
                          showsQuoteTime: true)
                Divider()
                goldValue(snapshot.goldCNYPerGram, unit: cnyUnit,
                          percentage: snapshot.usesConvertedGoldCNY ? nil : snapshot.goldCNY?.changePercent,
                          time: snapshot.goldCNY?.quotedAt, showsQuoteTime: !snapshot.usesConvertedGoldCNY)
            }
            .fixedSize(horizontal: false, vertical: true)
            if snapshot.usesConvertedGoldCNY, let fx = snapshot.fx {
                Text("USD/\(fx.currency ?? "—")  \(PanelNumber.format(fx.price, digits: 2...5))  ·  \(PanelQuoteTime.format(fx.quotedAt) ?? "暂无汇率时间")")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(fx.quotedAt ?? "暂无汇率时间")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.22)) }
    }

    private var cnyUnit: String {
        guard snapshot.usesConvertedGoldCNY else { return "人民币 / 克" }
        return snapshot.fx?.currency == "CNH" ? "离岸人民币 / 克 · 折算" : "人民币 / 克 · 折算"
    }

    private func goldValue(_ value: Decimal?, unit: String, percentage: Decimal?, time: String?, showsQuoteTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(unit).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(PanelNumber.format(value)).font(.system(size: 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if percentage != nil { PanelChange(value: percentage) }
            }
            .lineLimit(1).minimumScaleFactor(0.78)
            if showsQuoteTime {
                Text(PanelQuoteTime.format(time) ?? (value == nil ? "暂无报价" : "暂无行情时间"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(time ?? "暂无行情时间")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PanelQuoteRow: View {
    let item: WatchItem
    let quote: WindQuote?
    let isIndex: Bool

    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text([item.code, quote?.tradingStatus].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(PanelNumber.format(quote?.price, digits: isIndex ? 2...2 : 2...4))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    if let unit = isIndex ? "点" : (quote?.currency ?? quote?.unit) {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                    PanelChange(value: quote?.changePercent).frame(minWidth: 57, alignment: .trailing)
                }
                Text(PanelQuoteTime.format(quote?.quotedAt) ?? (quote == nil ? "等待报价" : "暂无行情时间"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(quote?.quotedAt ?? "暂无行情时间")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

enum PanelNumber {
    static func format(_ value: Decimal?, digits: ClosedRange<Int> = 2...2) -> String {
        value?.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(digits))) ?? "—"
    }
}

private enum PanelQuoteTime {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
    )

    static func format(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let text = value as NSString
        guard let match = pattern.firstMatch(in: value, range: NSRange(location: 0, length: text.length)) else { return value }
        let year = text.substring(with: match.range(at: 1))
        let monthDay = text.substring(with: match.range(at: 2))
        let day = year == String(Calendar.current.component(.year, from: .now)) ? monthDay : year + "-" + monthDay
        let timestamp = day + " " + text.substring(with: match.range(at: 3))
        guard match.range(at: 4).location != NSNotFound else { return timestamp }
        let zone = text.substring(with: match.range(at: 4))
        if zone == "Z" || zone == "+00:00" { return timestamp + " UTC" }
        if zone.hasSuffix(":00"), let hour = Int(zone.dropFirst().prefix(2)) {
            let sign = zone.hasPrefix("-") ? "−" : "+"
            return "\(timestamp) UTC\(sign)\(hour)"
        }
        return timestamp + " UTC" + zone
    }
}

private struct PanelChange: View {
    @Environment(\.colorScheme) private var colorScheme
    let value: Decimal?

    var body: some View {
        Text(value.map { ($0 > 0 ? "+" : "") + PanelNumber.format($0) + "%" } ?? "—")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(color)
    }

    private var color: Color {
        guard let value, value != 0 else { return .secondary }
        if colorScheme == .dark {
            return value > 0 ? Color(red: 1, green: 0.54, blue: 0.49) : Color(red: 0.44, green: 0.82, blue: 0.60)
        }
        return value > 0 ? Color(red: 0.70, green: 0.18, blue: 0.16) : Color(red: 0.08, green: 0.44, blue: 0.27)
    }
}

struct PanelNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
