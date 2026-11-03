import Foundation

/// Anthropic's first-party API rates, in dollars per million tokens (as of 2026-10). Sessions on a subscription, or
/// on Bedrock or Vertex, aren't billed these amounts, so everything built on this is an estimate at API rates.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Cache writes are a multiple of the input price: 1.25x for the 5-minute cache, 2x for the 1-hour one.
    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2 }

    static let table: [String: ModelPrice] = [
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": .init(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.2),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-8": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-7": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-6": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.2),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.2),
        "claude-sonnet-4-6": .init(input: 3, output: 15, cacheRead: 0.3),
        "claude-haiku-5-5": .init(input: 0.1, output: 0.5, cacheRead: 0.01),
        "claude-haiku-4-5": .init(input: 1, output: 5, cacheRead: 0.1),
    ]

    /// Matches exact ids and dated or suffixed ones ("claude-opus-5-5[1m]"); longest name first, so opus-5-5 beats opus-5.
    public static func lookup(_ model: String) -> ModelPrice? {
        if let exact = table[model] { return exact }
        let match = table.keys.filter { model.hasPrefix($0) }.max { $0.count < $1.count }
        return match.flatMap { table[$0] }
    }
}

/// Dollars for one or many requests, split by what they paid for.
public struct CostSplit: Equatable, Sendable {
    public var input = 0.0
    public var output = 0.0
    public var cacheRead = 0.0
    public var cacheWrite = 0.0
    public var total: Double { input + output + cacheRead + cacheWrite }
    public init() {}

    mutating func add(_ other: CostSplit) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }

    /// `usage` is a Messages API usage object. Nil if the model isn't in the price table.
    static func of(model: String, usage: [String: Any]) -> CostSplit? {
        guard let price = ModelPrice.lookup(model) else { return nil }
        let n = { (key: String) in Double(usage[key] as? Int ?? 0) }
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        let write1h = Double(creation["ephemeral_1h_input_tokens"] as? Int ?? 0)
        // Older transcripts have only the total, which is the 5-minute cache.
        let write5m = creation["ephemeral_5m_input_tokens"] as? Int != nil
            ? Double(creation["ephemeral_5m_input_tokens"] as? Int ?? 0) : max(0, n("cache_creation_input_tokens") - write1h)

        var scale = 1.0
        if usage["speed"] as? String == "fast", model.hasPrefix("claude-opus-5") { scale = 2 }  // fast mode
        let prompt = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
        if model.hasPrefix("claude-haiku-5-5"), prompt > 100_000 { scale = 5 }  // long-prompt rate

        var split = CostSplit()
        split.input = n("input_tokens") * price.input * scale / 1_000_000
        split.output = n("output_tokens") * price.output * scale / 1_000_000
        split.cacheRead = n("cache_read_input_tokens") * price.cacheRead * scale / 1_000_000
        split.cacheWrite = (write5m * price.cacheWrite5m + write1h * price.cacheWrite1h) * scale / 1_000_000
        return split
    }
}

public struct ModelCost: Identifiable, Equatable, Sendable {
    public var id: String { model }
    public var model: String
    public var cost: Double
    public var requests: Int
}

/// What one of your prompts cost, including every request Claude made answering it.
public struct TurnCost: Identifiable, Equatable, Sendable {
    public var id: Int
    public var prompt: String
    public var cost: Double
    public var requests: Int
}
