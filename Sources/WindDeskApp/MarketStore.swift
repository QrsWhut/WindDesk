import Foundation
import Observation
import OSLog
import WidgetKit
import WindDeskCore

enum AutoRefreshInterval: Int, CaseIterable {
    case off = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case hourly = 60

    var title: String { self == .off ? "关闭" : "\(rawValue) 分钟" }
}

@MainActor
@Observable
final class MarketStore {
    private static let autoRefreshPreference = "auto-refresh-minutes"
    private static let refreshResultPreference = "market-refresh-result"
    private static let widgetLog = Logger(subsystem: "com.winddesk.menubar", category: "WidgetSync")

    private(set) var hasKey = false
    private(set) var refreshStage: String?
    var isRefreshing: Bool { refreshStage != nil }
    private(set) var snapshot = MarketSnapshot()
    private(set) var watchlist: [WatchItem] = []
    private(set) var issues: [QuoteSection: String] = [:]
    private(set) var searchResults: [WatchItem] = []
    private(set) var searchError: String?
    private(set) var settingsError: String?
    private(set) var widgetError: String?
    private(set) var isSearching = false
    private(set) var isCheckingWindGold = false
    private(set) var windGoldCheckLines: [String] = []
    var lastRefresh: Date? { snapshot.lastRefresh }
    var autoRefreshInterval: AutoRefreshInterval {
        didSet {
            guard autoRefreshInterval != oldValue else { return }
            defaults.set(autoRefreshInterval.rawValue, forKey: Self.autoRefreshPreference)
            publishWidget()
            scheduleAutoRefresh(alignWithLastAttempt: true)
        }
    }

    @ObservationIgnored private let market = WindMarket()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var keyRevision = 0
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?

    private var isWindRequestInProgress: Bool { isRefreshing || isCheckingWindGold || isSearching }

    init() {
        let savedInterval = defaults.object(forKey: Self.autoRefreshPreference) as? Int
        autoRefreshInterval = savedInterval.flatMap(AutoRefreshInterval.init(rawValue:)) ?? .tenMinutes
        snapshot = decode(MarketSnapshot.self, key: "market-snapshot") ?? .init()
        watchlist = decode([WatchItem].self, key: "watchlist") ?? []
        do {
            apiKey = try CredentialStore.read()
            hasKey = apiKey != nil
        } catch {
            settingsError = error.localizedDescription
        }
        if let summary = defaults.dictionary(forKey: Self.refreshResultPreference),
           let messages = summary["issues"] as? [String: String] {
            for (name, message) in messages {
                if let section = QuoteSection(rawValue: name) { issues[section] = message }
            }
        }
        publishWidget(forceReload: true)
        scheduleAutoRefresh(alignWithLastAttempt: true)
    }

    deinit {
        scheduledRefresh?.cancel()
    }

    func saveKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            settingsError = "请输入完整的 Wind Alice API Key。"
            return false
        }
        do {
            try CredentialStore.save(key)
            activateKey(key, keepLegacyCache: false)
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
    }

    func migrateKey() -> Bool {
        do {
            guard let key = try CredentialStore.migrateFromKeychain() else {
                settingsError = "钥匙串里没有已保存的 Wind Key，可在上方填写。"
                return false
            }
            activateKey(key, keepLegacyCache: apiKey == nil)
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
    }

    private func activateKey(_ key: String, keepLegacyCache: Bool) {
        if apiKey != key {
            keyRevision += 1
            refreshStage = nil
            if !keepLegacyCache {
                snapshot = .init()
                issues = [:]
                searchResults = []
                searchError = nil
                windGoldCheckLines = []
                persist(snapshot, key: "market-snapshot")
                defaults.removeObject(forKey: Self.refreshResultPreference)
                defaults.removeObject(forKey: "wind-london-gold-check")
                publishWidget()
            }
        }
        apiKey = key
        hasKey = true
        settingsError = nil
        scheduleAutoRefresh(alignWithLastAttempt: true)
    }

    private func scheduleAutoRefresh(alignWithLastAttempt: Bool = false) {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        guard hasKey, !isRefreshing, autoRefreshInterval != .off else { return }
        let interval = TimeInterval(autoRefreshInterval.rawValue * 60)
        let delay: TimeInterval
        if alignWithLastAttempt {
            let lastAttempt = defaults.dictionary(forKey: Self.refreshResultPreference)?["attemptedAt"] as? Date
            delay = lastAttempt.map { max(0, interval - max(0, Date().timeIntervalSince($0))) } ?? 0
        } else {
            delay = interval
        }
        scheduledRefresh = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(5))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.scheduledRefresh = nil
            if self.isWindRequestInProgress {
                self.scheduleAutoRefresh()
            } else {
                await self.refresh(requestWidgetReload: false)
            }
        }
    }

    func refresh(requestWidgetReload: Bool = true) async {
        guard let apiKey, !isWindRequestInProgress, !Task.isCancelled else { return }
        let revision = keyRevision
        let started = Date()
        let original = snapshot
        var receivedResult = false
        refreshStage = "伦敦金"
        defer {
            if revision == keyRevision {
                refreshStage = nil
                if receivedResult {
                    let snapshotChanged = snapshot != original
                    if snapshotChanged { persist(snapshot, key: "market-snapshot") }
                    if snapshotChanged || requestWidgetReload { publishWidget(forceReload: requestWidgetReload) }
                    let messages = Dictionary(uniqueKeysWithValues: issues.map { ($0.key.rawValue, $0.value) })
                    defaults.set(["attemptedAt": started, "issues": messages], forKey: Self.refreshResultPreference)
                }
                scheduleAutoRefresh()
            }
        }

        // The transport spaces requests across all Wind endpoints. Publish each
        // section to the panel as it arrives, then write one widget snapshot.
        let precious = await market.preciousQuotes(apiKey: apiKey)
        guard revision == keyRevision, !Task.isCancelled else { return }
        receivedResult = true
        applyPrecious(precious)
        if let error = accountError(in: precious.gold) ?? accountError(in: precious.goldCNY) ?? accountError(in: precious.exchangeRate) {
            markSkipped(.indices, error: error)
            if !watchlist.isEmpty { markSkipped(.stocks, error: error) }
            return
        }

        refreshStage = "指数"
        guard revision == keyRevision, !Task.isCancelled else { return }
        let indexResult = await collect { try await market.indices(apiKey: apiKey) }
        guard revision == keyRevision, !Task.isCancelled else { return }
        let indexCodes = WatchItem.indices.map(\.code)
        applyBatch(indexResult, section: .indices, path: \.indices, requested: Set(indexCodes), order: indexCodes)
        guard !watchlist.isEmpty else {
            setIssue(nil, for: .stocks)
            return
        }
        if let error = accountError(in: indexResult) {
            markSkipped(.stocks, error: error)
            return
        }

        refreshStage = "自选股"
        guard revision == keyRevision, !Task.isCancelled else { return }
        let requested = watchlist.map(\.code)
        guard !requested.isEmpty else {
            setIssue(nil, for: .stocks)
            return
        }
        let stockResult = await collect { try await market.stocks(requested, apiKey: apiKey) }
        guard revision == keyRevision, !Task.isCancelled else { return }
        applyBatch(stockResult, section: .stocks, path: \.stocks, requested: Set(requested), order: watchlist.map(\.code))
    }

    private func applyPrecious(_ precious: WindMarket.PreciousQuotes) {
        var latest = snapshot
        var receivedQuote = false
        func apply(_ result: Result<WindQuote, Error>, section: QuoteSection, to path: WritableKeyPath<MarketSnapshot, WindQuote?>) {
            switch result {
            case .success(let quote):
                if Self.isOlder(quote, than: latest[keyPath: path]) {
                    setIssue("返回的行情时间早于已保存报价，保留较新报价。", for: section)
                } else {
                    latest[keyPath: path] = quote
                    receivedQuote = true
                    setIssue(nil, for: section)
                }
            case .failure(let error):
                setIssue(error.localizedDescription, for: section)
            }
        }
        apply(precious.gold, section: .gold, to: \.gold)
        apply(precious.goldCNY, section: .goldCNY, to: \.goldCNY)
        if let rate = precious.exchangeRate {
            apply(rate, section: .fx, to: \.fx)
        } else {
            setIssue(nil, for: .fx)
            if case .success = precious.goldCNY { latest.fx = nil }
        }
        if receivedQuote { latest.lastRefresh = Date() }
        if latest != snapshot { snapshot = latest }
    }

    private func applyBatch(
        _ result: Result<[WindQuote], Error>, section: QuoteSection, path: WritableKeyPath<MarketSnapshot, [WindQuote]>,
        requested: Set<String>, order: [String]
    ) {
        guard order.contains(where: requested.contains) else {
            setIssue(nil, for: section)
            return
        }
        switch result {
        case .failure(let error):
            setIssue(error.localizedDescription, for: section)
        case .success(let quotes):
            let byCode = Dictionary(quotes.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            let cached = Dictionary(snapshot[keyPath: path].map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            var missing: [String] = []
            var older: [String] = []
            var receivedQuote = false
            let updated: [WindQuote] = order.compactMap { code in
                guard requested.contains(code) else { return cached[code] }
                guard let incoming = byCode[code] else {
                    missing.append(code)
                    return cached[code]
                }
                if Self.isOlder(incoming, than: cached[code]) {
                    older.append(code)
                    return cached[code]
                }
                receivedQuote = true
                return incoming
            }
            let messages = [(missing, "本次没有报价"), (older, "返回行情较早，保留已有报价")].compactMap { codes, reason -> String? in
                guard !codes.isEmpty else { return nil }
                let suffix = codes.count > 3 ? "等 \(codes.count) 只" : ""
                return codes.prefix(3).joined(separator: "、") + suffix + reason + "。"
            }
            setIssue(messages.isEmpty ? nil : messages.joined(separator: " "), for: section)
            var latest = snapshot
            latest[keyPath: path] = updated
            if receivedQuote { latest.lastRefresh = Date() }
            if latest != snapshot { snapshot = latest }
        }
    }

    // Compare only source timestamps with an unambiguous offset, for the same instrument.
    // Wind can also return a market-local date or time without an offset.
    private static func isOlder(_ incoming: WindQuote, than cached: WindQuote?) -> Bool {
        guard let cached, incoming.code == cached.code,
              let next = incoming.quotedAt, let old = cached.quotedAt, next != old,
              let nextDate = sourceTime(next), let oldDate = sourceTime(old) else { return false }
        return nextDate < oldDate
    }

    private static func sourceTime(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle().parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
    }

    private func accountError<T>(in result: Result<T, Error>?) -> Error? {
        guard case .failure(let error) = result, WindMarket.stopsAccountRequests(error) else { return nil }
        return error
    }

    private func markSkipped(_ section: QuoteSection, error: Error) {
        setIssue("本次未请求。" + error.localizedDescription, for: section)
    }

    private func setIssue(_ message: String?, for section: QuoteSection) {
        if issues[section] != message { issues[section] = message }
    }

    func checkWindGold() async {
        guard let apiKey, !isWindRequestInProgress else { return }
        let revision = keyRevision
        isCheckingWindGold = true
        windGoldCheckLines = []
        defer { isCheckingWindGold = false }

        let checks = await market.checkLondonGold(apiKey: apiKey)
        guard revision == keyRevision, !Task.isCancelled else { return }
        let lines = checks.map { check in
            switch check.result {
            case .success(let quote):
                let price = quote.price.formatted(.number.locale(Locale(identifier: "en_US")))
                return [check.label, price, quote.quotedAt].compactMap { $0 }.joined(separator: " · ")
            case .failure(let error):
                return check.label + " · " + error.localizedDescription
            }
        }
        windGoldCheckLines = lines
        defaults.set(["attemptedAt": Date(), "results": lines], forKey: "wind-london-gold-check")
    }

    func search(_ text: String) async {
        guard !isWindRequestInProgress else { return }
        searchResults = []
        searchError = nil
        guard let apiKey else {
            searchError = "请先在设置中保存 API Key。"
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let revision = keyRevision
        isSearching = true
        defer { isSearching = false }
        do {
            let matches = try await market.searchStocks(query, apiKey: apiKey)
            guard keyRevision == revision, !Task.isCancelled else { return }
            searchResults = matches
            if matches.isEmpty { searchError = "未找到匹配的股票。可尝试完整 Wind 代码。" }
        } catch {
            guard keyRevision == revision, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    func add(_ item: WatchItem) {
        guard !watchlist.contains(where: { $0.code == item.code }) else { return }
        watchlist.append(item)
        persist(watchlist, key: "watchlist")
        publishWidget()
    }

    func remove(_ item: WatchItem) {
        watchlist.removeAll(where: { $0.code == item.code })
        snapshot.stocks.removeAll(where: { $0.code == item.code })
        if watchlist.isEmpty { issues[.stocks] = nil }
        persist(watchlist, key: "watchlist")
        persist(snapshot, key: "market-snapshot")
        publishWidget()
    }

    func move(_ item: WatchItem, by offset: Int) {
        guard let index = watchlist.firstIndex(of: item), watchlist.indices.contains(index + offset) else { return }
        watchlist.swapAt(index, index + offset)
        persist(watchlist, key: "watchlist")
        publishWidget()
    }

    private func publishWidget(forceReload: Bool = false) {
        do {
            let interval = autoRefreshInterval == .off ? nil : autoRefreshInterval.rawValue
            let entry = WidgetQuoteCache.Entry(snapshot: snapshot, watchlist: watchlist, refreshIntervalMinutes: interval)
            let changed = try WidgetQuoteCache.write(entry)
            widgetError = nil
            if changed || forceReload {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetQuoteCache.kind)
                Self.widgetLog.notice("Requested widget reload for snapshot \(self.snapshot.lastRefresh?.timeIntervalSince1970 ?? 0, privacy: .public)")
            }
        } catch {
            widgetError = "桌面小组件暂时无法读取最新行情快照。"
            Self.widgetLog.error("Could not publish the widget snapshot")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func collect<T>(_ fetch: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await fetch())
        } catch {
            return .failure(error)
        }
    }
}
