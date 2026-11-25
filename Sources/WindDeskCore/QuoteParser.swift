import CoreFoundation
import Foundation

/// Reads MCP tool results. Only an explicit instrument identifier paired with a price
/// can produce a quote; status codes and the order of a batch are never identifiers.
public enum QuoteParser {
    private typealias Row = [String: Any]

    public static func parse(_ result: [String: Any]) throws -> [WindQuote] {
        try parseResult(result, decode: quote, identity: { $0.code })
    }

    public static func parseSymbols(_ result: [String: Any], stocksOnly: Bool = false) throws -> [WatchItem] {
        try parseSymbols(result, categories: stocksOnly ? equityCategories : nil)
    }

    static func parseIndexSymbols(_ result: [String: Any]) throws -> [WatchItem] {
        try parseSymbols(result, categories: indexCategories).filter { qualifiedCode($0.code) }
    }

    private static func parseSymbols(_ result: [String: Any], categories acceptedCategories: Set<String>?) throws -> [WatchItem] {
        try parseResult(result, allowEmpty: true, decode: { row in
            if let acceptedCategories {
                guard let type = string(first(row, categories)), acceptedCategories.contains(key(type)) else { return nil }
            }
            guard let code = instrumentCode(row), let name = string(first(row, names)) else { return nil }
            return WatchItem(code: code, name: name, market: string(first(row, markets)))
        }, identity: { $0.code })
    }

    private static func parseResult<T: Equatable>(
        _ result: Row, allowEmpty: Bool = false, decode: (Row) -> T?, identity: (T) -> String
    ) throws -> [T] {
        if result["isError"] as? Bool == true {
            let blocks = result["content"] as? [Row]
            throw WindError.fromServiceMessage(blocks?.first?["text"] as? String)
        }
        var parsed: [T] = []
        if let structured = result["structuredContent"] {
            parsed = try records(in: structured, decode: decode)
        }
        // MCP often returns the same data through both representations.
        if parsed.isEmpty, let blocks = result["content"] as? [Row] {
            for block in blocks where block["type"] as? String == "text" || block["type"] == nil {
                if let text = block["text"] as? String {
                    parsed += try records(in: text, decode: decode)
                }
            }
        }
        if result["structuredContent"] == nil, result["content"] == nil {
            parsed = try records(in: result, decode: decode)
        }
        guard !parsed.isEmpty || allowEmpty else { throw WindError.noQuote }
        var byCode: [String: T] = [:]
        var unique: [T] = []
        for quote in parsed {
            let code = identity(quote)
            if let existing = byCode[code] {
                guard existing == quote else { throw WindError.invalidResponse }
            } else {
                byCode[code] = quote
                unique.append(quote)
            }
        }
        return unique
    }

    private static let codes = ["windcode", "wind代码", "万得代码", "证券代码", "指数代码", "股票代码", "品种代码", "标准代码", "代码", "seccode", "sinfowindcode", "instrumentcode", "securitycode", "indexcode", "symbol", "ticker", "code"]
    private static let names = ["中文简称", "证券简称", "指数简称", "股票简称", "证券名称", "指数名称", "品种名称", "股票名称", "简称", "secshortname", "sinfoname", "shortname", "名称", "secname", "securityname", "name", "rtsecname"]
    private static let prices = ["最新成交价", "最新价", "最新点位", "最新价格", "即期汇率", "现价", "最新汇率", "最新值", "lastprice", "latestprice", "lasttradeprice", "rtlatest", "tradeprice", "rtlast", "match", "last", "price"]
    private static let prior = ["前收盘价", "昨收盘价", "前收盘", "昨收", "昨收盘", "昨收点位", "previousclose", "preclose", "prevclose", "rtpreclose"]
    private static let changes = ["涨跌幅", "当日涨跌幅", "日涨跌幅", "rtpctchg", "pctchg", "changepercent", "percentchange", "pctchange", "changepct"]
    private static let currencies = ["报价币种", "计价货币", "报价货币", "交易币种", "币种", "货币", "quotecurrency", "currency"]
    private static let units = ["报价单位", "计价单位", "价格单位", "单位", "priceunit", "quoteunit", "indicatorunits", "unit"]
    // Lookup categories are a provider reference value, with no published complete enum.
    // An unfamiliar or missing category is left out of typed searches.
    private static let categories = ["category", "securitytype", "assettype", "证券类型", "证券类别", "资产类别"]
    private static let equityCategories: Set<String> = ["股票", "a股", "b股", "港股", "美股", "沪深a股", "北交所股票", "普通股", "stock", "stocks", "equity", "equities", "commonstock"]
    private static let indexCategories: Set<String> = ["指数", "市场指数", "股票指数", "index", "indices", "marketindex", "stockindex"]
    private static let markets = ["市场", "交易市场", "交易所", "market", "exchange", "marketname"]
    private static let statuses = ["交易状态", "市场状态", "tradingstatus", "tradestatus", "marketstatus", "rttradestatus"]
    private static let dates = ["最新交易日", "交易日期", "交易日", "日期", "tradedate", "tradingdate", "rtdate", "date"]
    private static let times = ["交易时间", "时间", "tradetime", "tradingtime", "rttime", "time"]
    private static let timestamps = ["行情时间", "报价时间", "数据时间", "quotedat", "datetime", "timestamp", "asof", "quotetime"]

    private static func records<T>(
        in node: Any, metadata: Row = [:], depth: Int = 0, decode: (Row) -> T?
    ) throws -> [T] {
        guard depth < 20 else { throw WindError.invalidResponse }
        if let text = node as? String {
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return [] }
            return try records(in: value, metadata: metadata, depth: depth + 1, decode: decode)
        }
        if let list = node as? [Any] {
            if let rows = list as? [Row], let grouped = try pivotIndicators(rows, metadata: metadata) {
                return grouped.compactMap(decode)
            }
            return try list.flatMap { try records(in: $0, metadata: metadata, depth: depth + 1, decode: decode) }
        }
        guard let original = node as? Row else { return [] }
        let row = normalized(original)
        try checkBusinessStatus(row)
        if let enclosingCode = instrumentCode(metadata), let rowCode = instrumentCode(row), enclosingCode != rowCode {
            throw WindError.invalidResponse
        }
        if row["type"] as? String == "text", let text = row["text"] as? String {
            return try records(in: text, metadata: metadata, depth: depth + 1, decode: decode)
        }
        // Carry only quote metadata across levels. A wrapper's numeric HTTP status
        // in "code" must not propagate into instrument rows.
        var shared = metadata
        for key in inheritedKeys {
            if let value = row[key] { shared[key] = value }
        }
        if let explicit = row["code"] as? String, qualifiedCode(explicit) { shared["code"] = explicit }
        let merged = shared.merging(row) { _, current in current }
        if let record = decode(merged) { return [record] }

        // Standard Wind field-major matrix. Each field has one value per security.
        if let fields = row["fields"] as? [String], let securities = row["codes"] as? [String],
           let values = row["data"] as? [[Any]] {
            guard fields.count == values.count,
                  values.allSatisfy({ $0.count == securities.count }) else { throw WindError.invalidResponse }
            return securities.enumerated().compactMap { index, code in
                var record = shared
                record["windcode"] = code
                for (fieldIndex, field) in fields.enumerated() {
                    record[key(field)] = values[fieldIndex][index]
                }
                return decode(record)
            }
        }

        // Wind One uses columnNames/rows; some tables attach unit and name to each column.
        if let headers = (row["columnnames"] ?? row["columns"] ?? row["fields"]) as? [Any],
           let values = (row["rows"] ?? row["data"]) as? [[Any]] {
            var fields: [String] = []
            for header in headers {
                if let field = header as? String {
                    fields.append(key(field))
                } else if let definition = header as? Row {
                    let column = normalized(definition)
                    let labels = ["label", "title", "displayname", "name", "field", "code", "key"].compactMap { string(column[$0]) }
                    let recognized = labels.map(key).first(where: knownKeys.contains)
                    guard let field = recognized ?? labels.first.map(key) else { throw WindError.invalidResponse }
                    fields.append(field)
                    if changes.contains(field), let changeUnit = string(first(column, units)) {
                        var fieldUnits = shared["indicatorunits"] as? Row ?? [:]
                        fieldUnits[field] = changeUnit
                        shared["indicatorunits"] = fieldUnits
                    }
                    if prices.contains(field) {
                        if let unit = first(column, units) { shared["priceunit"] = unit }
                        if let currency = first(column, currencies) { shared["quotecurrency"] = currency }
                    }
                } else { throw WindError.invalidResponse }
            }
            guard Set(fields).count == fields.count, values.allSatisfy({ $0.count == fields.count }) else {
                throw WindError.invalidResponse
            }
            let rows = values.map { Dictionary(uniqueKeysWithValues: zip(fields, $0)) }
            if let grouped = try pivotIndicators(rows, metadata: shared) { return grouped.compactMap(decode) }
            return rows.compactMap { decode(shared.merging($0) { _, current in current }) }
        }

        var found: [T] = []
        for child in ["data", "result", "tables", "table", "rows", "records", "quotes", "items", "list", "output", "results", "indicators", "indexes", "mcptooldata", "structuredcontent", "content"] {
            if let nested = row[child] {
                found += try records(in: nested, metadata: shared, depth: depth + 1, decode: decode)
            }
        }
        for (identifier, nested) in original where qualifiedCode(identifier) {
            var context = shared
            context["windcode"] = identifier
            found += try records(in: nested, metadata: context, depth: depth + 1, decode: decode)
        }
        return found
    }

    // A grouped result can place one indicator/value pair on each row.
    // Joining on the exact identifier prevents values from crossing instruments.
    private static func pivotIndicators(_ rows: [Row], metadata: Row) throws -> [Row]? {
        let labels = ["指标名称", "指标", "indicatorname", "indicator", "fieldname", "field"]
        let values = ["指标值", "数值", "值", "indicatorvalue", "value"]
        var grouped: [String: Row] = [:]
        var indicators: [String: Set<String>] = [:]
        var order: [String] = []
        for original in rows {
            let row = normalized(original)
            guard let label = string(first(row, labels)), let value = first(row, values) else { return nil }
            let combined = metadata.merging(row) { _, current in current }
            guard let code = instrumentCode(combined) else { return nil }
            let field = key(label)
            guard knownKeys.contains(field) else { continue }
            if grouped[code] == nil {
                grouped[code] = ["windcode": code]
                order.append(code)
            }
            // Duplicate indicator values for one code may belong to different
            // observations. Leave those for a time-series parser.
            guard indicators[code, default: []].insert(field).inserted else { throw WindError.invalidResponse }
            grouped[code]?[field] = value
            for metaKey in names + markets where grouped[code]?[metaKey] == nil {
                grouped[code]?[metaKey] = combined[metaKey]
            }
            if changes.contains(field), let changeUnit = string(first(combined, units)) {
                var fieldUnits = grouped[code]?["indicatorunits"] as? Row ?? [:]
                fieldUnits[field] = changeUnit
                grouped[code]?["indicatorunits"] = fieldUnits
            }
            if prices.contains(field) {
                for metaKey in units + currencies + dates + times + timestamps + statuses {
                    if let meta = combined[metaKey] { grouped[code]?[metaKey] = meta }
                }
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private static let inheritedKeys = [codes.filter { $0 != "code" }, names, units, currencies, markets, categories, statuses, dates, times, timestamps].flatMap { $0 }
    private static let knownKeys = Set(inheritedKeys + ["code"] + prices + prior + changes)

    private static func checkBusinessStatus(_ row: Row) throws {
        if let error = row["error"] as? Row {
            throw WindError.fromServiceMessage(error["message"] as? String)
        }
        if row["ok"] as? Bool == false || row["success"] as? Bool == false {
            throw WindError.fromServiceMessage(string(row["message"] ?? row["error"]))
        }
        if let code = first(row, ["mcptoolerrorcode", "errorcode"]), string(code) != "0" {
            throw WindError.fromServiceMessage(string(row["mcptoolerrormsg"] ?? row["message"]))
        }
        let envelope = ["message", "msg", "rows", "data", "records", "list"].contains { row[$0] != nil }
        if let status = string(row["code"]).flatMap(Int.init),
           instrumentCode(row) == nil, first(row, prices) == nil, envelope,
           status != 0, !(200..<300).contains(status) {
            throw WindError.fromServiceMessage(string(row["message"] ?? row["msg"]))
        }
    }

    private static func instrumentCode(_ row: Row) -> String? {
        let specific = first(row, codes.filter { $0 != "code" }) as? String
        let fallback = row["code"] as? String
        guard let identifier = specific ?? fallback,
              specific != nil || qualifiedCode(identifier) else { return nil }
        let code = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.range(of: #"^[A-Z0-9][A-Z0-9./_\-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }

    private static func quote(from row: Row) -> WindQuote? {
        guard let code = instrumentCode(row), let price = decimal(first(row, prices)), price >= 0 else { return nil }
        let name = string(first(row, names))
        let previous = decimal(first(row, prior)).flatMap { $0 >= 0 ? $0 : nil }
        var timestamp = string(first(row, timestamps))
        if timestamp == nil {
            let date = string(first(row, dates))
            let time = string(first(row, times))
            if let date, let time, !time.contains(date), !time.contains("-") {
                timestamp = "\(date) \(time)"
            } else {
                timestamp = time ?? date
            }
        }
        // Metadata can apply to every field or be keyed by the individual price field.
        func priceMetadata(_ keys: [String]) -> String? {
            for field in keys {
                if let map = row[field] as? Row, let value = string(first(normalized(map), prices)) { return value }
                if let value = string(row[field]) { return value }
            }
            return nil
        }
        // Wind's documented 1% unit reports percentage points: 0.87 means 0.87%.
        // A plain numeric value with an unspecified scale cannot be used as a percent.
        let changeField = changes.first { row[$0] != nil && !(row[$0] is NSNull) }
        let reported: Decimal? = changeField.flatMap { field in
            guard let raw = string(row[field]) else { return nil }
            let explicit = raw.hasSuffix("%") || raw.hasSuffix("％")
            let fieldUnits = (row["indicatorunits"] as? Row) ?? (row["unit"] as? Row) ?? [:]
            let unit = string(normalized(fieldUnits)[field])?.replacingOccurrences(of: " ", with: "")
            guard explicit || ["%", "1%", "％", "1％"].contains(unit) else { return nil }
            return decimal(explicit ? String(raw.dropLast()) : raw)
        }
        return WindQuote(code: code, name: name, price: price, previousClose: previous,
                         quotedAt: timestamp, currency: priceMetadata(currencies)?.uppercased(),
                         unit: priceMetadata(units), tradingStatus: string(first(row, statuses)),
                         reportedChangePercent: reported)
    }

    private static func key(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && $0 != "_" }
    }

    private static func normalized(_ row: Row) -> Row {
        Dictionary(row.map { (key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func qualifiedCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_\-]{0,39}\.[A-Za-z]{1,10}$"#, options: .regularExpression) != nil
    }

    private static func first(_ row: Row, _ keys: [String]) -> Any? {
        for key in keys {
            if let value = row[key], !(value is NSNull) { return value }
        }
        return nil
    }

    private static func string(_ any: Any?) -> String? {
        if let value = any as? String {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private static func decimal(_ any: Any?) -> Decimal? {
        guard let text = string(any),
              text.range(of: #"^[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
    }
}
