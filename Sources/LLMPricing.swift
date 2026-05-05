import Foundation

/// Per-million-token rates for an Anthropic model tier, in USD.
struct LLMRate {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
}

/// Token counts pulled from a transcript's `message.usage` object.
struct LLMUsage {
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let outputTokens: Int

    var promptTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Cost decomposition for one assistant turn.
struct LLMTurnCost: Equatable {
    let total: Double
    let active: Double           // cache_read + fresh input + output
    let cacheCreate: Double      // billed cache writes (the reclaimable bucket on a TTL miss)
}

enum LLMPricing {
    /// Anthropic API rates for the Opus 4.x family. The 1M tier kicks in once
    /// the prompt crosses 200K tokens.
    static let opusStandard = LLMRate(input: 15.00, output: 75.00, cacheWrite: 18.75, cacheRead: 1.50)
    static let opus1M       = LLMRate(input: 30.00, output: 150.00, cacheWrite: 37.50, cacheRead: 3.00)

    static let longContextThreshold = 200_000

    static func rate(forPromptTokens promptTokens: Int) -> LLMRate {
        promptTokens > longContextThreshold ? opus1M : opusStandard
    }

    static func turnCost(_ usage: LLMUsage) -> LLMTurnCost {
        let r = rate(forPromptTokens: usage.promptTokens)
        let perMillion = 1_000_000.0
        let active = (Double(usage.inputTokens) * r.input
                      + Double(usage.cacheReadTokens) * r.cacheRead
                      + Double(usage.outputTokens) * r.output) / perMillion
        let cacheCreate = Double(usage.cacheCreationTokens) * r.cacheWrite / perMillion
        return LLMTurnCost(total: active + cacheCreate, active: active, cacheCreate: cacheCreate)
    }
}
