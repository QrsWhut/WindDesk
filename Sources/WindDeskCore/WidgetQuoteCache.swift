import Darwin
import Foundation

public enum WidgetQuoteCache {
    public static let kind = "com.winddesk.menubar.market"

    public struct Entry: Codable, Equatable {
        public let snapshot: MarketSnapshot
        public let watchlist: [WatchItem]

        public init(snapshot: MarketSnapshot, watchlist: [WatchItem]) {
            self.snapshot = snapshot
            self.watchlist = watchlist
        }
    }

    public static func read() -> Entry? {
        cacheURL().flatMap(read(from:))
    }

    @discardableResult
    public static func write(_ entry: Entry) throws -> Bool {
        guard let url = cacheURL() else { throw CocoaError(.fileWriteNoPermission) }
        if read(from: url) == entry { return false }
        if usesLocalCache {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let data = try JSONEncoder().encode(entry)
        try data.write(to: url, options: .atomic)
        if usesLocalCache {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return true
    }

    private static func read(from url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private static var usesLocalCache: Bool {
        Bundle.main.object(forInfoDictionaryKey: "WindDeskWidgetLocalCache") as? Bool == true
    }

    private static func cacheURL() -> URL? {
        if usesLocalCache {
            // The widget's Foundation home directory is its sandbox container.
            guard let homePath = userHomePath() else { return nil }
            return URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent("Library/Application Support/WindDeskWidget/market-snapshot.json", isDirectory: false)
        }
        let group = Bundle.main.object(forInfoDictionaryKey: "WindDeskAppGroup") as? String
            ?? "group.com.winddesk.market"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("market-snapshot.json", isDirectory: false)
    }

    private static func userHomePath() -> String? {
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: suggestedSize > 0 ? suggestedSize : 16_384)
        return buffer.withUnsafeMutableBufferPointer { storage in
            var user = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &user, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let path = user.pw_dir else { return nil }
            return String(cString: path)
        }
    }
}
