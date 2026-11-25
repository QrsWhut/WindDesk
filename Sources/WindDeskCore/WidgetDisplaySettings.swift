public struct WidgetDisplaySettings: Codable, Equatable {
    public struct Counts: Codable, Equatable {
        public var indices: Int
        public var stocks: Int

        public init(indices: Int, stocks: Int) {
            self.indices = indices
            self.stocks = stocks
        }

        fileprivate func limited(to capacity: Int) -> Self {
            let indices = min(max(0, indices), capacity)
            return Self(indices: indices, stocks: min(max(0, stocks), capacity - indices))
        }
    }

    public static let mediumCapacity = 4
    public static let largeCapacity = 7

    public var medium: Counts
    public var large: Counts

    public init(medium: Counts = .init(indices: 4, stocks: 0), large: Counts = .init(indices: 4, stocks: 3)) {
        self.medium = medium.limited(to: Self.mediumCapacity)
        self.large = large.limited(to: Self.largeCapacity)
    }

    package var normalized: Self { Self(medium: medium, large: large) }
}
