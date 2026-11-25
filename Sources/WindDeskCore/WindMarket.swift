import Foundation

public struct WindMarket {
    private static let quoteFields = "中文简称,最新交易日,交易时间,最新成交价,前收盘价,交易状态"

    public init() {}

    public func indices(apiKey: String) async throws -> [WindQuote] {
        try await indices(WatchItem.indices.map(\.code), apiKey: apiKey)
    }

    public func indices(_ codes: [String], apiKey: String) async throws -> [WindQuote] {
        guard !codes.isEmpty else { return [] }
        return try await snapshots(codes, domain: .index, tool: "get_index_price_indicators", apiKey: apiKey)
    }

    public func stocks(_ codes: [String], apiKey: String) async throws -> [WindQuote] {
        guard !codes.isEmpty else { return [] }
        return try await snapshots(codes, domain: .stock, tool: "get_stock_price_indicators", apiKey: apiKey)
    }

    public func searchStocks(_ query: String, apiKey: String) async throws -> [WatchItem] {
        try await search(query, apiKey: apiKey, maxCount: 10) {
            try QuoteParser.parseSymbols($0, stocksOnly: true)
        }
    }

    public func searchIndices(_ query: String, apiKey: String) async throws -> [WatchItem] {
        try await search(query, apiKey: apiKey, maxCount: 20, parse: QuoteParser.parseIndexSymbols)
    }

    private func search(
        _ query: String, apiKey: String, maxCount: Int, parse: ([String: Any]) throws -> [WatchItem]
    ) async throws -> [WatchItem] {
        guard query.count <= 80, !query.contains(","), !query.contains("，"),
              !query.contains(where: \.isNewline) else { throw WindError.noQuote }
        let client = WindMCP(.global, apiKey: apiKey)
        try await client.connect()
        let result = try await client.call("securities_entities_lookup", arguments: [
            "keyword": query,
            "maxCount": maxCount,
        ])
        do {
            return try parse(result).map { item in
                WatchItem(code: item.code, name: item.name, market: item.market ?? Self.marketName(item.code))
            }
        } catch WindError.noQuote {
            return []
        }
    }

    public struct PreciousQuotes {
        public let gold: Result<WindQuote, Error>
        public let goldCNY: Result<WindQuote, Error>
        public let exchangeRate: Result<WindQuote, Error>?
    }

    public struct LondonGoldCheck {
        public let label: String
        public let result: Result<WindQuote, Error>
    }

    public func checkLondonGold(apiKey: String) async -> [LondonGoldCheck] {
        let client = WindMCP(.global, apiKey: apiKey)
        do {
            let pair = try await directGoldQuotes(client: client)
            var checks = [LondonGoldCheck(label: "SPTAUUSDOZ.IDC · 美元/金衡盎司", result: pair.usd)]
            if case .failure(let error) = pair.usd, Self.shouldStop(after: error) { return checks }
            checks.append(.init(label: "XAUCNY.IDC · 人民币/克", result: pair.cny))
            return checks
        } catch {
            return [.init(label: "Wind 全球行情接入", result: .failure(error))]
        }
    }

    public func preciousQuotes(apiKey: String) async -> PreciousQuotes {
        let client = WindMCP(.global, apiKey: apiKey)
        do {
            let pair = try await directGoldQuotes(client: client)
            var rate: Result<WindQuote, Error>?
            if case .success = pair.usd, case .failure(let error) = pair.cny, !Self.shouldStop(after: error) {
                let onshore = await fetch(.onshore, client: client)
                switch onshore {
                case .failure(WindError.noQuote), .failure(WindError.rejected):
                    rate = await fetch(.offshore, client: client)
                default:
                    rate = onshore
                }
            }
            return PreciousQuotes(gold: pair.usd, goldCNY: pair.cny, exchangeRate: rate)
        } catch {
            return PreciousQuotes(gold: .failure(error), goldCNY: .failure(error), exchangeRate: nil)
        }
    }

    private func directGoldQuotes(client: WindMCP) async throws -> (usd: Result<WindQuote, Error>, cny: Result<WindQuote, Error>) {
        try await client.connect()
        let usd = await fetch(.goldUSD, client: client)
        if case .failure(let error) = usd, Self.shouldStop(after: error) { return (usd, .failure(error)) }
        return (usd, await fetch(.goldCNY, client: client))
    }

    private static func shouldStop(after error: Error) -> Bool {
        if stopsAccountRequests(error) { return true }
        switch error as? WindError {
        case .network, .missingTool: return true
        default: return false
        }
    }

    package static func stopsAccountRequests(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? WindError {
        case .authentication, .rateLimit, .quota, .http(429): return true
        default: return false
        }
    }

    private func fetch(_ instrument: Instrument, client: WindMCP) async -> Result<WindQuote, Error> {
        do {
            // Query the two gold instruments separately to preserve partial results.
            let result = try await client.call("securities_get_price", arguments: ["windCodes": [instrument.rawValue]])
            let quotes = try QuoteParser.parse(result)
            guard let quote = quotes.first(where: { $0.code == instrument.rawValue && $0.price > 0 }),
                  quote.quotedAt != nil else { throw WindError.noQuote }
            guard instrument.acceptsUnits(of: quote) else { throw WindError.invalidResponse }
            return .success(quote.normalized(code: instrument.rawValue, currency: instrument.currency))
        } catch {
            return .failure(error)
        }
    }

    private func snapshots(_ codes: [String], domain: WindMCP.Domain, tool: String, apiKey: String) async throws -> [WindQuote] {
        let client = WindMCP(domain, apiKey: apiKey)
        try await client.connect()
        var quotes: [WindQuote] = []
        for start in stride(from: 0, to: codes.count, by: 50) {
            let batch = codes[start..<min(start + 50, codes.count)]
            let result = try await client.call(tool, arguments: [
                "windcode": batch.joined(separator: ","),
                "indexes": Self.quoteFields,
            ])
            quotes += try QuoteParser.parse(result)
        }
        if domain == .index { return Self.matchIndexQuotes(quotes, to: codes) }
        return quotes.compactMap { quote -> WindQuote? in
            guard quote.price > 0 else { return nil }
            let code = quote.code.uppercased()
            return quote.normalized(code: code, currency: quote.currency ?? Self.stockCurrency(code))
        }
    }

    static func matchIndexQuotes(_ quotes: [WindQuote], to codes: [String]) -> [WindQuote] {
        let requested = Set(codes.map { $0.uppercased() })
        let byTicker = Dictionary(grouping: requested) { $0.prefix(while: { $0 != "." }) }
        let positiveQuotes = quotes.filter { $0.price > 0 }
        let exactMatches = requested.intersection(positiveQuotes.map { $0.code.uppercased() })
        return positiveQuotes.compactMap { quote in
            let code = quote.code.uppercased()
            if requested.contains(code) { return quote.normalized(code: code) }
            // Some index replies omit the exchange suffix. Resolve those only
            // against a unique requested ticker and prefer the qualified quote.
            guard !code.contains("."), let candidates = byTicker[code[...]], candidates.count == 1,
                  let matched = candidates.first, !exactMatches.contains(matched) else { return nil }
            return quote.normalized(code: matched)
        }
    }

    private enum Instrument: String {
        case goldUSD = "SPTAUUSDOZ.IDC"
        case goldCNY = "XAUCNY.IDC"
        case onshore = "USDCNY.IB"
        case offshore = "USDCNH.FX"

        var currency: String {
            switch self {
            case .goldUSD: "USD"
            case .goldCNY, .onshore: "CNY"
            case .offshore: "CNH"
            }
        }

        func acceptsUnits(of quote: WindQuote) -> Bool {
            let acceptedCurrencies: [String]
            let incompatibleUnits: [String]
            switch self {
            case .goldUSD:
                acceptedCurrencies = ["USD", "US$", "美元", "美金"]
                incompatibleUnits = ["cny", "cnh", "人民币", "/克", "/g", "每克", "gram", "千克", "kg"]
            case .goldCNY:
                acceptedCurrencies = ["CNY", "人民币", "在岸人民币"]
                incompatibleUnits = ["usd", "美元", "cnh", "离岸", "oz", "ounce", "盎司", "千克", "kg"]
            case .onshore:
                acceptedCurrencies = ["CNY", "人民币", "在岸人民币"]
                incompatibleUnits = []
            case .offshore:
                acceptedCurrencies = ["CNH", "离岸人民币", "人民币"]
                incompatibleUnits = []
            }
            if let currency = quote.currency, !acceptedCurrencies.contains(currency.uppercased()) { return false }
            guard let unit = quote.unit?.lowercased() else { return true }
            return !incompatibleUnits.contains(where: unit.contains)
        }
    }

    private static func marketName(_ code: String) -> String? {
        switch code.split(separator: ".").last {
        case "SH": "上交所"
        case "SZ": "深交所"
        case "BJ": "北交所"
        case "O": "纳斯达克"
        case "N": "纽交所"
        case "HK": "港交所"
        default: nil
        }
    }

    private static func stockCurrency(_ code: String) -> String? {
        switch code.split(separator: ".").last {
        case "SH", "SZ", "BJ": "CNY"
        case "O", "N": "USD"
        case "HK": "HKD"
        default: nil
        }
    }

}
