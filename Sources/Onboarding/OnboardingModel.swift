import Foundation
import AppKit

/// Whether first-launch setup is still owed.
enum OnboardingGate {
    /// An install that already has Swarmaa configured (enabled, token file
    /// present) is complete; that is recorded so a later missing token does not
    /// send them back through it. Returns true when onboarding is needed.
    static func needsOnboarding(defaults: UserDefaults = .standard,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        if defaults.bool(forKey: Preferences.onboardingCompleteKey) { return false }
        let token = (Preferences.storedSwarmaTokenPath(defaults: defaults) as NSString).expandingTildeInPath
        if Preferences.storedSwarmaEnabled(defaults: defaults), fileExists(token) {
            defaults.set(true, forKey: Preferences.onboardingCompleteKey)
            return false
        }
        return true
    }
}

enum OnboardingPage: Int, CaseIterable {
    case welcome, services, projects, remote, review, progress, summary
}

struct OnboardingProject: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: String
    var entry: String { "\(name)=\(path)" }

    static func defaultName(for path: String) -> String {
        let base = (path as NSString).lastPathComponent.lowercased()
        let cleaned = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return cleaned.isEmpty ? "project" : cleaned
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    struct ServiceChoice: Equatable {
        var connect = false
        var worker = false
        var share = false
    }

    // Page flow
    @Published private(set) var page: OnboardingPage = .welcome

    // Welcome
    @Published var serviceRoot: String { didSet { if oldValue != serviceRoot { rootChanged() } } }
    @Published private(set) var detection: SetupDetection?
    @Published private(set) var detectionError: String?
    @Published private(set) var detecting = false

    // Services
    @Published var choices: [SetupHarness: ServiceChoice] = [:]

    // Projects, remote, login
    @Published var projects: [OnboardingProject] = []
    @Published var hostname = "api.swarmaa.com"
    @Published var setUpRemoteNow = false
    @Published var autostart = true

    // Review / progress / summary
    @Published private(set) var busy = false
    @Published private(set) var steps: [SetupStep] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var preview: SetupSummary?
    @Published private(set) var summary: SetupSummary?
    @Published private(set) var failure: String?

    private let defaults: UserDefaults
    private let engine: SetupEngine
    private let runOffMain: (@escaping () -> Void) -> Void
    private var detectToken = 0

    /// `runOffMain` is injectable so tests can run the engine inline.
    init(defaults: UserDefaults = .standard, engine: SetupEngine = SetupEngine(),
         runOffMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }) {
        self.defaults = defaults
        self.engine = engine
        self.runOffMain = runOffMain
        self.serviceRoot = defaults.string(forKey: Preferences.serviceRootKey) ?? Preferences.defaultSwarmaaServiceRoot
        for h in SetupHarness.allCases { choices[h] = ServiceChoice() }
        choices[.notchtrader] = ServiceChoice(connect: true)
        rootChanged()
    }

    // MARK: Welcome

    var rootURL: URL { URL(fileURLWithPath: (serviceRoot as NSString).expandingTildeInPath) }

    var rootIsValid: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rootURL.appendingPathComponent("scripts/setup.ts").path)
            && fm.fileExists(atPath: rootURL.appendingPathComponent("package.json").path)
    }

    private func rootChanged() {
        detection = nil
        detectionError = nil
        guard rootIsValid else { return }
        detecting = true
        detectToken += 1
        let token = detectToken, root = rootURL, engine = engine
        runOffMain { [weak self] in
            let result = Result { try engine.detect(root: root) }
            DispatchQueue.main.async {
                guard let self, self.detectToken == token else { return }
                self.detecting = false
                switch result {
                case .success(let d): self.apply(detection: d)
                case .failure(let e): self.detectionError = e.localizedDescription
                }
            }
        }
    }

    func retryDetection() { let r = serviceRoot; serviceRoot = ""; serviceRoot = r }

    func apply(detection d: SetupDetection) {
        detection = d
        let state = d.state
        for h in SetupHarness.allCases where h != .notchtrader {
            let installed = d.isInstalled(h)
            let hosted = h == .grok || h == .dot
            var c = ServiceChoice()
            if let state {
                c.connect = state.agents.contains(h.rawValue)
                c.worker = state.workers.contains(h.rawValue)
                c.share = state.sharing.contains(h.rawValue)
            } else {
                c.connect = installed
                c.share = installed && !hosted
            }
            choices[h] = c
        }
        if let state {
            if projects.isEmpty {
                projects = state.folders.compactMap(Self.project(fromEntry:))
            }
            if let autostart = state.autostart { self.autostart = autostart }
            if let host = state.remote?.hostname, !host.isEmpty { hostname = host; setUpRemoteNow = true }
        }
    }

    static func project(fromEntry entry: String) -> OnboardingProject? {
        guard let eq = entry.firstIndex(of: "=") else { return nil }
        return OnboardingProject(name: String(entry[..<eq]), path: String(entry[entry.index(after: eq)...]))
    }

    // MARK: Services

    static func canConnect(_ h: SetupHarness, installed: Bool) -> Bool {
        switch h {
        case .claude, .codex, .agy: return installed
        case .grok, .dot, .notchtrader: return true
        }
    }
    static func hasWorker(_ h: SetupHarness) -> Bool { h == .claude || h == .codex }
    static func hasSharing(_ h: SetupHarness) -> Bool { h == .claude || h == .codex || h == .agy }

    func isInstalled(_ h: SetupHarness) -> Bool { detection?.isInstalled(h) ?? false }

    var needsRemote: Bool { (choices[.grok]?.connect ?? false) || (choices[.dot]?.connect ?? false) }

    // MARK: Projects

    func addFolders(_ urls: [URL]) {
        for url in urls where !projects.contains(where: { $0.path == url.path }) {
            projects.append(OnboardingProject(name: OnboardingProject.defaultName(for: url.path), path: url.path))
        }
    }

    /// Why the project list can't be used yet, if it can't.
    var projectsProblem: String? {
        var seen = Set<String>()
        for p in projects {
            let name = p.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.contains("=") || name.contains(where: \.isWhitespace) {
                return "Scope names can't be empty or contain spaces or “=”."
            }
            if !seen.insert(name).inserted { return "Two projects are called “\(name)”." }
        }
        return nil
    }

    // MARK: Plan

    func makePlan() -> SetupPlan {
        var harnesses: [String: SetupPlan.Harness] = [:]
        for h in SetupHarness.allCases {
            let c = choices[h] ?? ServiceChoice()
            let connect = h == .notchtrader ? true : c.connect
            harnesses[h.rawValue] = .init(connect: connect,
                                          worker: connect && Self.hasWorker(h) && c.worker,
                                          share: connect && Self.hasSharing(h) && c.share)
        }
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return SetupPlan(harnesses: harnesses,
                         folders: projects.map { "\($0.name.trimmingCharacters(in: .whitespaces))=\($0.path)" },
                         remote: needsRemote && setUpRemoteNow && !host.isEmpty ? .init(hostname: host) : nil,
                         autostart: autostart)
    }

    // MARK: Navigation

    var canContinue: Bool {
        switch page {
        case .welcome: return rootIsValid && detection != nil
        case .projects: return projectsProblem == nil
        case .remote: return !setUpRemoteNow || !hostname.trimmingCharacters(in: .whitespaces).isEmpty
        case .review: return preview?.ok == true && !busy
        case .progress: return false
        default: return true
        }
    }

    var canGoBack: Bool { page != .welcome && page != .summary && !(page == .progress && busy) }

    static func next(after page: OnboardingPage, needsRemote: Bool) -> OnboardingPage? {
        switch page {
        case .projects: return needsRemote ? .remote : .review
        default: return OnboardingPage(rawValue: page.rawValue + 1)
        }
    }

    static func previous(before page: OnboardingPage, needsRemote: Bool) -> OnboardingPage? {
        switch page {
        case .review: return needsRemote ? .remote : .projects
        case .progress: return .review
        default: return OnboardingPage(rawValue: page.rawValue - 1)
        }
    }

    func goBack() {
        guard canGoBack, let p = Self.previous(before: page, needsRemote: needsRemote) else { return }
        failure = nil
        page = p
    }

    /// Continue / Connect.
    func goNext() {
        guard canContinue, let n = Self.next(after: page, needsRemote: needsRemote) else { return }
        if page == .welcome { defaults.set(serviceRoot, forKey: Preferences.serviceRootKey) }
        page = n
        if n == .review { runPreview() }
        if n == .progress { runForReal() }
    }

    // MARK: Engine runs

    func runPreview() {
        preview = nil; failure = nil; steps = []; busy = true
        execute(dry: true) { [weak self] summary, error in
            self?.preview = summary
            self?.failure = summary?.ok == false ? (summary?.error ?? "The preview reported a problem.") : error
        }
    }

    func runForReal() {
        summary = nil; failure = nil; steps = []; log = []; busy = true
        execute(dry: false) { [weak self] summary, error in
            guard let self else { return }
            self.summary = summary
            if let summary, summary.ok { self.page = .summary; self.applyToApp(summary) }
            else { self.failure = summary?.error ?? error ?? "Setup did not finish." }
        }
    }

    func retry() { page == .review ? runPreview() : runForReal() }

    private func execute(dry: Bool, done: @escaping (SetupSummary?, String?) -> Void) {
        let plan = makePlan(), root = rootURL, engine = engine
        runOffMain { [weak self] in
            let onMain: (@escaping (OnboardingModel) -> Void) -> Void = { work in
                DispatchQueue.main.async { if let self { work(self) } }
            }
            do {
                let summary = try engine.run(plan: plan, dry: dry, root: root,
                    onEvent: { event in onMain { $0.handle(event) } },
                    onRaw: { line in onMain { $0.log.append(line) } })
                onMain { $0.busy = false; done(summary, nil) }
            } catch {
                onMain { $0.busy = false; done(nil, error.localizedDescription) }
            }
        }
    }

    private func handle(_ event: SetupEvent) {
        switch event {
        case .step(let s):
            if let i = steps.firstIndex(where: { $0.id == s.id }) { steps[i] = s } else { steps.append(s) }
        case .log(let line): log.append(line)
        case .summary, .error: break
        }
    }

    // MARK: Finish

    /// Point the notch at the service that was just set up.
    private func applyToApp(_ summary: SetupSummary) {
        defaults.set(serviceRoot, forKey: Preferences.serviceRootKey)
        defaults.set(true, forKey: "swarmaEnabled")
        defaults.set(rootURL.appendingPathComponent(".local/notchtrader.json").path, forKey: "swarmaTokenPath")
        if let url = summary.serviceUrl, !url.isEmpty { defaults.set(url, forKey: "swarmaServiceURL") }
    }

    func markComplete() { defaults.set(true, forKey: Preferences.onboardingCompleteKey) }

    func copyMCPURL() {
        guard let url = summary?.mcpUrl else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
