import Foundation

/// A bounded read pool and one automation queue per application.
public final class RequestScheduler {
    private let reads: OperationQueue
    private var automation: [String: OperationQueue] = [:]
    private var pending: [String: Int] = [:]
    private let lock = NSLock()
    public init() {
        reads = OperationQueue(); reads.name = "ApplePersonalMCP.reads"; reads.maxConcurrentOperationCount = 4
    }
    public func submit(agentID: String, automationApp: String?, work: @escaping () throws -> Data, reply: @escaping (Data) -> Void) throws {
        lock.lock()
        guard pending.values.reduce(0, +) < 64, pending[agentID, default: 0] < 16 else {
            lock.unlock(); throw ServiceError("server_busy", "Too many outstanding requests; retry later")
        }
        pending[agentID, default: 0] += 1
        let queue: OperationQueue
        if let app = automationApp {
            if let existing = automation[app] { queue = existing }
            else {
                queue = OperationQueue(); queue.name = "ApplePersonalMCP.automation.\(app)"; queue.maxConcurrentOperationCount = 1
                automation[app] = queue
            }
        } else { queue = reads }
        lock.unlock()
        queue.addOperation {
            let data: Data
            do { data = try work() } catch { data = (try? JSONEncoder().encode(ToolReply.failure(error))) ?? Data() }
            self.lock.lock(); self.pending[agentID, default: 1] -= 1
            if self.pending[agentID] == 0 { self.pending.removeValue(forKey: agentID) }; self.lock.unlock()
            reply(data)
        }
    }
}

public final class AgentSession {
    public let id = UUID().uuidString
    private let lock = NSLock()
    private var credential: AgentCredential?
    private var active = true
    private var requests: [String: Bool] = [:]
    private var earlyCancellation: [String: Date] = [:]
    public init() {}
    public func bind(_ value: AgentCredential?) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw ServiceError("disconnected", "Client disconnected before execution") }
        if let credential, credential != value { throw ServiceError("identity_changed", "An XPC connection cannot change Agent identity") }
        credential = value
    }
    public func invalidate() { lock.lock(); active = false; lock.unlock() }
    public func begin(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw ServiceError("disconnected", "Connection closed") }
        guard UUID(uuidString: id) != nil, requests[id] == nil else { throw ServiceError("invalid_request", "Request UUID is invalid or already active") }
        requests[id] = earlyCancellation.removeValue(forKey: id) == nil
    }
    public func cancel(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if requests[id] != nil { requests[id] = false }
        else {
            earlyCancellation = earlyCancellation.filter { Date().timeIntervalSince($0.value) < 30 }
            if earlyCancellation.count < 64 { earlyCancellation[id] = Date() }
        }
    }
    public func check(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw ServiceError("disconnected", "Client disconnected") }
        guard requests[id] == true else { throw ServiceError("cancelled", "Client cancelled this request; completed effects are not rolled back") }
    }
    public func end(_ id: String) { lock.lock(); requests.removeValue(forKey: id); earlyCancellation.removeValue(forKey: id); lock.unlock() }
}

public final class RequestBroker {
    public let registry: AgentRegistry
    private let scheduler: RequestScheduler
    private let mailRoot: URL?
    private let jobs: VoiceJobs?
    private let voiceControl: VoiceControl
    private let cleanupTimer: DispatchSourceTimer
    public init(registry: AgentRegistry, scheduler: RequestScheduler = RequestScheduler(), mailRoot: URL? = nil) {
        self.registry = registry; self.scheduler = scheduler; self.mailRoot = mailRoot
        jobs = try? VoiceJobs(root: registry.root.appendingPathComponent("Jobs"))
        voiceControl = VoiceControl(root: registry.root)
        cleanupTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        cleanupTimer.schedule(deadline: .now(), repeating: 3600)
        let root = registry.root
        cleanupTimer.setEventHandler {
            let agents = root.appendingPathComponent("Agents")
            for folder in (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? [] where UUID(uuidString: folder.lastPathComponent) != nil {
                for app in ["mail", "messages", "voice_memos", "notes"] { AssetStore(root: folder.appendingPathComponent("\(app)/Exports"), application: app).cleanupExpired() }
                AttachmentUpload(root: folder.appendingPathComponent("mail/Uploads"), assets: AssetStore(root: folder.appendingPathComponent("mail/Exports"))).cleanup()
            }
        }
        cleanupTimer.resume()
    }
    deinit { cleanupTimer.cancel() }
    public func request(_ request: HostRequest, session: AgentSession, reply: @escaping (Data) -> Void) {
        do {
            let agent = try registry.authenticate(request.credential)
            try session.bind(request.credential)
            guard ["tools", "call", "resources", "resource", "prompts", "prompt"].contains(request.method) else { throw ServiceError("unknown_method", "Unsupported host method") }
            let name = request.method == "tools" ? "tools/list" : request.method == "call" ? request.tool ?? "system_status" : request.method
            let definition = PersonalService.allDefinitions.first { $0.name == name }
            if request.method == "call" {
                guard let definition else { throw ServiceError("unknown_tool", name) }
                try Self.authorize(agent, definition, request)
            }
            let requestID = request.requestID ?? UUID().uuidString
            let activity = ActivityLog(url: registry.root.appendingPathComponent("activity.jsonl"), agentID: agent.id, connectionID: session.id, requestID: requestID)
            activity.write(name, phase: "queued")
            try session.begin(requestID)
            var automationApp = definition?.usesAutomation == true ? definition?.automationApplication : nil
            if MailModule.tools.contains(where: { $0.name == name }), request.arguments["backend"]?.string != "local" {
                if MailOfficialRead.requested(request.arguments) || (try? MailModule(root: mailRoot).store()) == nil { automationApp = "mail" }
            }
            do { try scheduler.submit(agentID: agent.id, automationApp: automationApp, work: {
                defer { session.end(requestID) }
                let validate = {
                    try session.bind(request.credential)
                    try session.check(requestID)
                    let current = try self.registry.authenticate(request.credential)
                    guard current.permissions == agent.permissions else { throw ServiceError("permissions_changed", "Agent permissions changed; retry discovery or reading") }
                    if let definition { try Self.authorize(current, definition, request) }
                }
                do { try validate() } catch { activity.write(name, phase: "denied_before_execution"); throw error }
                let current = try self.registry.authenticate(request.credential)
                let directory = self.registry.root.appendingPathComponent("Agents/\(agent.id)")
                let mail = MailModule(root: self.mailRoot, assets: AssetStore(root: directory.appendingPathComponent("mail/Exports")))
                let jobAuthorize = {
                    let current = try self.registry.authenticate(request.credential)
                    if let definition { try Self.authorize(current, definition, request) }
                }
                let service = PersonalService(mail: mail, agent: current, operationURL: self.registry.root.appendingPathComponent("state.sqlite"), agentDirectory: directory, activity: activity, validate: validate, jobs: self.jobs, jobAuthorize: jobAuthorize, voiceControl: self.voiceControl)
                return service.handle(request)
            }, reply: reply) }
            catch { session.end(requestID); throw error }
        } catch { reply((try? JSONEncoder().encode(ToolReply.failure(error))) ?? Data()) }
    }
    private static func authorize(_ agent: AgentRecord, _ tool: ToolDefinition, _ request: HostRequest) throws {
        guard !request.readOnly || tool.readOnly else { throw ServiceError("read_only", "This connection only allows reading") }
        guard agent.allows(tool) else { throw ServiceError("permission_denied", "Agent lacks permission for \(tool.name)") }
        if ["assets_read", "operations_get"].contains(tool.name) {
            let app = try Arguments(request.arguments).string("application") ?? "mail"
            let apps = tool.name == "assets_read" ? ["mail", "messages", "voice_memos", "notes"] : ["mail", "messages"]
            guard apps.contains(app), agent.permissions.contains("\(app).read") else { throw ServiceError("permission_denied", "Agent lacks application permission") }
        }
    }
}

public struct ActivityLog {
    private static let lock = NSLock()
    public let url: URL
    public let agentID: String
    public let connectionID: String
    public let requestID: String
    public init(url: URL, agentID: String, connectionID: String = UUID().uuidString, requestID: String = UUID().uuidString) {
        self.url = url; self.agentID = agentID; self.connectionID = connectionID; self.requestID = requestID
    }
    public func write(_ tool: String, phase: String, duration: TimeInterval? = nil) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = JSON.object(["agent_id": .string(agentID), "connection_id": .string(connectionID), "request_id": .string(requestID), "tool": .string(tool), "phase": .string(phase), "time": .string(formatter.string(from: Date())), "version": .string(AppIdentity.version), "duration_ms": duration.map { .number($0 * 1000) } ?? .null])
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: entry.data() + Data([10]))
        } catch { /* Logging failure must not make a completed operation retryable. */ }
    }
}
