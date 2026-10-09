import AppKit
import SwiftUI

struct WelcomeView: View {
    static let windowID = "welcome"

    var model: DeskModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Brand.name)
                    .font(.largeTitle.bold())
                Text("Brainstorm with several AI agents in one thread. They take turns and read each other's replies.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(model.welcomeAgents, id: \.self) { agent in
                    if agent != model.welcomeAgents.first {
                        Divider()
                    }
                    WelcomeRow(model: model, agent: agent)
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                if !model.hasReadyAgent {
                    Text("Install and sign in to at least one agent")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Get Started") {
                    model.completeWelcome()
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasReadyAgent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await model.refreshReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshReadiness() }
        }
    }
}

private struct WelcomeRow: View {
    var model: DeskModel
    let agent: AgentID

    var body: some View {
        let status = model.welcomeStatus(for: agent)
        HStack(spacing: 10) {
            AgentMark(agent: agent, size: 22)
            Text(agent.displayName)
                .fontWeight(.semibold)
            Spacer()
            Text(status.detail.map { "\(status.label) (\($0))" } ?? status.label)
                .foregroundStyle(status.isReady ? Color.secondary : Color.orange)
            action(status.action)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func action(_ action: WelcomeStatus.Action?) -> some View {
        switch action {
        case .get(let url)?:
            Link("Get…", destination: url)
        case .signIn?:
            Button("Sign In") { model.openSignIn(for: agent) }
        case .checkAgain?:
            Button("Check Again") { Task { await model.refreshReadiness() } }
        case nil:
            EmptyView()
        }
    }
}
