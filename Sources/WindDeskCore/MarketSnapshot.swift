import Foundation

public enum QuoteSection: String, Hashable {
    case gold, goldCNY, fx, indices, stocks
}

public struct WatchItem: Identifiable, Codable, Equatable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let market: String?

    public init(code: String, name: String, market: String? = nil) {
        self.code = code
        self.name = name
        self.market = market
    }

    public static let indices = [
        WatchItem(code: "NDX.GI", name: "纳斯达克 100", market: "美国"),
        WatchItem(code: "000688.SH", name: "科创 50", market: "上交所"),
        WatchItem(code: "399673.SZ", name: "创业板 50", market: "深交所"),
        WatchItem(code: "000001.SH", name: "上证指数", market: "上交所")
    ]
}

public struct WindQuote: Codable, Equatable {
    public let code: String
    public let name: String?
    public let price: Decimal
    public let previousClose: Decimal?
    public let quotedAt: String?
    public let currency: String?
    public let unit: String?
    public let tradingStatus: String?
    public let reportedChangePercent: Decimal?

    public init(
        code: String,
        name: String? = nil,
        price: Decimal,
        previousClose: Decimal? = nil,
        quotedAt: String? = nil,
        currency: String? = nil,
        unit: String? = nil,
        tradingStatus: String? = nil,
        reportedChangePercent: Decimal? = nil
    ) {
        self.code = code
        self.name = name
        self.price = price
        self.previousClose = previousClose
        self.quotedAt = quotedAt
        self.currency = currency
        self.unit = unit
        self.tradingStatus = tradingStatus
        self.reportedChangePercent = reportedChangePercent
    }

    public var changePercent: Decimal? {
        guard let previousClose, previousClose > 0 else { return reportedChangePercent }
        return (price / previousClose - 1) * 100
    }

    func normalized(code: String, currency: String? = nil) -> Self {
        .init(
            code: code, name: name, price: price, previousClose: previousClose,
            quotedAt: quotedAt, currency: currency ?? self.currency, unit: unit,
            tradingStatus: tradingStatus, reportedChangePercent: reportedChangePercent
        )
    }
}

public struct MarketSnapshot: Codable, Equatable {
    public var gold: WindQuote?
    public var goldCNY: WindQuote?
    public var fx: WindQuote?
    public var indices: [WindQuote] = []
    public var stocks: [WindQuote] = []
    public var lastRefresh: Date?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case gold, goldCNY, fx, indices, stocks, lastRefresh
    }

    private enum LegacyKeys: String, CodingKey {
        case goldSource
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        indices = try values.decodeIfPresent([WindQuote].self, forKey: .indices) ?? []
        stocks = try values.decodeIfPresent([WindQuote].self, forKey: .stocks) ?? []
        lastRefresh = try values.decodeIfPresent(Date.self, forKey: .lastRefresh)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        // Early versions cached the previous provider's gold and FX alongside Wind indices.
        if try legacy.decodeIfPresent(String.self, forKey: .goldSource) == "goldAPI" {
            if indices.isEmpty && stocks.isEmpty { lastRefresh = nil }
            return
        }
        gold = try values.decodeIfPresent(WindQuote.self, forKey: .gold)
        goldCNY = try values.decodeIfPresent(WindQuote.self, forKey: .goldCNY)
        fx = try values.decodeIfPresent(WindQuote.self, forKey: .fx)
    }

    private var directGoldCNYPrice: Decimal? {
        guard let goldCNY, goldCNY.code == "XAUCNY.IDC", goldCNY.currency == "CNY", goldCNY.price > 0 else { return nil }
        return goldCNY.price
    }

    public var usesConvertedGoldCNY: Bool {
        directGoldCNYPrice == nil && goldCNYPerGram != nil
    }

    public var goldCNYPerGram: Decimal? {
        if let directGoldCNYPrice { return directGoldCNYPrice }
        guard let gold, let fx, gold.price > 0, fx.price > 0,
              gold.currency == "USD", fx.currency == "CNY" || fx.currency == "CNH" else { return nil }
        return gold.price * fx.price / Decimal(string: "31.1034768")!
    }
}
