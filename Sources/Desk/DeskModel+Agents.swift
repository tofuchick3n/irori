import Foundation

extension DeskModel {
    func selectedModel(for agent: AgentID) -> String? {
        selectedModels[agent]
    }

    func setSelectedModel(_ id: String?, for agent: AgentID) {
        let key = Self.modelKey(agent)
        if let id, !id.isEmpty {
            defaults.set(id, forKey: key)
            selectedModels[agent] = id
        } else {
            defaults.removeObject(forKey: key)
            selectedModels[agent] = nil
        }
        if let effort = selectedEfforts[agent],
           !catalog.efforts(for: agent, model: selectedModels[agent]).contains(where: { $0.id == effort }) {
            setSelectedEffort(nil, for: agent)
        }
    }

    func selectedEffort(for agent: AgentID) -> String? {
        selectedEfforts[agent]
    }

    /// The model a reply runs on and the picker shows: the chosen one, else the catalog's default.
    /// Nil until the catalog lists any, which leaves the choice to the CLI.
    func modelForRun(for agent: AgentID) -> String? {
        selectedModel(for: agent) ?? catalog.defaultModel(for: agent)?.id
    }

    /// The effort a reply runs with and the picker shows: the chosen one if that model lists it,
    /// else the model's default; with no default known it is left unset for the CLI. Until the
    /// catalog has loaded there's nothing to check against, so the saved effort is used as is.
    func effortForRun(for agent: AgentID) -> String? {
        let efforts = catalog.efforts(for: agent, model: modelForRun(for: agent))
        let fallback = efforts.first(where: \.isDefault)?.id
        guard let selected = selectedEffort(for: agent) else { return fallback }
        guard !(catalog.options[agent] ?? []).isEmpty else { return selected }
        return efforts.first { $0.id == selected }?.id ?? fallback
    }

    func setSelectedEffort(_ id: String?, for agent: AgentID) {
        let key = Self.effortKey(agent)
        if let id, !id.isEmpty {
            defaults.set(id, forKey: key)
            selectedEfforts[agent] = id
        } else {
            defaults.removeObject(forKey: key)
            selectedEfforts[agent] = nil
        }
    }

    static func loadSelectedModels(from defaults: UserDefaults) -> [AgentID: String] {
        var models: [AgentID: String] = [:]
        for agent in AgentID.allCases {
            if let value = defaults.string(forKey: modelKey(agent)), !value.isEmpty {
                models[agent] = value
            }
        }
        return models
    }

    private static func modelKey(_ agent: AgentID) -> String {
        "model.\(agent.rawValue)"
    }

    static func loadSelectedEfforts(from defaults: UserDefaults) -> [AgentID: String] {
        var efforts: [AgentID: String] = [:]
        for agent in AgentID.allCases {
            if let value = defaults.string(forKey: effortKey(agent)), !value.isEmpty {
                efforts[agent] = value
            }
        }
        return efforts
    }

    private static func effortKey(_ agent: AgentID) -> String {
        "effort.\(agent.rawValue)"
    }

    func setDefaultAgent(_ agent: AgentID) {
        defaultAgent = agent
        defaults.set(agent.rawValue, forKey: Self.defaultAgentKey)
    }

    /// Makes `agent` the default and stops earlier mentions in the open thread from overriding it.
    func chooseNextReplier(_ agent: AgentID) {
        setDefaultAgent(agent)
        forgetEarlierMentions()
    }

    /// True when earlier mentions, not the draft, pick someone other than the default agent.
    var repliersCarryOver: Bool {
        guard Turn.mentionedAgents(in: draft).isEmpty, let agent = effectiveDefaultAgent else { return false }
        let next = nextRecipients
        return !next.isEmpty && next != [agent]
    }

    /// Hands the open thread back to the default agent, ignoring who earlier messages mentioned.
    func forgetEarlierMentions() {
        guard let selection, let index = threads.firstIndex(where: { $0.id == selection }) else { return }
        threads[index].mentionsFrom = threads[index].messages.count
        persist(threads[index])
    }

    func refreshSignIn() async {
        let jobs = activeAgents.map { ($0, availability[$0]?.binary) }
        let home = homeDirectory
        let environment = environment
        let probe = signInProbe
        await withTaskGroup(of: (AgentID, SignInState).self) { group in
            for job in jobs {
                let agent = job.0
                let binary = job.1
                group.addTask {
                    let state = await SignInCheck.evaluate(
                        agent: agent,
                        binary: binary,
                        home: home,
                        environment: environment,
                        probe: probe
                    )
                    return (agent, state)
                }
            }
            for await (agent, state) in group {
                signIn[agent] = state
            }
        }
    }

    /// Checks one agent again and records the result.
    @discardableResult
    func checkSignIn(for agent: AgentID) async -> SignInState {
        let state = await SignInCheck.evaluate(
            agent: agent,
            binary: availability[agent]?.binary,
            home: homeDirectory,
            environment: environment,
            probe: signInProbe
        )
        signIn[agent] = state
        return state
    }

    /// For the Welcome window: what is installed and signed in right now.
    func refreshReadiness() async {
        refreshAvailability()
        await refreshSignIn()
    }

    func completeWelcome() {
        hasSeenWelcome = true
        if threads.isEmpty {
            newThread()
        }
    }

    func openSignIn(for agent: AgentID) {
        guard let binary = availability[agent]?.binary else { return }
        openTerminal(TerminalScript.commandFile(
            executable: binary,
            arguments: SignInCommand.loginArguments(for: agent)
        ))
    }

    func refreshAvailability() {
        probedInstallation = true
        var resolved: [AgentID: AgentAvailability] = [:]
        for agent in AgentID.allCases {
            resolved[agent] = AgentAvailability(binary: resolvedBinary(for: agent))
        }
        availability = resolved
        syncCatalog()
    }

    func isEnabled(_ agent: AgentID) -> Bool {
        enabledSettings[agent] ?? true
    }

    func setEnabled(_ enabled: Bool, for agent: AgentID) {
        defaults.set(enabled, forKey: Self.enabledKey(agent))
        enabledSettings[agent] = enabled
        syncCatalog()
    }

    func binaryOverride(for agent: AgentID) -> String? {
        binaryOverrides[agent]
    }

    /// Where Desk keeps an agent's own pasted Takibi key.
    func agentKeyURL(for agent: AgentID) -> URL {
        supportDirectory
            .appending(path: "takibi-keys", directoryHint: .isDirectory)
            .appending(path: "\(agent.rawValue).key", directoryHint: .notDirectory)
    }

    /// Saves a pasted API key for one agent and points that agent's takibi at it.
    func saveAgentKey(_ key: String, for agent: AgentID) throws {
        let file = agentKeyURL(for: agent)
        try TakibiKey.write(key, to: file)
        setKeyFile(file.path(percentEncoded: false), for: agent)
    }

    /// Back to the main key; deletes the file only when Desk wrote it.
    func removeAgentKey(for agent: AgentID) {
        let file = agentKeyURL(for: agent)
        if keyFile(for: agent) == file.path(percentEncoded: false) {
            try? FileManager.default.removeItem(at: file)
        }
        setKeyFile(nil, for: agent)
    }

    func keyFile(for agent: AgentID) -> String? {
        keyFiles[agent]
    }

    func setKeyFile(_ path: String?, for agent: AgentID) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = Self.keyFileKey(agent)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
            keyFiles[agent] = nil
        } else {
            defaults.set(trimmed, forKey: key)
            keyFiles[agent] = trimmed
        }
    }

    func setBinaryOverride(_ path: String?, for agent: AgentID) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = Self.pathKey(agent)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
            binaryOverrides[agent] = nil
        } else {
            defaults.set(trimmed, forKey: key)
            binaryOverrides[agent] = trimmed
        }
        refreshAvailability()
    }

    /// Lets agents run `program` from now on, as if it were added in Settings → Permissions.
    func allowCommand(_ program: String) {
        let name = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !allowedCommands.contains(name) else { return }
        allowedCommands.append(name)
    }

    private func resolvedBinary(for agent: AgentID) -> URL? {
        if let override = binaryOverrides[agent] {
            return executableFile(at: AgentCommand.expandingTilde(override, home: homeDirectory))
        }
        return AgentCommand.resolve(candidates: AgentCommand.candidatePaths(for: agent, home: homeDirectory), isExecutable: isExecutable)
            .flatMap { url in executableFile(at: url.path(percentEncoded: false)) }
    }

    private func executableFile(at path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        guard isExecutable(path) else { return nil }
        return URL(filePath: path)
    }

    /// Only an explicit override replaces the runner's own search. Tests pass a stand-in on the runner itself.
    func launchExecutable(for agent: AgentID) -> URL? {
        guard binaryOverrides[agent] != nil else { return nil }
        return availability[agent]?.binary
    }

    func syncCatalog() {
        catalog.activeAgents = activeAgents
        guard probedInstallation else { return }
        var resolved: [AgentID: URL] = [:]
        for agent in AgentID.allCases {
            if let binary = availability[agent]?.binary {
                resolved[agent] = binary
            }
        }
        catalog.binaries = resolved
    }

    static func loadEnabled(from defaults: UserDefaults) -> [AgentID: Bool] {
        var enabled: [AgentID: Bool] = [:]
        for agent in AgentID.allCases where defaults.object(forKey: enabledKey(agent)) != nil {
            enabled[agent] = defaults.bool(forKey: enabledKey(agent))
        }
        return enabled
    }

    func environmentKeyFile(for agent: AgentID) -> String? {
        guard let stored = keyFile(for: agent) else { return nil }
        let expanded = AgentCommand.expandingTilde(stored, home: homeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return expanded.isEmpty ? nil : expanded
    }

    static func loadKeyFiles(from defaults: UserDefaults) -> [AgentID: String] {
        var files: [AgentID: String] = [:]
        for agent in AgentID.allCases {
            if let value = defaults.string(forKey: keyFileKey(agent))?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                files[agent] = value
            }
        }
        return files
    }

    private static func keyFileKey(_ agent: AgentID) -> String {
        "takibi.key.\(agent.rawValue)"
    }

    static func loadOverrides(from defaults: UserDefaults) -> [AgentID: String] {
        var paths: [AgentID: String] = [:]
        for agent in AgentID.allCases {
            if let value = defaults.string(forKey: pathKey(agent))?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                paths[agent] = value
            }
        }
        return paths
    }

    private static func enabledKey(_ agent: AgentID) -> String {
        "agent.\(agent.rawValue).enabled"
    }

    private static func pathKey(_ agent: AgentID) -> String {
        "agent.\(agent.rawValue).path"
    }
}
