import Foundation

/// What `swarm_status` returns: the workers on this Mac, how much of each
/// vendor's quota they have left, and what every project scope is doing.
///
/// Keys are spelled out rather than converted: `convertFromSnakeCase` turns
/// `completed_24h` into `completed24H`, which no property is called.
///
/// Every list defaults to empty rather than failing the decode. The service is
/// ours but it moves faster than this app, and a worker row missing one array
/// should still draw a cell, not blank the whole notch.
struct SwarmaStatus: Decodable, Equatable {
    struct Worker: Equatable {
        struct Running: Decodable, Equatable {
            let taskId: String
            let scope: String?
            private enum CodingKeys: String, CodingKey { case taskId = "task_id", scope }
        }
        let name: String
        let lastSeenAt: Date?
        let live: Bool
        let running: [Running]
        let providers: [String]
    }

    struct Usage: Equatable {
        struct Window: Decodable, Equatable {
            let name: String?
            let usedPercent: Double?
            let resetsAt: Date?
            private enum CodingKeys: String, CodingKey { case name, usedPercent = "used_percent", resetsAt = "resets_at" }
        }
        let provider: String
        let ok: Bool
        /// Percent of the quota left, 0...100. Nil when the vendor could not be read.
        let headroom: Double?
        let windows: [Window]
        let plan: String?
        let error: String?
        let fetchedAt: Date?
    }

    struct Scope: Equatable {
        let scope: String
        let queued: Int
        let running: Int
        let blocked: Int
        let completed24h: Int
        let failed24h: Int
    }

    struct TaskRow: Equatable {
        let id: String
        let scope: String?
        let kind: String?
        let status: String?
        /// The optimistic-concurrency token `task_cancel` insists on.
        let version: Int?
        let objective: String?
        let requiredCapability: String?
        let updatedAt: Date?
        let worker: String?
        private enum CodingKeys: String, CodingKey {
            case id, scope, kind, status, version, objective, worker
            case requiredCapability = "required_capability", updatedAt = "updated_at"
        }
    }

    var workers: [Worker] = []
    var usage: [Usage] = []
    var scopes: [Scope] = []
    var recent: [TaskRow] = []
    var generatedAt: Date?

    init(workers: [Worker] = [], usage: [Usage] = [], scopes: [Scope] = [],
         recent: [TaskRow] = [], generatedAt: Date? = nil) {
        self.workers = workers
        self.usage = usage
        self.scopes = scopes
        self.recent = recent
        self.generatedAt = generatedAt
    }
}

private extension KeyedDecodingContainer {
    /// An absent or malformed list is an empty one; see `SwarmaStatus`.
    func list<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([T].self, forKey: key)) ?? nil) ?? []
    }
}

extension SwarmaStatus {
    private enum CodingKeys: String, CodingKey { case workers, usage, scopes, recent, generatedAt = "generated_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workers = c.list(.workers)
        usage = c.list(.usage)
        scopes = c.list(.scopes)
        recent = c.list(.recent)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }
}

extension SwarmaStatus.Worker: Decodable {
    private enum CodingKeys: String, CodingKey { case name, lastSeenAt = "last_seen_at", live, running, providers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        running = c.list(.running)
        providers = c.list(.providers)
    }
}

extension SwarmaStatus.Usage: Decodable {
    private enum CodingKeys: String, CodingKey { case provider, ok, headroom, windows, plan, error, fetchedAt = "fetched_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        headroom = try c.decodeIfPresent(Double.self, forKey: .headroom)
        windows = c.list(.windows)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
    }
}

extension SwarmaStatus.Scope: Decodable {
    private enum CodingKeys: String, CodingKey { case scope, queued, running, blocked, completed24h = "completed_24h", failed24h = "failed_24h" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(String.self, forKey: .scope)
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        blocked = try c.decodeIfPresent(Int.self, forKey: .blocked) ?? 0
        completed24h = try c.decodeIfPresent(Int.self, forKey: .completed24h) ?? 0
        failed24h = try c.decodeIfPresent(Int.self, forKey: .failed24h) ?? 0
    }
}

extension SwarmaStatus.TaskRow: Decodable {}

/// A running task a cell can offer to cancel. The version is part of it
/// because `task_cancel` refuses a stale one.
struct SwarmaCancelTarget: Equatable {
    let taskID: String
    let version: Int
    let title: String
}

/// Client for the local Swarma service (`POST {serviceURL}/api/tools/<tool>`).
///
/// One `swarm_status` answer feeds every cell: an agent cell and a swarm cell
/// are each a provider, and each provider fetches on its own, so without
/// sharing a single refresh would be a dozen identical requests. The answer —
/// or the failure — is held for `cacheTTL`, and concurrent callers share the
/// request already in flight.
///
/// The bearer token is read from its file on each request and goes nowhere
/// else: not into the cache, not into an error, not into the log.
actor SwarmaClient {
    static let shared = SwarmaClient()

    /// Everything that can go wrong, each already phrased for a cell.
    enum Failure: Error, Equatable {
        case badURL
        case insecureURL
        case noToken
        case unauthorized
        case http(Int)
        case unreachable
        case badResponse

        var message: String {
            switch self {
            case .unreachable:   return L10n.t("Swarmaa not running")
            case .noToken:       return L10n.t("Swarmaa token file unreadable")
            case .unauthorized:  return L10n.t("Swarmaa rejected the token")
            case .badURL:        return L10n.t("Swarmaa service URL is invalid")
            case .insecureURL:   return L10n.t("Swarmaa needs https off this Mac")
            case .http(let status): return L10n.t("Swarmaa error (HTTP \(status))")
            case .badResponse:   return L10n.t("Unexpected Swarmaa response")
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let serviceURL: @Sendable () -> String
    private let tokenPath: @Sendable () -> String
    private let transport: Transport
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: (key: String, at: Date, result: Result<SwarmaStatus, Failure>)?
    private var inFlight: (key: String, task: Task<SwarmaStatus, Error>)?

    init(
        serviceURL: @escaping @Sendable () -> String = { Preferences.storedSwarmaServiceURL() },
        tokenPath: @escaping @Sendable () -> String = { Preferences.storedSwarmaTokenPath() },
        transport: @escaping Transport = SwarmaClient.liveTransport,
        cacheTTL: TimeInterval = 4,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.serviceURL = serviceURL
        self.tokenPath = tokenPath
        self.transport = transport
        self.cacheTTL = cacheTTL
        self.now = now
    }

    // MARK: - Calls

    func status() async throws -> SwarmaStatus {
        let key = serviceURL() + "|" + tokenPath()
        if let cached, cached.key == key, now().timeIntervalSince(cached.at) < cacheTTL {
            return try cached.result.get()
        }
        if let inFlight, inFlight.key == key { return try await inFlight.task.value }

        let request = try makeRequest(tool: "swarm_status", body: Data("{}".utf8))
        let transport = self.transport
        let task = Task { () throws -> SwarmaStatus in
            let data = try await Self.send(request, via: transport)
            do {
                return try Self.decoder.decode(Envelope<SwarmaStatus>.self, from: data).result
            } catch {
                throw Failure.badResponse
            }
        }
        inFlight = (key, task)
        defer { inFlight = nil }
        do {
            let status = try await task.value
            cached = (key, now(), .success(status))
            return status
        } catch {
            let failure = error as? Failure ?? .unreachable
            cached = (key, now(), .failure(failure))
            throw failure
        }
    }

    func cancelTask(id: String, expectedVersion: Int) async throws {
        struct Body: Encodable {
            let taskId: String
            let expectedVersion: Int
            enum CodingKeys: String, CodingKey { case taskId = "task_id", expectedVersion = "expected_version" }
        }
        let body = try JSONEncoder().encode(Body(taskId: id, expectedVersion: expectedVersion))
        _ = try await Self.send(makeRequest(tool: "task_cancel", body: body), via: transport)
        // The next look must see the task gone, not the answer from before.
        cached = nil
    }

    // MARK: - Requests

    private struct Envelope<T: Decodable>: Decodable { let result: T }

    private struct TokenFile: Decodable { let token: String }

    private func makeRequest(tool: String, body: Data) throws -> URLRequest {
        var request = URLRequest(url: try Self.endpoint(serviceURL(), tool: tool))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(try readToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func readToken() throws -> String {
        let path = (tokenPath() as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(TokenFile.self, from: data),
              !file.token.isEmpty
        else { throw Failure.noToken }
        return file.token
    }

    /// Plain http only to this Mac. A bearer token over http to anywhere else
    /// would cross the network readable by whoever is on it.
    nonisolated static func endpoint(_ serviceURL: String, tool: String) throws -> URL {
        guard var parts = URLComponents(string: serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { throw Failure.badURL }
        if scheme == "http", !["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) {
            throw Failure.insecureURL
        }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        let base = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (base.isEmpty ? "" : "/" + base) + "/api/tools/\(tool)"
        guard let url = parts.url else { throw Failure.badURL }
        return url
    }

    private static func send(_ request: URLRequest, via transport: Transport) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw Failure.unauthorized
        default:        throw Failure.http(http.statusCode)
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // The service writes both "…:00Z" and "…:00.123Z".
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unrecognised date"))
            }
            return date
        }
        return decoder
    }()

    // MARK: - Live transport

    /// Refuses redirects: a 3xx would otherwise carry the Authorization header
    /// to wherever it points, and the token belongs to the configured URL only.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let liveTransport: Transport = { request in
        try await session.data(for: request)
    }
}
