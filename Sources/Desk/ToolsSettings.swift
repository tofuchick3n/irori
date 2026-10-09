import SwiftUI

struct ToolsSettings: View {
    var model: DeskModel
    @State private var showsAdd = false
    @State private var removing: Removal?
    @State private var removeError: String?

    private struct Removal: Identifiable {
        var agent: AgentID
        var name: String
        var id: String { "\(agent.rawValue)/\(name)" }
    }

    var body: some View {
        Form {
            Section {
                Button("Add Server…", systemImage: "plus") { showsAdd = true }
                    .disabled(model.activeAgents.isEmpty)
            } footer: {
                Text("Servers are saved in each agent's own settings. Configured means the agent has it, not that it works.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.activeAgents, id: \.self) { agent in
                AgentToolsSection(model: model, agent: agent) { name in
                    removing = Removal(agent: agent, name: name)
                }
            }
            if let removeError {
                Section {
                    Text(removeError).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshTools() }
        .sheet(isPresented: $showsAdd) {
            AddServerSheet(model: model)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { removal in
            Button("Remove from \(removal.agent.displayName)", role: .destructive) {
                Task {
                    do {
                        removeError = nil
                        try await model.removeServer(removal.name, from: removal.agent)
                    } catch {
                        removeError = error.localizedDescription
                    }
                }
            }
        } message: { removal in
            Text("\(removal.agent.displayName) will stop using this server.")
        }
    }
}

private struct AgentToolsSection: View {
    var model: DeskModel
    var agent: AgentID
    var remove: (String) -> Void

    var body: some View {
        let tools = model.tools[agent]
        Section(agent.displayName) {
            if let error = tools?.error {
                Text(error).foregroundStyle(.orange)
            }
            if tools == nil {
                Text("Loading…").foregroundStyle(.secondary)
            } else if tools?.servers.isEmpty == true, tools?.error == nil {
                Text("No servers").foregroundStyle(.secondary)
            }
            ForEach(tools?.servers ?? []) { server in
                HStack {
                    VStack(alignment: .leading) {
                        Text(server.name)
                        if let target = server.target {
                            Text(target)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if server.status == .needsSignIn {
                        Button("Sign In…") { model.openToolSignIn(for: agent, server: server.name) }
                    }
                    Text(server.status.label)
                        .foregroundStyle(color(server.status))
                }
                .contextMenu {
                    // claude.ai connectors belong to the account; they're removed on claude.ai, not by the CLI.
                    if agent == .claude, server.name.hasPrefix("claude.ai ") {
                        Text("Manage on claude.ai")
                    } else {
                        Button("Remove…", role: .destructive) { remove(server.name) }
                    }
                }
            }
            let skills = tools?.skills ?? []
            if !skills.isEmpty {
                DisclosureGroup("\(skills.count) \(skills.count == 1 ? "skill" : "skills")") {
                    ForEach(skills, id: \.self) { Text($0) }
                }
            }
        }
    }

    private func color(_ status: ToolServer.Status) -> Color {
        switch status {
        case .connected: .green
        case .needsSignIn, .failed: .orange
        case .disabled, .configured: .secondary
        }
    }
}

private struct AddServerSheet: View {
    var model: DeskModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @State private var chosen: Set<AgentID> = []
    @State private var results: [AgentID: String?] = [:]
    @State private var isAdding = false
    @State private var urlHint: String?
    @FocusState private var urlFocused: Bool

    private var url: URL? { URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canAdd: Bool {
        !isAdding && !chosen.isEmpty && ToolsCommand.isValidName(name.trimmingCharacters(in: .whitespaces)) && ToolsCommand.isValidURL(url)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("URL", text: $urlText, prompt: Text(urlHint ?? "https://example.com/mcp"))
                    .focused($urlFocused)
                Button("Composio") {
                    name = "composio"
                    urlHint = "Paste your MCP URL from composio.dev"
                    urlFocused = true
                }
            }
            Section("Add to") {
                ForEach(model.activeAgents, id: \.self) { agent in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(agent) },
                        set: { if $0 { chosen.insert(agent) } else { chosen.remove(agent) } }
                    )) {
                        HStack {
                            Text(agent.displayName)
                            Spacer()
                            if let result = results[agent] {
                                if let message = result {
                                    Text(message).foregroundStyle(.orange).lineLimit(2)
                                } else {
                                    Label("Added", systemImage: "checkmark.circle").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { chosen = Set(model.activeAgents) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(results.isEmpty ? "Cancel" : "Done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!canAdd)
            }
        }
    }

    private func add() {
        guard let url else { return }
        isAdding = true
        let agents = model.activeAgents.filter(chosen.contains)
        Task {
            results = await model.addServer(name: name.trimmingCharacters(in: .whitespaces), url: url, to: agents)
            isAdding = false
        }
    }
}
