import Foundation

enum SessionStatus: String, Codable {
    case idle
    case thinking
    case toolUse = "tool_use"
    case streaming
    case disconnected
}

/// The /context breakdown the mod sends: one row per category, and the MCP
/// tools and memory files behind two of them, largest first.
struct ContextBreakdown: Codable, Equatable {
    struct Row: Codable, Equatable, Hashable {
        var name: String
        var tokens: Int
        /// `used`, `free`, `buffer` or `deferred`.
        var kind: String
    }
    struct McpTool: Codable, Equatable, Hashable {
        var name: String
        var server: String
        var tokens: Int
    }
    struct MemoryFile: Codable, Equatable, Hashable {
        var path: String
        var tokens: Int
    }
    var windowTokens: Int
    var usedTokens: Int
    /// When the last full count ran, in milliseconds since the epoch.
    var measuredAt: Double
    var rows: [Row]
    var mcpTools: [McpTool]
    var memoryFiles: [MemoryFile]

    var fractionUsed: Double {
        windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0
    }

    var percentUsed: Int { Int((fractionUsed * 100).rounded()) }

    enum CodingKeys: String, CodingKey {
        case windowTokens = "window_tokens", usedTokens = "used_tokens", measuredAt = "measured_at"
        case rows, mcpTools = "mcp_tools", memoryFiles = "memory_files"
    }
}

struct CostInfo: Codable, Equatable {
    var totalCostUsd: Double
    var totalDurationMs: Int
    var totalApiDurationMs: Int
}

struct SubagentInfo: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var status: SessionStatus
    var description: String?
    var currentTool: String?
    var toolDetail: String?
}

struct SessionTask: Codable, Identifiable, Equatable {
    var id: String
    var subject: String
    var status: String
    var blockedBy: [String]?
}

struct ActiveTool: Codable, Equatable, Identifiable {
    var id: String
    var tool: String
    var detail: String?
}

struct PullRequest: Codable, Equatable {
    var number: Int
    var url: String?
    var reviewState: String?
}

struct NetworkToolEntry: Codable, Equatable {
    var ms: Int
    var tool: String
    var detail: String?
}

struct NetworkInfo: Codable, Equatable {
    var lastToolMs: Int?
    var recentToolMs: [Int]?
    var recentTools: [NetworkToolEntry]?
    var avgApiMsPerTurn: Int?
    var apiTimePercent: Int?

    // Cumulative time breakdown for the session — all counted in ms.
    // apiMsTotal is "Claude thinking" (network + server inference), accumulated
    // across UserPromptSubmit→PreToolUse and PostToolUse→(PreToolUse|Stop).
    // toolMsTotal is wall-clock time spent running local tools
    // (PreToolUse→PostToolUse).
    var apiMsTotal: Int?
    var toolMsTotal: Int?

    var hasData: Bool {
        lastToolMs != nil || avgApiMsPerTurn != nil || apiTimePercent != nil
            || apiMsTotal != nil || toolMsTotal != nil
    }
}

struct SessionState: Codable, Equatable {
    var sessionName: String?
    var sessionNameOverride: Bool?
    var modelName: String?
    var workingDirectory: String?
    var status: SessionStatus
    var cost: CostInfo?
    var claudeCodeSessionId: String?
    var currentToolName: String?
    var toolDetail: String?
    var subagents: [SubagentInfo]
    var tasks: [SessionTask]
    var network: NetworkInfo?
    var documents: [String]?
    var activeTools: [ActiveTool]?
    var conversationTurns: Int?
    var needsInput: Bool?
    var permissionMode: String?
    var pullRequest: PullRequest?
    var contextBreakdown: ContextBreakdown?
    var isCompacting: Bool?
    var apiSendMs: Int?

    enum CodingKeys: String, CodingKey {
        case sessionName, sessionNameOverride, modelName, workingDirectory
        case status, cost, claudeCodeSessionId
        case currentToolName, toolDetail
        case subagents, tasks, network, documents, activeTools, conversationTurns, needsInput
        case permissionMode, pullRequest, contextBreakdown, isCompacting
        case apiSendMs = "_apiSendMs"
    }

    static let empty = SessionState(
        sessionName: nil,
        modelName: nil,
        workingDirectory: nil,
        status: .disconnected,
        cost: nil,
        currentToolName: nil,
        toolDetail: nil,
        subagents: [],
        tasks: [],
        conversationTurns: nil
    )
}
