import Foundation
import WindDeskCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("检查失败：\(message)\n", stderr)
        exit(1)
    }
}

func fixture(_ json: String) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return result
}

let index = try QuoteParser.parse(fixture("""
    {"structuredContent":{"data":{"columns":["Wind代码","最新成交价","前收盘价","最新交易日","交易时间"],
    "rows":[["000001.SH","3,100.00",3000,"2026-11-23","15:00:00"],
            ["399673.SZ",950,1000,"2026-11-23","15:00:00"]]}}}
    """))
require(index.map(\.code) == ["000001.SH", "399673.SZ"], "批量快照按证券代码识别")
require(index[0].quotedAt == "2026-11-23 15:00:00", "保留行情日期和时间")
require(index[1].changePercent == -5, "根据前收盘价计算涨跌幅")

let gold = try QuoteParser.parse([
    "content": [["type": "text", "text": """
    {"data":{"records":[{"windcode":"SPTAUUSDOZ.IDC","price":3110.34768,"currency":"USD","unit":"USD/oz","time":"2026-11-23 09:00:00"}]}}
    """]]
])
var snapshot = MarketSnapshot()
snapshot.gold = gold.first
require(snapshot.goldCNYPerGram == nil, "汇率缺失时保留美元金价")
snapshot.fx = WindQuote(code: "USDCNY.FX", price: 7, currency: "CNY")
require(snapshot.goldCNYPerGram == 700, "将美元/金衡盎司换算为人民币/克")
snapshot.fx = WindQuote(code: "USDCNH.FX", price: 7, currency: "CNH")
require(snapshot.goldCNYPerGram == 700, "可用离岸人民币显式折算")
snapshot.fx = WindQuote(code: "USDJPY.FX", price: 150, currency: "JPY")
require(snapshot.goldCNYPerGram == nil, "拒绝把其他币种作为人民币汇率")

for input in [
    #"{"data":{"code":"200","price":3200}}"#,
    #"{"data":{"windcode":"000001.SH","price":true}}"#,
    #"{"data":{"windcode":"000001.SH","price":"7 000"}}"#,
    #"{"data":{"code":429,"message":"quota","rows":[{"windcode":"000001.SH","price":5}]}}"#,
] {
    do {
        _ = try QuoteParser.parse(fixture(input))
        require(false, "无证券代码、非数值或业务错误不生成报价")
    } catch {}
}

let directCNY = try QuoteParser.parse(fixture("""
    {"structuredContent":{"data":[{"windcode":"XAUCNY.IDC","最新成交价":708.1234,
    "交易时间":"2026-01-05T09:00:00.000+08:00","币种":"CNY","单位":"元/克"}]}}
    """))
snapshot.goldCNY = directCNY.first
snapshot.fx = WindQuote(code: "USDCNY.IB", price: 7, currency: "CNY")
require(snapshot.goldCNYPerGram == Decimal(string: "708.1234"), "优先使用 Wind 人民币原报价")
require(!snapshot.usesConvertedGoldCNY, "人民币原报价无需折算")
snapshot.gold = nil
require(snapshot.goldCNYPerGram == Decimal(string: "708.1234"), "人民币原报价可独立显示")

let legacy = try JSONDecoder().decode(MarketSnapshot.self, from: Data("""
    {"goldSource":"goldAPI","gold":{"code":"hf_XAU","price":3600,"currency":"USD"},
    "fx":{"code":"USDCNY","price":7,"currency":"CNY"},
    "indices":[{"code":"000001.SH","price":3100}],"stocks":[]}
    """.utf8))
require(legacy.gold == nil && legacy.fx == nil, "迁移旧缓存时清除第三方金价和汇率")
require(legacy.indices.first?.code == "000001.SH", "迁移旧缓存时保留 Wind 指数")
let cache = WidgetQuoteCache.Entry(snapshot: snapshot, watchlist: WatchItem.indices)
let encoded = try JSONEncoder().encode(cache)
let decoded = try JSONDecoder().decode(WidgetQuoteCache.Entry.self, from: encoded)
require(decoded == cache, "小组件快照保留自选顺序、报价时间和原报价精度")

print("行情解析、人民币原报价、旧缓存迁移与小组件快照检查通过。")
