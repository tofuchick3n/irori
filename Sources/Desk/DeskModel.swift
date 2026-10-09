import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DeskModel {
    let store: ThreadStore
    let runner: any AgentRunner
    let workspacesDirectory: URL
    let trash: @Sendable (URL) throws -> Void
    let defaults: UserDefaults
    /// Each agent's chosen model, mirrored from `defaults` so pickers and labels redraw when it changes.
    var selectedModels: [AgentID: String] = [:]
    /// Each agent's chosen effort, mirrored from `defaults` so pickers redraw when it changes.
    var selectedEfforts: [AgentID: String] = [:]
    /// Who answers when nothing in the thread has mentioned anyone yet. Stored under `defaultAgent`.
    var defaultAgent: AgentID = .claude
    /// The sidebar lists archived threads instead of active ones.
    var showsArchived = false {
        didSet { keepSelectionVisible() }
    }
    /// Nil shows every thread. Stored in `defaults` under `sidebar.tagFilter`.
    var tagFilter: String? {
        didSet {
            storeTagFilter()
            keepSelectionVisible()
        }
    }
    let catalog: ModelCatalog
    let profile: UserProfile
    let takibi: TakibiService
    /// Resolved at launch and again from `refreshAvailability()`.
    var availability: [AgentID: AgentAvailability] = [:]
    /// Nil until that agent's sign-in check finishes. Inactive agents are left alone.
    var signIn: [AgentID: SignInState] = [:]
    var tools: [AgentID: AgentTools] = [:]
    var allowsFileWrites: Bool = true {
        didSet { defaults.set(allowsFileWrites, forKey: Self.writesKey) }
    }
    var allowedCommands: [String] = ["takibi"] {
        didSet {
            let normalized = Self.normalizedCommands(allowedCommands)
            if normalized != allowedCommands {
                allowedCommands = normalized
                return
            }
            defaults.set(allowedCommands, forKey: Self.commandsKey)
        }
    }

    /// Tool rules allowed everywhere. Stored in `defaults` under `permissions.alwaysAllowed`.
    var alwaysAllowedTools: [String] = ["WebSearch", "WebFetch"] {
        didSet { defaults.set(alwaysAllowedTools, forKey: Self.alwaysAllowedKey) }
    }
    /// Approval cards still waiting for the person, by message.
    var approvalWaiters: [Message.ID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    let supportDirectory: URL
    let homeDirectory: URL
    let environment: [String: String]
    let isExecutable: @Sendable (String) -> Bool
    let signInProbe: @Sendable (URL, [String]) async -> SignInOutput?
    let openTerminal: @Sendable (String) -> Void
    let toolsRunner: @Sendable (URL, [String]) async -> SignInOutput?
    var probedInstallation = false
    var enabledSettings: [AgentID: Bool] = [:]
    var binaryOverrides: [AgentID: String] = [:]
    var keyFiles: [AgentID: String] = [:]
    var knownTags: [String] = []
    var tagsError: String?
    var logoRevision = 0
    let logos = LogoCache()
    let dictation = Dictation()

    var threads: [Thread]
    var selection: Thread.ID? {
        didSet {
            markRead(selection)
            findIndex = nil
            // Words keep going to the thread they were started in, so stop when it's no longer shown.
            if let dictating = dictation.threadID, dictating != selection {
                Task { await dictation.finish() }
            }
        }
    }
    /// Sidebar search words; empty shows every thread the other filters allow.
    var searchText = ""
    var showsFiles = false
    /// The Settings tab showing, so a notice can open Settings on Agents.
    var settingsTab = "General"
    /// Bumped to move the keyboard focus into the composer.
    var composerFocusRequest = 0
    var isFinding = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { findIndex = nil } }
    }
    /// The current match among the open thread's matches; nil means the newest one.
    var findIndex: Int?
    /// Bumped to move the keyboard focus into the find field.
    var findFocusRequest = 0
    var hasSeenWelcome = false {
        didSet { defaults.set(hasSeenWelcome, forKey: Self.welcomeKey) }
    }
    /// Threads that finished a turn while the app was inactive and haven't been opened since.
    var unreadThreads: Set<Thread.ID> = [] {
        didSet { notifier.setBadge(unreadThreads.count) }
    }
    let notifier: any TurnNotifier
    let isAppActive: @MainActor () -> Bool
    var drafts: [Thread.ID: String] = [:]
    var draft: String {
        get {
            guard let selection else { return "" }
            return drafts[selection] ?? ""
        }
        set {
            guard let selection else { return }
            drafts[selection] = newValue
        }
    }
    var pendingAttachments: [Thread.ID: [URL]] = [:]
    /// Files waiting to go with the next message in the open thread.
    var attachments: [URL] {
        get {
            guard let selection else { return [] }
            return pendingAttachments[selection] ?? []
        }
        set {
            guard let selection else { return }
            pendingAttachments[selection] = newValue.isEmpty ? nil : newValue
        }
    }
    var renameText = ""
    var isRenaming = false
    var streamingMessageID: Message.ID?
    var liveReply: LiveReply?
    var activity: String?
    var renameTarget: Thread.ID?
    var runTask: Task<Void, Never>?
    var runningThreadID: Thread.ID?
    var runningAgent: AgentID?
    private var loadError: String?
    /// What went wrong for each thread whose save or delete hasn't succeeded yet.
    var storageFailures: [Thread.ID: String] = [:]
    var failedDeletes: Set<Thread.ID> = []

    var isRunning: Bool { runTask != nil }

    /// Whether the selected thread is the one an agent is replying in.
    var selectedThreadIsRunning: Bool {
        runningThreadID != nil && runningThreadID == selection
    }

    var runningThreadTitle: String? {
        guard let runningThreadID else { return nil }
        return threads.first { $0.id == runningThreadID }?.title
    }

    /// Why what's on disk may not match what's shown, until loading or saving succeeds again.
    var saveError: String? {
        loadError ?? tagsError ?? storageFailures.values.sorted().first
    }

    var orderedThreads: [Thread] {
        threads.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// What the sidebar lists: the archive and tag filters, then the search.
    var visibleThreads: [Thread] {
        filteredThreads.filter { ThreadSearch.matches($0, query: searchText) }
    }

    /// The threads the archive toggle and tag filter allow, before any search.
    var filteredThreads: [Thread] {
        let listed = orderedThreads.filter { ($0.archivedAt != nil) == showsArchived }
        guard let tagFilter else { return listed }
        return listed.filter { thread in
            thread.tags.contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
        }
    }

    var archivedCount: Int {
        threads.count { $0.archivedAt != nil }
    }

    /// Tags from `tags.json`, plus every tag used on a thread. One spelling per name, ignoring case.
    var allTags: [String] {
        var seen: [String: String] = [:]
        for name in knownTags where seen[name.lowercased()] == nil {
            seen[name.lowercased()] = name
        }
        for thread in threads {
            for tag in thread.tags where seen[tag.lowercased()] == nil {
                seen[tag.lowercased()] = tag
            }
        }
        return seen.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Enabled and installed, in `AgentID` order.
    var activeAgents: [AgentID] {
        AgentID.allCases.filter { isEnabled($0) && (availability[$0]?.isInstalled == true) }
    }

    /// Who answers a message that names nobody, given who is actually available.
    var effectiveDefaultAgent: AgentID? {
        if activeAgents.contains(defaultAgent) {
            return defaultAgent
        }
        return activeAgents.first
    }

    var selectedThread: Thread? {
        guard let selection else { return nil }
        return threads.first { $0.id == selection }
    }

    /// Who will answer the draft as typed, in reply order.
    var nextRecipients: [AgentID] {
        guard let thread = selectedThread else { return [] }
        return delivery(for: draft, earlierUserTexts: userTexts(in: thread)).recipients
    }

    init(
        store: ThreadStore,
        runner: any AgentRunner = EchoAgentRunner(),
        workspacesDirectory: URL? = nil,
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        defaults: UserDefaults = .standard,
        catalog: ModelCatalog = ModelCatalog(),
        supportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        assumeInstalled: Bool = true,
        accountPicture: (@MainActor () -> NSImage?)? = nil,
        takibi: TakibiService? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        signInProbe: @escaping @Sendable (URL, [String]) async -> SignInOutput? = { executable, arguments in
            await SignInCLI.run(executable: executable, arguments: arguments)
        },
        openTerminal: @escaping @Sendable (String) -> Void = { TerminalScript.open($0) },
        toolsRunner: @escaping @Sendable (URL, [String]) async -> SignInOutput? = { executable, arguments in
            await SignInCLI.run(executable: executable, arguments: arguments, timeout: .seconds(20))
        },
        notifier: any TurnNotifier = NoTurnNotifier(),
        isAppActive: @escaping @MainActor () -> Bool = { true }
    ) {
        self.notifier = notifier
        self.isAppActive = isAppActive
        self.store = store
        self.runner = runner
        self.trash = trash
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.isExecutable = isExecutable
        self.signInProbe = signInProbe
        self.openTerminal = openTerminal
        self.toolsRunner = toolsRunner
        selectedModels = Self.loadSelectedModels(from: defaults)
        defaultAgent = defaults.string(forKey: Self.defaultAgentKey).flatMap(AgentID.init(rawValue:)) ?? .claude
        selectedEfforts = Self.loadSelectedEfforts(from: defaults)
        if let stored = defaults.string(forKey: Self.tagFilterKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            tagFilter = stored
        }
        allowsFileWrites = defaults.object(forKey: Self.writesKey) == nil ? true : defaults.bool(forKey: Self.writesKey)
        if defaults.object(forKey: Self.commandsKey) != nil {
            allowedCommands = Self.normalizedCommands(defaults.stringArray(forKey: Self.commandsKey) ?? [])
        }
        if let stored = defaults.stringArray(forKey: Self.alwaysAllowedKey) {
            alwaysAllowedTools = stored
        }
        hasSeenWelcome = defaults.bool(forKey: Self.welcomeKey)
        enabledSettings = Self.loadEnabled(from: defaults)
        binaryOverrides = Self.loadOverrides(from: defaults)
        keyFiles = Self.loadKeyFiles(from: defaults)
        self.catalog = catalog
        self.takibi = takibi ?? .inactive(home: homeDirectory)
        let support = supportDirectory ?? store.directory.appending(path: ".desk", directoryHint: .isDirectory)
        self.supportDirectory = support
        profile = UserProfile(folder: support, defaults: defaults, accountPicture: accountPicture ?? { nil })
        knownTags = TagLibrary.load(from: support)
        self.workspacesDirectory = workspacesDirectory
            ?? store.directory.appending(path: "workspaces", directoryHint: .isDirectory)
        do {
            threads = try store.load()
        } catch {
            threads = []
            loadError = "Couldn't read your saved threads: \(error.localizedDescription)"
        }
        selection = filteredThreads.first?.id
        if assumeInstalled {
            // Tests skip the machine's CLIs. A stand-in keeps every agent active until a real probe.
            let standIn = URL(filePath: "/usr/bin/true")
            var installed: [AgentID: AgentAvailability] = [:]
            for agent in AgentID.allCases {
                installed[agent] = AgentAvailability(binary: standIn)
            }
            availability = installed
            syncCatalog()
        } else {
            refreshAvailability()
        }
    }

    convenience init() {
        let catalog = ModelCatalog()
        let takibi = TakibiService()
        let notifier = SystemTurnNotifier.ifBundled()
        self.init(
            store: ThreadStore(directory: ThreadStore.applicationSupportDirectory),
            runner: RoutingAgentRunner(),
            workspacesDirectory: ThreadStore.workspacesDirectory,
            catalog: catalog,
            supportDirectory: ThreadStore.supportDirectory,
            assumeInstalled: false,
            accountPicture: { AccountPicture.load() },
            takibi: takibi,
            notifier: notifier,
            isAppActive: { NSApplication.shared.isActive }
        )
        notifier.onOpen = { [weak self] id in self?.openThread(id) }
        Task { await catalog.refresh() }
        Task { await takibi.refresh() }
        Task { await refreshSignIn() }
    }

    private static let tagFilterKey = "sidebar.tagFilter"
    static let defaultAgentKey = "defaultAgent"
    static let welcomeKey = "hasSeenWelcome"
    private static let writesKey = "permissions.writes"
    private static let commandsKey = "permissions.commands"
    private static let alwaysAllowedKey = "permissions.alwaysAllowed"

    /// Reads saved threads again if loading failed, then retries every save and delete that failed.
    func retrySave() {
        if loadError != nil, let loaded = try? store.load() {
            let shown = Set(threads.map(\.id))
            threads += loaded.filter { !shown.contains($0.id) }
            loadError = nil
            if selection == nil {
                selection = filteredThreads.first?.id
            }
        }
        for thread in threads where storageFailures[thread.id] != nil && !failedDeletes.contains(thread.id) {
            persist(thread)
        }
        for id in failedDeletes {
            delete(id)
        }
        if tagsError != nil {
            saveKnownTags()
        }
    }

    func persist(_ thread: Thread) {
        do {
            try store.save(thread)
            if !failedDeletes.contains(thread.id) {
                storageFailures[thread.id] = nil
            }
        } catch {
            storageFailures[thread.id] = "Couldn't save “\(thread.title)”: \(error.localizedDescription)"
        }
    }

    /// Keeps the open thread one the sidebar shows, so the composer never sends into a hidden thread.
    func keepSelectionVisible() {
        guard let selection, !filteredThreads.contains(where: { $0.id == selection }) else { return }
        self.selection = filteredThreads.first?.id
    }

    private static func normalizedCommands(_ commands: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for command in commands {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func storeTagFilter() {
        let trimmed = tagFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if trimmed != tagFilter {
                tagFilter = trimmed
                return
            }
            defaults.set(trimmed, forKey: Self.tagFilterKey)
        } else {
            if tagFilter != nil {
                tagFilter = nil
                return
            }
            defaults.removeObject(forKey: Self.tagFilterKey)
        }
    }

    func index(of id: Thread.ID) -> Int? {
        threads.firstIndex { $0.id == id }
    }

    func userTexts(in thread: Thread) -> [String] {
        thread.messages.dropFirst(thread.mentionsFrom).compactMap { message in
            guard case .user = message.author else { return nil }
            return message.body
        }
    }
}
