import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: DeskModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "General") {
                GeneralSettings(model: model)
            }
            Tab("Agents", systemImage: "person.2", value: "Agents") {
                AgentsSettings(model: model)
            }
            Tab("Permissions", systemImage: "lock", value: "Permissions") {
                PermissionsSettings(model: model)
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver", value: "Tools") {
                ToolsSettings(model: model)
            }
            Tab("Tags", systemImage: "tag", value: "Tags") {
                TagsSettings(model: model)
            }
            Tab("Takibi", systemImage: "flame", value: "Takibi") {
                TakibiSettings(model: model)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
        .onAppear(perform: clearInitialFocus)
        .onChange(of: model.settingsTab, clearInitialFocus)
    }

    /// With keyboard navigation on, nothing in a tab claims focus, so macOS rings the selected
    /// tab's icon. Start each tab unfocused; Tab still moves into its controls.
    private func clearInitialFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: DeskModel
    @State private var photoError: String?

    var body: some View {
        Form {
            Section("You") {
                TextField("Name", text: Bindable(model.profile).displayName, prompt: Text("You"))
                LabeledContent("Photo") {
                    HStack(spacing: 10) {
                        UserPhoto(image: model.profile.photo, size: 40)
                        Button("Choose…", action: choosePhoto)
                        Button("Use Account Picture") {
                            model.profile.resetPhoto()
                        }
                    }
                }
                if let photoError {
                    Text(photoError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Section("Threads") {
                LabeledContent("Saved in") {
                    HStack {
                        Text(ThreadStore.applicationSupportDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ThreadStore.applicationSupportDirectory])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choosePhoto() {
        guard let url = chooseImage(message: "Choose a photo for your messages") else { return }
        do {
            try model.profile.setPhoto(from: url)
            photoError = nil
        } catch {
            photoError = "Couldn't use that image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Agents

struct AgentsSettings: View {
    var model: DeskModel

    var body: some View {
        Form {
            Section {
                if model.activeAgents.isEmpty {
                    Text("No agents are available. Install one of the CLIs below, or turn one on.")
                        .foregroundStyle(.secondary)
                } else {
                    DefaultAgentPicker(model: model)
                }
            } footer: {
                Text("A thread keeps replying to whoever you last mentioned; this agent answers when nobody has been mentioned yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(AgentID.allCases, id: \.self) { agent in
                AgentSection(model: model, agent: agent)
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshAvailability()
            await model.catalog.refresh()
            await model.refreshSignIn()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from signing in in Terminal.
            Task { await model.refreshSignIn() }
        }
        .onChange(of: model.activeAgents) {
            // An agent just turned on (or was found) needs its models and efforts listed.
            Task {
                await model.catalog.refresh()
                await model.refreshSignIn()
            }
        }
    }
}

private struct AgentSection: View {
    var model: DeskModel
    let agent: AgentID
    @State private var path = ""

    var body: some View {
        Section {
            Toggle("Use \(agent.displayName)", isOn: Binding(
                get: { model.isEnabled(agent) },
                set: { model.setEnabled($0, for: agent) }
            ))
            LabeledContent("Status") {
                if let binary = model.availability[agent]?.binary {
                    Text(binary.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Not found")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Location") {
                HStack {
                    TextField("Location", text: $path, prompt: Text("Search the usual places"))
                        .labelsHidden()
                        .onSubmit(savePath)
                    Button("Choose…", action: choosePath)
                    if model.binaryOverride(for: agent) != nil {
                        Button("Reset") {
                            path = ""
                            model.setBinaryOverride(nil, for: agent)
                        }
                    }
                }
            }
            if model.activeAgents.contains(agent) {
                LabeledContent("Account") {
                    HStack {
                        signInText
                        if model.signIn[agent] != nil, !isSignedIn {
                            Button("Sign In…") {
                                model.openSignIn(for: agent)
                            }
                        }
                    }
                }
            }
            if model.activeAgents.contains(agent) {
                AgentSettingsPickers(model: model, agent: agent)
            }
        } header: {
            Label {
                Text(agent.displayName)
            } icon: {
                AgentMark(agent: agent, size: 16)
            }
        }
        .onAppear {
            path = model.binaryOverride(for: agent) ?? ""
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = model.signIn[agent] { return true }
        return false
    }

    @ViewBuilder private var signInText: some View {
        switch model.signIn[agent] {
        case .signedIn(let detail)?:
            Text(detail.map { "Signed in (\($0))" } ?? "Signed in")
                .foregroundStyle(.secondary)
        case .signedOut?:
            Text("Not signed in")
                .foregroundStyle(.orange)
        case .unknown?:
            Text("Couldn't check")
                .foregroundStyle(.secondary)
        case nil:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func savePath() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setBinaryOverride(trimmed.isEmpty ? nil : trimmed, for: agent)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.message = "Choose the \(agent.displayName) command-line tool"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path(percentEncoded: false)
        savePath()
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    @Bindable var model: DeskModel
    @State private var newCommand = ""

    var body: some View {
        Form {
            Section {
                Toggle("Agents can create and edit files in the thread's folder", isOn: $model.allowsFileWrites)
            } footer: {
                Text("Each thread has its own folder. Claude and Codex ask in the thread before anything else, and Grok and Muse run in their own sandboxes. With this off, Codex also loses network access, and Muse can't run shell commands at all, including takibi.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.allowedCommands, id: \.self) { command in
                    HStack {
                        Text(command)
                            .font(.body.monospaced())
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            model.allowedCommands.removeAll { $0 == command }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New command", text: $newCommand, prompt: Text("Command, e.g. takibi"))
                        .labelsHidden()
                        .onSubmit(addCommand)
                    Button("Add", action: addCommand)
                        .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Commands that never ask")
            } footer: {
                Text("Read-only commands, such as ls and git status, never ask. Claude asks in the thread before any other command that isn't listed here. Codex runs commands inside the thread's folder and asks before anything outside it. Grok and Muse run commands in their own sandboxes, which keep them out of everything except the thread's folder.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if model.alwaysAllowedTools.isEmpty {
                    Text("Nothing yet. Choose Always Allow on a request in a thread.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.alwaysAllowedTools, id: \.self) { rule in
                    HStack {
                        Text(ApprovalRule.friendlyName(rule))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            model.removeAlwaysAllowed(rule)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Always allowed")
            } footer: {
                Text("Tools Claude and Codex may use in any thread without asking.")
                    .foregroundStyle(.secondary)
            }
            Section("What each agent can do") {
                AgentCapabilitiesGrid(writesOn: model.allowsFileWrites)
            }
        }
        .formStyle(.grouped)
    }

    private func addCommand() {
        let command = newCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        model.allowedCommands.append(command)
        newCommand = ""
    }
}

// MARK: - Tags

struct TagsSettings: View {
    var model: DeskModel
    @State private var newTag = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @State private var logoError: String?

    var body: some View {
        Form {
            Section {
                if model.allTags.isEmpty {
                    Text("No tags yet. Add one for each client or topic you want to filter by.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.allTags, id: \.self) { tag in
                    HStack(spacing: 10) {
                        ClientMark(tag: tag, logo: model.logo(for: tag), size: 22)
                        Text(tag)
                        if model.takibiProject(for: tag) != nil {
                            Text("Takibi project")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Edit") {
                            Button("Rename…") {
                                renameText = tag
                                renaming = tag
                            }
                            Button("Choose Logo…") {
                                chooseLogo(for: tag)
                            }
                            if model.logo(for: tag) != nil {
                                Button("Remove Logo") {
                                    model.removeLogo(for: tag)
                                }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                deleting = tag
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                HStack {
                    TextField("New tag", text: $newTag, prompt: Text("New tag, e.g. a client name"))
                        .labelsHidden()
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let logoError {
                    Text(logoError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if !missingProjects.isEmpty {
                    Button("Add \(missingProjects.count) Takibi \(missingProjects.count == 1 ? "Project" : "Projects")", action: model.importTakibiProjects)
                }
            } footer: {
                Text("Tag threads from the sidebar or the tag button above a thread, then filter the sidebar by tag. A tag named like a Takibi project tells agents which project the thread is about.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let old = renaming {
                    model.renameTag(old, to: renameText)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleting ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tag = deleting {
                    model.deleteTag(tag)
                }
                deleting = nil
            }
        } message: {
            Text("It's removed from every thread. The threads themselves stay.")
        }
    }

    private var missingProjects: [TakibiProject] {
        model.takibi.projects.filter { project in
            !model.allTags.contains { TagLibrary.slug($0) == TagLibrary.slug(project.name) }
        }
    }

    private func addTag() {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.createTag(name)
        newTag = ""
    }

    private func chooseLogo(for tag: String) {
        guard let url = chooseImage(message: "Choose a logo for “\(tag)”") else { return }
        do {
            try model.setLogo(for: tag, from: url)
            logoError = nil
        } catch {
            logoError = "Couldn't use that image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Takibi

struct TakibiSettings: View {
    var model: DeskModel
    @State private var installError: String?
    @State private var isInstalling = false
    @State private var pastedKey = ""
    @State private var keyError: String?
    @State private var isReplacingKey = false

    private var takibi: TakibiService { model.takibi }

    var body: some View {
        Form {
            Section {
                LabeledContent("Command-line tool") {
                    if let path = takibi.cliPath {
                        Text(path.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not installed")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Your key") {
                    if let error = takibi.projectsError {
                        Text(error)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    } else if takibi.cliPath != nil {
                        Text("Works with \(takibi.projects.count) \(takibi.projects.count == 1 ? "project" : "projects")")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                if takibi.cliPath != nil, takibi.hasKeyFile, takibi.projectsError == nil, !isReplacingKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved")
                                .foregroundStyle(.secondary)
                            Button("Replace…") {
                                isReplacingKey = true
                            }
                        }
                    }
                } else if takibi.cliPath != nil {
                    LabeledContent("Paste your API key") {
                        HStack {
                            SecureField("Key", text: $pastedKey, prompt: Text("publicId.secret"))
                                .labelsHidden()
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey)
                                .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if let keyError {
                        Text(keyError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Spacer()
                    if takibi.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Check Again") {
                        Task { await takibi.refresh() }
                    }
                    .disabled(takibi.isRefreshing)
                }
            } header: {
                Text("Takibi")
            } footer: {
                Text("Agents use the takibi command to search your knowledge base and update cards. \(Brand.name) saves a pasted key to ~/.takibi/key, readable only by you, and never sends it anywhere.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(AgentID.allCases, id: \.self) { agent in
                    LabeledContent {
                        Text(takibi.skillInstalled[agent] == true ? "Installed" : "Missing")
                            .foregroundStyle(takibi.skillInstalled[agent] == true ? Color.secondary : Color.orange)
                    } label: {
                        Label {
                            Text(agent.displayName)
                        } icon: {
                            AgentMark(agent: agent, size: 16)
                        }
                    }
                }
                HStack {
                    if let installError {
                        Text(installError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Install for Every Agent", action: install)
                        .disabled(isInstalling || takibi.cliPath == nil || !AgentID.allCases.contains { takibi.skillInstalled[$0] != true })
                }
            } header: {
                Text("Agent skill")
            } footer: {
                Text("The takibi-use skill teaches each agent how to use the takibi command.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(AgentID.allCases, id: \.self) { agent in
                    KeyFileRow(model: model, agent: agent)
                }
            } header: {
                Text("Separate keys (optional)")
            } footer: {
                Text("Paste a separate Takibi API key for an agent so Takibi records which agent made each change. \(Brand.name) saves each key in its own folder, readable only by you, and hands that agent's takibi the file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await takibi.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await takibi.refresh() }
        }
    }

    private func saveKey() {
        do {
            try takibi.saveKey(pastedKey)
            pastedKey = ""
            keyError = nil
            isReplacingKey = false
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func install() {
        isInstalling = true
        installError = nil
        Task {
            do {
                try await takibi.installSkill()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }
}

private struct KeyFileRow: View {
    var model: DeskModel
    let agent: AgentID
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        LabeledContent {
            if model.keyFile(for: agent) != nil {
                HStack {
                    Text("Own key")
                        .foregroundStyle(.secondary)
                    Button("Remove") {
                        model.removeAgentKey(for: agent)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        SecureField("Key", text: $key, prompt: Text("Uses your main key"))
                            .labelsHidden()
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else if fallsBackToMainKey {
                        Text("Without its own key, Takibi records \(agent.displayName)'s changes under your main key.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } label: {
            Label {
                Text(agent.displayName)
            } icon: {
                AgentMark(agent: agent, size: 16)
            }
        }
    }

    /// Once any agent has its own key, the others quietly using the main key are worth flagging.
    private var fallsBackToMainKey: Bool {
        model.keyFile(for: agent) == nil && AgentID.allCases.contains { model.keyFile(for: $0) != nil }
    }

    private func save() {
        do {
            try model.saveAgentKey(key, for: agent)
            key = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private func chooseImage(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}
