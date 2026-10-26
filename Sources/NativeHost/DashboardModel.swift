import AppKit
import Combine
import PersonalCore
import ServiceManagement

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "概览", agents = "Agent", applications = "应用", activity = "活动"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .agents: return "person.2"
        case .applications: return "app.connected.to.app.below.fill"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct ConnectedApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let capability: String
    let icon: NSImage?
    init(_ id: String, _ name: String, _ bundleID: String, _ capability: String) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.capability = capability
        icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    static let all = [
        ConnectedApp("mail", "邮件", "com.apple.mail", "本机邮件与附件 · 草稿与确认发送"),
        ConnectedApp("calendar", "日历", "com.apple.iCal", "日程读写 · 重复事件 · 邀请草稿"),
        ConnectedApp("reminders", "提醒事项", "com.apple.reminders", "清单与提醒 · 到期日期 · 完成状态"),
        ConnectedApp("notes", "备忘录", "com.apple.Notes", "笔记与附件 · 普通正文编辑"),
        ConnectedApp("messages", "信息", "com.apple.MobileSMS", "本机聊天历史 · 确认发送信息"),
        ConnectedApp("voice_memos", "语音备忘录", "com.apple.VoiceMemos", "已有录音与转写 · 本地语音任务")
    ]
}

struct AppAccess {
    let title: String
    let detail: String
    let ready: Bool
}

struct RecentActivity: Identifiable {
    let id: String
    let agentID: String
    let tool: String
    let phase: String
    let time: Date
    let duration: Int?
    var label: String {
        switch phase {
        case "finished": return "已完成"
        case "failed": return "未完成"
        case "queued": return "已排队"
        case "started": return "已开始"
        case "denied_before_execution": return "已拒绝"
        default: return phase
        }
    }
}

@MainActor final class DashboardModel: ObservableObject {
    @Published var page: DashboardPage = .overview
    @Published private(set) var agents: [AgentRecord] = []
    @Published private(set) var selectedID: String?
    @Published var name = ""
    @Published private(set) var permissions: Set<String> = []
    @Published private(set) var access: [String: AppAccess] = [:]
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    @Published private(set) var activity: [RecentActivity] = []
    @Published var notice: String?
    @Published var failure: String?
    private let registry: AgentRegistry
    let serviceRunning: () -> Bool
    let action: (String) -> Void
    private var originalPermissions: Set<String> = []
    private var originalName = ""
    var current: AgentRecord? { agents.first { $0.id == selectedID } }
    var dirty: Bool { permissions != originalPermissions || name != originalName }
    var activeAgents: Int { agents.filter { !$0.revoked }.count }
    var serviceLabel: String {
        if serviceRunning() { return "后台服务运行中" }
        return SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist").status == .enabled ? "服务已注册" : "后台服务未启用"
    }
    init(registry: AgentRegistry, serviceRunning: @escaping () -> Bool, action: @escaping (String) -> Void) throws {
        self.registry = registry; self.serviceRunning = serviceRunning; self.action = action
        agents = try registry.list()
    }
    func refresh() {
        perform { agents = try registry.list(); if !dirty { loadSelection(selectedID) } }
        refreshActivity()
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.inspectAccess()
            DispatchQueue.main.async { self.access = result; self.checkedAt = Date(); self.checking = false }
        }
    }
    func select(_ id: String?) {
        guard id != selectedID else { return }
        guard canDiscard() else { return }
        loadSelection(id)
    }
    func newAgent() { if canDiscard() { loadSelection(nil); page = .agents } }
    func discardEdits() { loadSelection(selectedID) }
    private func loadSelection(_ id: String?) {
        selectedID = id; name = current?.name ?? ""; permissions = current?.permissions ?? []
        originalName = name; originalPermissions = permissions; notice = nil
    }
    func canDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的修改？"
        alert.informativeText = "已保存的 Agent 权限不会改变。"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func setPermission(_ app: String, _ level: String, _ enabled: Bool) {
        let key = "\(app).\(level)"
        if enabled {
            permissions.insert(key)
            if level == "send" { permissions.insert("\(app).write") }
            if level != "read" { permissions.insert("\(app).read") }
        } else {
            permissions.remove(key)
            if level == "read" { permissions.remove("\(app).write") }
            if level != "send" { permissions.remove("\(app).send") }
        }
    }
    func save() {
        perform {
            let id: String
            if let agent = current {
                try registry.update(agent.id, permissions: permissions); id = agent.id
            } else { id = try registry.create(name: name, permissions: permissions).id }
            agents = try registry.list(); loadSelection(id)
            notice = "已保存。新请求将使用当前权限。"
        }
    }
    func copyConfiguration() {
        perform {
            guard let agent = current, !agent.revoked else { throw ServiceError("select_agent", "请选择有效 Agent") }
            let object = try JSONSerialization.jsonObject(with: registry.configuration(agent).data())
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            notice = "MCP 配置已复制，仅含入口和凭据文件路径。"
        }
    }
    func revoke() {
        guard let agent = current, !agent.revoked else { return }
        let alert = NSAlert(); alert.messageText = "撤销 \(agent.name) 的接入？"
        alert.informativeText = "旧凭据将失效。已发生的操作不会撤回；录音未知状态需在语音备忘录中人工处理。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "撤销")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { try registry.revoke(agent.id); agents = try registry.list(); loadSelection(agent.id); notice = "已撤销接入，旧凭据不再有效。" }
    }
    private func perform(_ work: () throws -> Void) { do { try work() } catch { failure = String(describing: error) } }
    func refreshActivity() {
        let url = registry.root.appendingPathComponent("activity.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { activity = []; return }
        perform {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let end = try file.seekToEnd(); let start = end > 262144 ? end - 262144 : 0
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: 262144) ?? Data()
            var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty { lines.removeLast() } // A trailing partial record is not complete.
            let tools = Set(PersonalService.allDefinitions.map(\.name) + ["tools/list", "resources", "resource", "prompts", "prompt"])
            let phases: Set<String> = ["queued", "started", "finished", "failed", "denied_before_execution"]
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var requests: [String: RecentActivity] = [:]
            for line in lines {
                guard let value = try? JSONDecoder().decode(JSON.self, from: Data(line)),
                      let id = value["request_id"].string, let agent = value["agent_id"].string,
                      let tool = value["tool"].string, tools.contains(tool),
                      let phase = value["phase"].string, phases.contains(phase),
                      let time = value["time"].string.flatMap(formatter.date(from:)) else { continue }
                let duration: Int?
                if case .number(let ms) = value["duration_ms"], ms.isFinite, (0...86400000).contains(ms) { duration = Int(ms.rounded()) } else { duration = nil }
                requests[id] = RecentActivity(id: id, agentID: agent, tool: tool, phase: phase, time: time, duration: duration)
            }
            activity = Array(requests.values.sorted { $0.time > $1.time }.prefix(80))
        }
    }
    nonisolated private static func inspectAccess() -> [String: AppAccess] {
        func check(_ title: String, _ body: () throws -> Void) -> AppAccess {
            do { try body(); return AppAccess(title: "本地数据可读取", detail: title, ready: true) }
            catch {
                let code = (error as? ServiceError)?.code ?? "unavailable"
                return AppAccess(title: code == "needs_permission" ? "需要系统访问权限" : "暂不可用", detail: code == "source_unavailable" ? "请打开系统应用完成本机同步后刷新。" : "请检查完全磁盘访问与本机数据，再刷新状态。", ready: false)
            }
        }
        var result: [String: AppAccess] = [:]
        let mailAutomation = MailAutomation.permissionStatus() == 0 ? "已允许" : "未允许"
        result["mail"] = check("本地邮件索引 · Mail 自动化：\(mailAutomation)") { _ = try MailModule().store().messageCount() }
        for app in ["calendar", "reminders"] {
            let ready = EventKitModule.status(app)["state"].string == "ready"
            result[app] = AppAccess(title: ready ? "系统授权可用" : "需要系统授权", detail: "EventKit · 日历与提醒分别授权", ready: ready)
        }
        let notes = NotesModule.status()["state"].string == "ready"
        result["notes"] = AppAccess(title: notes ? "自动化授权可用" : "需要自动化授权", detail: "Notes 官方接口 · 尚未在此检查中读取正文", ready: notes)
        let messagesAutomation = MessagesAutomation.permissionStatus() == 0 ? "已允许" : "未允许"
        result["messages"] = check("本机聊天索引 · 信息自动化：\(messagesAutomation)") { _ = try MessagesModule(assets: AssetStore()).status() }
        result["voice_memos"] = check("本地录音库 · 音频下载和转写按录音检查") { _ = try VoiceMemosModule(assets: AssetStore()).status() }
        return result
    }
}
