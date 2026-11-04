import Foundation

/// Display names shared by the Mac UI and the core (moved out of AppDelegate).
enum AgentDisplay {
    static func agentName(_ backend: AgentBackendID) -> String {
        switch backend {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .aura: return "Page Aura"
        case .orbit: return "Page Orbit"
        }
    }
}
