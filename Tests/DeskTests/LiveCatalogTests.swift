import Foundation
import Testing
@testable import Desk

/// Lists each CLI's models for real. Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LiveCatalog`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveCatalogTests {
    @Test func discoversModelsForEveryAgent() async {
        let catalog = ModelCatalog()
        await catalog.refresh()
        for agent in AgentID.allCases {
            let options = catalog.options[agent] ?? []
            print("CATALOG \(agent): \(options.map { "\($0.label)\($0.isDefault ? "*" : "") [\($0.efforts.map { $0.id + ($0.isDefault ? "*" : "") }.joined(separator: " "))]" }.joined(separator: ", "))")
            #expect(!options.isEmpty, "\(agent) listed no models")
        }
    }
}

/// Reads each real CLI's sign-in state. Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LiveSignIn`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveSignInTests {
    @Test func readsEverySignedInAgent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desk-signin-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "desk-signin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DeskModel(store: ThreadStore(directory: directory), trash: { _ in }, defaults: defaults, assumeInstalled: false)
        await model.refreshSignIn()
        for agent in AgentID.allCases {
            print("SIGNIN \(agent): \(String(describing: model.signIn[agent]))")
            #expect(model.signIn[agent].map { if case .signedIn = $0 { true } else { false } } == true, "\(agent) should read as signed in on this Mac")
        }
    }
}
