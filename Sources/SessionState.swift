import Foundation

enum SessionStatus: String, Codable {
    case idle
    case thinking
    case toolUse = "tool_use"
    case streaming
    case disconnected
}

struct ContextUsage: Codable, Equatable {
    var usedPercentage: Int
    var remainingPercentage: Int
    var contextWindowSize: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?

    var fractionUsed: Double {
        Double(usedPercentage) / 100.0
    }
}

struct CostInfo: Codable, Equatable {
    var totalCostUsd: Double
    var totalDurationMs: Int
    var totalApiDurationMs: Int
    var totalLinesAdded: Int
    var totalLinesRemoved: Int
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

    var hasData: Bool {
        lastToolMs != nil || avgApiMsPerTurn != nil || apiTimePercent != nil
    }
}

struct SessionState: Codable, Equatable {
    var sessionName: String?
    var sessionNameOverride: Bool?
    var modelName: String?
    var workingDirectory: String?
    var status: SessionStatus
    var contextUsage: ContextUsage?
    var cost: CostInfo?
    var currentToolName: String?
    var toolDetail: String?
    var subagents: [SubagentInfo]
    var tasks: [SessionTask]
    var network: NetworkInfo?
    var documents: [String]?
    var activeTools: [ActiveTool]?
    var conversationTurns: Int?
    var needsInput: Bool?
    var apiSendMs: Int?

    enum CodingKeys: String, CodingKey {
        case sessionName, sessionNameOverride, modelName, workingDirectory
        case status, contextUsage, cost, currentToolName, toolDetail
        case subagents, tasks, network, documents, activeTools, conversationTurns, needsInput
        case apiSendMs = "_apiSendMs"
    }

    static let empty = SessionState(
        sessionName: nil,
        modelName: nil,
        workingDirectory: nil,
        status: .disconnected,
        contextUsage: nil,
        cost: nil,
        currentToolName: nil,
        toolDetail: nil,
        subagents: [],
        tasks: [],
        conversationTurns: nil
    )
}
