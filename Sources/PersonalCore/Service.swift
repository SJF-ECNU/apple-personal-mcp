import Foundation

public final class PersonalService {
    public let mail: MailModule
    private let agent: AgentRecord
    private let operationURL: URL
    private let agentDirectory: URL
    private let activity: ActivityLog
    private let validate: () throws -> Void
    private let jobs: VoiceJobs?
    private let jobAuthorize: () throws -> Void
    private let voiceControl: VoiceControl?
    public init(mail: MailModule, agent: AgentRecord, operationURL: URL, agentDirectory: URL, activity: ActivityLog, validate: @escaping () throws -> Void, jobs: VoiceJobs? = nil, jobAuthorize: @escaping () throws -> Void = {}, voiceControl: VoiceControl? = nil) {
        self.mail = mail; self.agent = agent; self.operationURL = operationURL; self.agentDirectory = agentDirectory; self.activity = activity; self.validate = validate
        self.jobs = jobs; self.jobAuthorize = jobAuthorize
        self.voiceControl = voiceControl
    }
    public static let allDefinitions: [ToolDefinition] = {
        [ToolDefinition("system_status", "Actual app capabilities and permission checks"), ToolDefinition("assets_read", "Read this Agent's exported resource; application requires its own read scope", ["asset_id": ToolDefinition.field("string", "Exported UUID"), "application": ToolDefinition.field("string", "mail (default), messages, voice_memos or notes"), "offset": ToolDefinition.field("integer", "Byte offset"), "length": ToolDefinition.field("integer", "At most 524288 bytes")], required: ["asset_id"])] + MailModule.tools + MailAutomation.tools + EventKitModule.tools + CalendarInvitation.tools + NotesModule.tools + MessagesModule.tools + MessagesAutomation.tools + VoiceMemosModule.tools + VoiceJobs.tools + VoiceControl.tools
    }()
    public func handle(_ request: HostRequest) -> Data {
        let name = request.method == "tools" ? "tools/list" : request.method == "call" ? request.tool ?? "system_status" : request.method
        let started = Date(); activity.write(name, phase: "started")
        let reply: ToolReply
        do {
            try validate()
            if ["resources", "resource", "prompts", "prompt"].contains(request.method) {
                let value = try MCPExtensions(agent: agent, directory: agentDirectory).call(request.method, request.arguments)
                try validate(); activity.write(request.method, phase: "finished", duration: Date().timeIntervalSince(started))
                return try JSONEncoder().encode(ToolReply(value))
            }
            if request.method == "tools" {
                let definitions = Self.allDefinitions.filter { agent.allows($0) && (!request.readOnly || $0.readOnly) }
                let data = try JSONEncoder().encode(definitions)
                try validate(); activity.write(name, phase: "finished", duration: Date().timeIntervalSince(started)); return data
            }
            guard request.method == "call" else { throw ServiceError("unknown_method", request.method) }
            guard let definition = Self.allDefinitions.first(where: { $0.name == name }) else { throw ServiceError("unknown_tool", name) }
            guard !request.readOnly || definition.readOnly else { throw ServiceError("read_only", "This connection only allows reading") }
            guard agent.allows(definition) else { throw ServiceError("permission_denied", "Agent lacks permission for \(name)") }
            let allowed = definition.inputSchema["properties"].object ?? [:]
            guard Set(request.arguments.keys).isSubset(of: Set(allowed.keys)) else { throw ServiceError("invalid_arguments", "Unknown argument") }
            let result: JSON
            if name == "system_status" { result = status() }
            else if name == "operations_get" {
                let a = Arguments(request.arguments); let app = try a.string("application") ?? "mail"
                guard ["mail", "messages"].contains(app), agent.permissions.contains("\(app).read") else { throw ServiceError("permission_denied", "Agent lacks operation application permission") }
                result = try OperationStore(url: operationURL, owner: app == "mail" ? agent.id : agent.id + ":messages").get(a.requiredString("operation_id"))
            }
            else if name == "assets_read" {
                let a = Arguments(request.arguments)
                let app = try a.string("application") ?? "mail"
                guard ["mail", "messages", "voice_memos", "notes"].contains(app), agent.permissions.contains("\(app).read") else { throw ServiceError("permission_denied", "Agent lacks resource application permission") }
                let assets = app == "mail" ? mail.assets : appAssets(app)
                result = try assets.read(id: a.requiredString("asset_id"), offset: a.integer("offset", default: 0, range: 0...Int.max), length: a.integer("length", default: 524288, range: 1...524288))
            } else if MailAutomation.tools.contains(where: { $0.name == name }) {
                result = try MailAutomation(module: mail, operationURL: operationURL, agentName: agent.name, agentID: agent.id, authorize: validate).call(name, request.arguments)
            } else if CalendarInvitation.tools.contains(where: { $0.name == name }) {
                result = try CalendarInvitation(directory: agentDirectory.appendingPathComponent("calendar/Invitations"), mail: mail, agent: agent, operationURL: operationURL, authorize: validate).call(name, request.arguments)
            } else if EventKitModule.tools.contains(where: { $0.name == name }) {
                result = try EventKitModule(agentName: agent.name, authorize: validate).call(name, request.arguments)
            } else if NotesModule.tools.contains(where: { $0.name == name }) {
                result = try NotesModule(agentName: agent.name, authorize: validate, assets: appAssets("notes")).call(name, request.arguments)
            } else if MessagesAutomation.tools.contains(where: { $0.name == name }) {
                result = try MessagesAutomation(operationURL: operationURL, agentID: agent.id, agentName: agent.name, authorize: validate).call(name, request.arguments)
            } else if MessagesModule.tools.contains(where: { $0.name == name }) {
                result = try MessagesModule(assets: appAssets("messages")).call(name, request.arguments)
            } else if VoiceControl.tools.contains(where: { $0.name == name }) {
                guard let voiceControl else { throw ServiceError("state_unavailable", "Voice controls are unavailable") }
                result = try voiceControl.call(name, owner: agent, values: request.arguments, module: { try VoiceMemosModule(assets: self.appAssets("voice_memos")) }, authorize: validate)
            } else if VoiceJobs.tools.contains(where: { $0.name == name }) {
                guard let jobs else { throw ServiceError("state_unavailable", "Background job storage is unavailable") }
                if ["voicememos_transcribe", "voicememos_convert"].contains(name) {
                    let a = Arguments(request.arguments); let id = try a.requiredString("id")
                    let source = try VoiceMemosModule(assets: appAssets("voice_memos")).localAudio(id: id)
                    let locale = name == "voicememos_transcribe" ? try a.requiredString("locale") : ""
                    result = try jobs.start(owner: agent.id, kind: name == "voicememos_transcribe" ? "transcription" : "conversion", recordingID: id, source: source, locale: locale, downloadModels: a.bool("download_models") ?? false, authorize: jobAuthorize)
                } else { result = try jobs.call(name, owner: agent.id, arguments: request.arguments) }
            } else if VoiceMemosModule.tools.contains(where: { $0.name == name }) {
                result = try VoiceMemosModule(assets: appAssets("voice_memos")).call(name, request.arguments)
            } else {
                let backend = try Arguments(request.arguments).string("backend") ?? "auto"
                guard ["auto", "local", "official"].contains(backend) else { throw ServiceError("invalid_arguments", "Unknown Mail backend") }
                let official = MailAutomation(module: mail, operationURL: operationURL, agentName: agent.name, agentID: agent.id, authorize: validate)
                if backend == "local", MailOfficialRead.requested(request.arguments) { throw ServiceError("invalid_arguments", "An official Mail reference cannot be used with backend=local") }
                if MailOfficialRead.requested(request.arguments) { result = try official.officialRead(name, request.arguments) }
                else {
                    do { result = try mail.call(name, request.arguments) }
                    catch let error as ServiceError where backend == "auto" && ["unsupported_schema", "needs_permission"].contains(error.code) {
                        result = try official.officialRead(name, request.arguments)
                    }
                }
            }
            if definition.readOnly { try validate() }
            reply = ToolReply(result)
        } catch { reply = .failure(error) }
        activity.write(name, phase: reply.isError ? "failed" : "finished", duration: Date().timeIntervalSince(started))
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }
    private func status() -> JSON {
        let state: JSON
        do {
            guard agent.permissions.contains("mail.read") else { throw ServiceError("permission_denied", "Mail is not authorized for this Agent") }
            let store = try mail.store(); state = .object(["state": .string("ready"), "messages": .int(try store.messageCount()), "backend": .string("local_readonly")])
        }
        catch { state = .object(["state": .string((error as? ServiceError)?.code ?? "unavailable"), "detail": .string(String(describing: error))]) }
        var apps = ["mail": state]
        for name in ["calendar", "reminders"] {
            apps[name] = agent.permissions.contains("\(name).read") ? EventKitModule.status(name) : .object(["state": .string("permission_denied")])
        }
        apps["notes"] = agent.permissions.contains("notes.read") ? NotesModule.status() : .object(["state": .string("permission_denied")])
        if agent.permissions.contains("messages.read") {
            do {
                var info = try MessagesModule(assets: appAssets("messages")).status().object ?? [:]
                info["official_send_implemented"] = .bool(true); info["automation_status"] = .int(Int(MessagesAutomation.permissionStatus()))
                apps["messages"] = .object(info)
            }
            catch { apps["messages"] = .object(["state": .string((error as? ServiceError)?.code ?? "unavailable")]) }
        } else { apps["messages"] = .object(["state": .string("permission_denied")]) }
        if agent.permissions.contains("voice_memos.read") {
            do {
                var info = try VoiceMemosModule(assets: appAssets("voice_memos")).status().object ?? [:]
                info["generated_transcription_jobs"] = .bool(jobs != nil); info["media_controls_implemented"] = .bool(voiceControl != nil)
                apps["voice_memos"] = .object(info)
            }
            catch { apps["voice_memos"] = .object(["state": .string((error as? ServiceError)?.code ?? "unavailable")]) }
        } else { apps["voice_memos"] = .object(["state": .string("permission_denied")]) }
        return .object(["version": .string(AppIdentity.version), "host_path": .string(Bundle.main.bundlePath), "agent": .object(["id": .string(agent.id), "name": .string(agent.name), "permissions": .array(agent.permissions.sorted().map(JSON.string))]), "applications": .object(apps), "automation": agent.permissions.contains("mail.read") ? .int(Int(MailAutomation.permissionStatus())) : .null, "coverage": .string("current_mac_local_data")])
    }
    private func appAssets(_ app: String) -> AssetStore {
        AssetStore(root: agentDirectory.appendingPathComponent("\(app)/Exports"), application: app)
    }
}
