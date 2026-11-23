import OSLog
import SwiftUI
import WidgetKit
import WindDeskCore

private struct QuoteEntry: TimelineEntry {
    let date: Date
    let cache: WidgetQuoteCache.Entry?
    var isPlaceholder = false
}

private struct QuoteProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "com.winddesk.menubar.widget", category: "Timeline")

    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: .now, cache: nil, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        let cache = WidgetQuoteCache.read()
        completion(QuoteEntry(date: .now, cache: cache, isPlaceholder: context.isPreview && cache == nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        let cache: WidgetQuoteCache.Entry?
        do {
            cache = try WidgetQuoteCache.readSnapshot()
            let time = cache?.snapshot.lastRefresh?.ISO8601Format() ?? "none"
            Self.logger.notice("getTimeline cache=available lastRefresh=\(time, privacy: .public)")
        } catch {
            cache = nil
            let error = error as NSError
            Self.logger.notice("getTimeline cache=unavailable domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
        }
        let entry = QuoteEntry(date: .now, cache: cache)
        // The app requests a reload after writing. Also schedule a local reread in
        // case WidgetKit defers or coalesces that request.
        let interval = cache?.reloadInterval ?? WidgetQuoteCache.defaultReloadInterval
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(interval))))
    }
}

@main
struct WindDeskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetQuoteCache.kind, provider: QuoteProvider()) { entry in
            QuoteWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("黄金与市场指数")
        .description("查看两种单位的伦敦金、四个市场指数和自选股的最新行情快照。")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct QuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: QuoteEntry

    private var isLarge: Bool { family == .systemLarge }
    private var snapshot: MarketSnapshot { entry.cache?.snapshot ?? MarketSnapshot() }
    private var watchlist: [WatchItem] { Array((entry.cache?.watchlist ?? []).prefix(3)) }
    private var hasQuotes: Bool {
        snapshot.gold != nil || snapshot.goldCNYPerGram != nil || !snapshot.indices.isEmpty
            || (isLarge && watchlist.contains { item in snapshot.stocks.contains { $0.code == item.code } })
    }

    var body: some View {
        Group {
            if !entry.isPlaceholder && !hasQuotes {
                VStack(alignment: .leading, spacing: 7) {
                    Text("暂无行情快照").font(.headline)
                    Text("在菜单栏打开 WindDesk 并刷新。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: isLarge ? 8 : 5) {
                    goldHeader
                    goldPrices
                    Divider()
                    if isLarge {
                        expandedMarkets
                    } else {
                        compactIndices
                    }
                }
                .redacted(reason: entry.isPlaceholder ? .placeholder : [])
                .accessibilityHidden(entry.isPlaceholder)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, isLarge ? 15 : 12)
        .padding(.vertical, isLarge ? 14 : 9)
    }

    private var goldHeader: some View {
        HStack(spacing: 5) {
            Text("伦敦金现货").fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Text(snapshotLabel).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private var snapshotLabel: String {
        guard let lastRefresh = snapshot.lastRefresh else { return "Wind Alice · 快照" }
        let format: Date.FormatStyle = Calendar.current.isDate(lastRefresh, inSameDayAs: entry.date)
            ? .dateTime.hour().minute().second()
            : .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
        return "Wind Alice · 快照 " + lastRefresh.formatted(format)
    }

    private var goldPrices: some View {
        let isConverted = snapshot.usesConvertedGoldCNY
        let yuanUnit = snapshot.fx?.currency == "CNH" && isConverted ? "离岸元/克" : "元/克"
        let yuanPrice = snapshot.goldCNYPerGram
        let yuanTime = isConverted ? snapshot.fx?.quotedAt : (yuanPrice == nil ? nil : snapshot.goldCNY?.quotedAt)
        return HStack(spacing: 10) {
            goldValue(snapshot.gold?.price, unit: "美元/盎司", at: snapshot.gold?.quotedAt, spokenUnit: "美元/金衡盎司")
            Divider()
            goldValue(yuanPrice, unit: yuanUnit, at: yuanTime, timeLabel: isConverted ? "汇率" : nil,
                      spokenUnit: isConverted ? yuanUnit + "，汇率折算" : nil)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func goldValue(
        _ price: Decimal?, unit: String, at time: String?, timeLabel: String? = nil, spokenUnit: String? = nil
    ) -> some View {
        let timePrefix = timeLabel.map { $0 + " " } ?? ""
        let accessibleUnit = spokenUnit ?? unit
        let priceLabel = price.map { formatted($0) + " " + accessibleUnit } ?? accessibleUnit + " 暂无报价"
        return VStack(alignment: .leading, spacing: 1) {
            Text((timeLabel != nil && price != nil ? "≈" : "") + formatted(price))
                .font(.system(size: isLarge ? 23 : 18, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 3) {
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary).layoutPriority(1)
                Spacer(minLength: 1)
                quoteTimeLabel(time, prefix: timePrefix, size: 9)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(priceLabel + spokenTime(time, label: timeLabel ?? "报价", hasQuote: price != nil))
    }

    private var compactIndices: some View {
        let items = WatchItem.indices
        return VStack(spacing: 5) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { first in
                HStack(spacing: 12) {
                    ForEach(items[first..<min(first + 2, items.count)], content: compactIndex)
                }
            }
        }
    }

    private func compactIndex(_ item: WatchItem) -> some View {
        let quote = snapshot.indices.first { $0.code == item.code }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.name).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 1)
                quoteTimeLabel(quote?.quotedAt, size: 9)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(formatted(quote?.price)).font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Spacer(minLength: 1)
                change(quote?.changePercent)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.82)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenMarket(item, quote: quote, unit: "点"))
    }

    @ViewBuilder private var expandedMarkets: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeading("市场指数")
            ForEach(WatchItem.indices) { item in
                marketRow(item, quote: snapshot.indices.first { $0.code == item.code }, unit: "点")
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            let total = entry.cache?.watchlist.count ?? 0
            sectionHeading("自选股", detail: total > watchlist.count ? "前 \(watchlist.count) 只" : nil)
            if watchlist.isEmpty {
                Text("在菜单栏添加自选股。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(watchlist) { item in
                    let quote = snapshot.stocks.first { $0.code == item.code }
                    marketRow(item, quote: quote, unit: quote?.currency ?? quote?.unit)
                }
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let detail {
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func marketRow(_ item: WatchItem, quote: WindQuote?, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(item.name).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            quoteTimeLabel(quote?.quotedAt, size: 9)
                .frame(width: 64, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(formatted(quote?.price, digits: unit == "点" ? 2...2 : 2...4))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                if let unit, quote != nil {
                    Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(width: 72, alignment: .trailing)
            change(quote?.changePercent).frame(width: 45, alignment: .trailing)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenMarket(item, quote: quote, unit: unit))
    }

    private func change(_ value: Decimal?) -> some View {
        let color: Color = switch value {
        case let value? where value > 0:
            colorScheme == .dark ? .pink : Color(red: 0.7, green: 0.16, blue: 0.22)
        case let value? where value < 0:
            colorScheme == .dark ? Color(red: 0.44, green: 0.81, blue: 0.59) : Color(red: 0.11, green: 0.43, blue: 0.25)
        default: .secondary
        }
        return Text(value.map(signedPercent) ?? "—")
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(color)
    }

    private func formatted(_ value: Decimal?, digits: ClosedRange<Int> = 2...2) -> String {
        value?.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(digits))) ?? "—"
    }

    private func signedPercent(_ value: Decimal) -> String {
        (value > 0 ? "+" : "") + formatted(value) + "%"
    }

    private func spokenMarket(_ item: WatchItem, quote: WindQuote?, unit: String?) -> String {
        guard let quote else { return item.name + "，暂无报价" }
        let price = formatted(quote.price, digits: unit == "点" ? 2...2 : 2...4)
        let change = quote.changePercent.map { "，涨跌幅 " + signedPercent($0) } ?? ""
        return item.name + "，" + price + (unit.map { " " + $0 } ?? "") + change
            + spokenTime(quote.quotedAt, label: "报价", hasQuote: true)
    }

    private func spokenTime(_ time: String?, label: String, hasQuote: Bool) -> String {
        guard hasQuote else { return "" }
        if let time, !time.isEmpty { return "，" + label + "时间 " + time }
        return "，" + label + "时间未知"
    }

    private func quoteTimeLabel(_ time: String?, prefix: String = "", size: CGFloat) -> some View {
        Text(time.map { prefix + compactQuoteTime($0) } ?? "—")
            .font(.system(size: size)).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func compactQuoteTime(_ time: String) -> String {
        // Preserve each market's date. Remove seconds only when the provider supplied a recognizable clock time.
        let parts = time.replacingOccurrences(of: "T", with: " ").split(separator: " ", maxSplits: 1)
        guard let day = parts.first,
              day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return time.isEmpty ? "—" : time
        }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: entry.date)
        let date = String(day.dropFirst(Int(day.prefix(4)) == thisYear ? 5 : 2))
        guard parts.count > 1 else { return date }
        let clock = parts[1].prefix(5)
        guard clock.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return time }
        return date + " " + clock
    }
}
