import Foundation

struct AgentAvailability: Equatable, Sendable {
    var binary: URL?
    var isInstalled: Bool { binary != nil }
}
