import Foundation

extension DeskModel {
    func refreshTools() async {
        let jobs = activeAgents.map { ($0, availability[$0]?.binary) }
        let home = homeDirectory
        let environment = environment
        let runner = toolsRunner
        await withTaskGroup(of: (AgentID, AgentTools).self) { group in
            for job in jobs {
                group.addTask {
                    (job.0, await Self.loadTools(agent: job.0, binary: job.1, home: home, environment: environment, runner: runner))
                }
            }
            for await (agent, loaded) in group {
                tools[agent] = loaded
            }
        }
    }

    func addServer(name: String, url: URL, to agents: [AgentID]) async -> [AgentID: String?] {
        var results: [AgentID: String?] = [:]
        guard ToolsCommand.isValidName(name) else {
            return Dictionary(uniqueKeysWithValues: agents.map { ($0, "Use letters, numbers, dashes, underscores, or dots in the name.") })
        }
        guard ToolsCommand.isValidURL(url) else {
            return Dictionary(uniqueKeysWithValues: agents.map { ($0, "The URL must start with http:// or https://.") })
        }
        for agent in agents {
            results[agent] = await add(name: name, url: url, to: agent)
        }
        await refreshTools()
        return results
    }

    func removeServer(_ name: String, from agent: AgentID) async throws {
        do {
            try await remove(name, from: agent)
        } catch {
            await refreshTools()
            throw error
        }
        await refreshTools()
    }

    func openToolSignIn(for agent: AgentID, server: String) {
        guard let binary = availability[agent]?.binary else { return }
        openTerminal(TerminalScript.commandFile(
            executable: binary,
            arguments: ToolsCommand.signInArguments(for: agent, name: server)
        ))
    }

    private func remove(_ name: String, from agent: AgentID) async throws {
        if agent == .muse {
            try MuseSettings.remove(name: name, from: MuseSettings.file(home: homeDirectory, environment: environment))
            return
        }
        guard let binary = availability[agent]?.binary, let arguments = ToolsCommand.removeArguments(for: agent, name: name) else {
            throw ToolsFailure("\(agent.displayName) isn't installed.")
        }
        let output = await toolsRunner(binary, arguments)
        if let failure = ToolsCommand.failureText(output, fallback: "Couldn't remove \(name).") {
            throw ToolsFailure(failure)
        }
    }

    private func add(name: String, url: URL, to agent: AgentID) async -> String? {
        if agent == .muse {
            do {
                try MuseSettings.add(name: name, url: url, to: MuseSettings.file(home: homeDirectory, environment: environment))
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        guard let binary = availability[agent]?.binary, let arguments = ToolsCommand.addArguments(for: agent, name: name, url: url) else {
            return "\(agent.displayName) isn't installed."
        }
        let output = await toolsRunner(binary, arguments)
        return ToolsCommand.failureText(output, fallback: "Couldn't add \(name).")
    }

    @concurrent
    private static func loadTools(
        agent: AgentID,
        binary: URL?,
        home: URL,
        environment: [String: String],
        runner: @Sendable (URL, [String]) async -> SignInOutput?
    ) async -> AgentTools {
        var loaded = AgentTools()
        switch agent {
        case .muse:
            do {
                loaded.servers = try MuseSettings.servers(at: MuseSettings.file(home: home, environment: environment))
            } catch {
                loaded.error = error.localizedDescription
            }
            if let binary, let output = await runner(binary, ToolsCommand.museSkillsArguments), output.exitCode == 0 {
                loaded.skills = ToolsParser.museSkills(from: output.stdout)
            }
        case .claude, .codex, .grok:
            loaded.skills = skillFolders(agent, home: home)
            guard let binary, let arguments = ToolsCommand.listArguments(for: agent) else {
                loaded.error = "\(agent.displayName) isn't installed."
                return loaded
            }
            let output = await runner(binary, arguments)
            if let failure = ToolsCommand.failureText(output, fallback: "Couldn't list servers.") {
                loaded.error = failure
            } else if let output {
                switch agent {
                case .claude: loaded.servers = ToolsParser.claude(from: output.stdout)
                case .codex: loaded.servers = ToolsParser.codex(from: output.stdout)
                default: loaded.servers = ToolsParser.grok(from: output.stdout)
                }
            }
        }
        return loaded
    }

    nonisolated private static func skillFolders(_ agent: AgentID, home: URL) -> [String] {
        let directory = URL(filePath: TakibiPaths.skillsDirectory(agent, home: home), directoryHint: .isDirectory)
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
