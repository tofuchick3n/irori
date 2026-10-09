import Foundation

/// What the Welcome window shows for one agent, and the button beside it.
struct WelcomeStatus: Equatable {
    enum Action: Equatable {
        case get(URL)
        case signIn
        case checkAgain
    }

    var label: String
    var detail: String?
    var action: Action?
    var isReady = false

    static func make(agent: AgentID, availability: AgentAvailability?, signIn: SignInState?, isEnabled: Bool = true) -> WelcomeStatus {
        guard availability?.isInstalled == true else {
            return WelcomeStatus(label: "Not installed", action: agent.installURL.map(Action.get))
        }
        guard isEnabled else {
            return WelcomeStatus(label: "Turned off in Settings")
        }
        switch signIn {
        case .signedIn(let detail)?:
            return WelcomeStatus(label: "Ready", detail: detail, isReady: true)
        case .signedOut?:
            return WelcomeStatus(label: "Not signed in", action: .signIn)
        case .unknown?:
            return WelcomeStatus(label: "Couldn't check", action: .checkAgain)
        case nil:
            return WelcomeStatus(label: "Checking…")
        }
    }
}

extension DeskModel {
    func welcomeStatus(for agent: AgentID) -> WelcomeStatus {
        WelcomeStatus.make(agent: agent, availability: availability[agent], signIn: signIn[agent], isEnabled: isEnabled(agent))
    }

    /// Agents to list: installed ones, and missing ones only when there's a page to get them from.
    var welcomeAgents: [AgentID] {
        AgentID.allCases.filter { availability[$0]?.isInstalled == true || $0.installURL != nil }
    }

    var hasReadyAgent: Bool {
        AgentID.allCases.contains { welcomeStatus(for: $0).isReady }
    }
}
