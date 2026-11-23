import Foundation

enum WindError: LocalizedError {
    case authentication, permission, rateLimit, quota, network, invalidResponse, missingTool, noQuote, rejected, http(Int)

    var errorDescription: String? {
        switch self {
        case .authentication: "Wind Alice 未通过鉴权，请检查 API Key。"
        case .permission: "当前 Wind Alice 账号无法访问该工具或市场，请核对套餐和权限。"
        case .rateLimit: "Wind Alice 的请求频率受限，请稍后重试。"
        case .quota: "Wind Alice 的账户积分或取数额度不足。"
        case .network: "连接 Wind Alice 失败，请检查网络后重试。"
        case .invalidResponse: "Wind Alice 返回了无法识别的数据格式。"
        case .missingTool: "当前 Wind Alice 接入未提供所需的行情工具。"
        case .noQuote: "Wind Alice 没有返回可确认的行情。"
        case .rejected: "Wind Alice 拒绝了本次取数，请检查标的和账户权益。"
        case .http(let status): "Wind Alice 请求失败（HTTP \(status)）。"
        }
    }

    static func fromServiceMessage(_ message: String?) -> Self {
        let message = message?.lowercased() ?? ""
        if ["rate_limit", "rate limit", "too many requests", "限流", "频率限制", "qps", "请求过快"].contains(where: message.contains) { return .rateLimit }
        if ["quota", "积分不足", "积分余额", "额度不足", "额度用完", "次数用尽", "exhausted", "余额不足", "insufficient credits"].contains(where: message.contains) { return .quota }
        if ["permission", "forbidden", "授权", "权限"].contains(where: message.contains) { return .permission }
        if ["unauthorized", "api key", "鉴权", "未认证"].contains(where: message.contains) { return .authentication }
        return .rejected
    }
}

final class WindMCP: NSObject, URLSessionTaskDelegate {
    private static let clientVersion = "0.3.0"

    enum Domain: String {
        case stock = "vserver_stock_data"
        case index = "vserver_index_data"
        case global = "vserver_global_securities"
    }

    private let endpoint: URL
    private let apiKey: String
    private var sessionID: String?
    private var protocolVersion = "2025-03-26"

    private static let requestPacer = RequestPacer()

    // The three MCP services use separate protocol sessions on the same HTTPS host.
    // Reusing the transport lets Foundation pool connections without sharing request headers.
    private static let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    init(_ domain: Domain, apiKey: String) {
        self.endpoint = URL(string: "https://mcp.wind.com.cn/\(domain.rawValue)/mcp/")!
        self.apiKey = apiKey
    }

    func connect() async throws {
        let result = try await request("initialize", arguments: [
            "protocolVersion": protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "WindDesk", "version": Self.clientVersion],
        ])
        guard let version = result["protocolVersion"] as? String,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw WindError.invalidResponse
        }
        protocolVersion = version
        // The documented Wind domain CLI uses an initialize request and then makes the call
        // directly. A stateful MCP endpoint additionally needs the initialized notification.
        if sessionID != nil {
            _ = try await request("notifications/initialized", notification: true)
        }
    }

    func call(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await request("tools/call", arguments: ["name": tool, "arguments": arguments])
        if result["isError"] as? Bool == true {
            let content = result["content"] as? [[String: Any]]
            throw WindError.fromServiceMessage(content?.first?["text"] as? String)
        }
        return result
    }

    private func request(
        _ method: String,
        arguments: [String: Any] = [:],
        notification: Bool = false
    ) async throws -> [String: Any] {
        let id = Int.random(in: 1...Int(Int32.max))
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": arguments]
        if !notification { message["id"] = id }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WindDesk/\(Self.clientVersion)", forHTTPHeaderField: "User-Agent")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        do {
            try await Self.requestPacer.waitForTurn()
            let (body, response) = try await Self.transport.bytes(for: request, delegate: self)
            // Streamable HTTP can keep the response open after the matching event.
            defer { body.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw WindError.invalidResponse }
            switch http.statusCode {
            case 200..<300: break
            case 401: throw WindError.authentication
            case 403: throw WindError.permission
            case 429: throw WindError.http(429)
            default: throw WindError.http(http.statusCode)
            }
            if method == "initialize" {
                sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
            }
            if notification { return [:] }
            if http.mimeType == "text/event-stream" {
                var lineBytes: [UInt8] = []
                var eventData: [String] = []
                for try await byte in body {
                    if byte != 10 {
                        lineBytes.append(byte)
                        continue
                    }
                    if lineBytes.last == 13 { lineBytes.removeLast() }
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    if line.isEmpty {
                        if let response = Self.envelope(Data(eventData.joined(separator: "\n").utf8), id: id) {
                            return try Self.result(response)
                        }
                        eventData.removeAll(keepingCapacity: true)
                    } else if line.hasPrefix("data:") {
                        let value = line.dropFirst(5)
                        eventData.append(String(value.first == " " ? value.dropFirst() : value))
                    }
                }
                if !lineBytes.isEmpty {
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    if line.hasPrefix("data:") { eventData.append(String(line.dropFirst(5))) }
                }
                if let response = Self.envelope(Data(eventData.joined(separator: "\n").utf8), id: id) {
                    return try Self.result(response)
                }
            } else {
                var data = Data()
                if (1...262_144).contains(http.expectedContentLength) {
                    data.reserveCapacity(Int(http.expectedContentLength))
                }
                for try await byte in body { data.append(byte) }
                if let response = Self.envelope(data, id: id) {
                    return try Self.result(response)
                }
            }
            throw WindError.invalidResponse
        } catch let error as WindError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw WindError.network
        }
    }

    private static func envelope(_ data: Data, id: Int) -> [String: Any]? {
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (response["id"] as? Int == id || response["id"] as? String == String(id)) else { return nil }
        return response
    }

    private static func result(_ envelope: [String: Any]) throws -> [String: Any] {
        if let error = envelope["error"] as? [String: Any] {
            if error["code"] as? Int == -32601 { throw WindError.missingTool }
            throw WindError.fromServiceMessage(error["message"] as? String)
        }
        guard let result = envelope["result"] as? [String: Any] else { throw WindError.invalidResponse }
        return result
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor RequestPacer {
    private let clock = ContinuousClock()
    private var nextStart: ContinuousClock.Instant?

    func waitForTurn() async throws {
        // Count time spent receiving the previous response against the interval.
        // A caller woken by sleep rechecks in case another request started first.
        while let nextStart, clock.now < nextStart {
            try await clock.sleep(until: nextStart)
        }
        try Task.checkCancellation()
        nextStart = clock.now.advanced(by: .milliseconds(1_100))
    }
}
