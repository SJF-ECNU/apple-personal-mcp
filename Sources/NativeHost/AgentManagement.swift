import AppKit
import PersonalCore

/// Local owner administration. Deliberately absent from the MCP tool catalog.
enum AgentAdministration {
    static func run(_ args: [String]) throws -> JSON {
        let registry = try AgentRegistry()
        let command = args.first ?? ""
        let permissions: () throws -> Set<String> = {
            guard let i = args.firstIndex(of: "--permissions"), i + 1 < args.count else { throw ServiceError("invalid_arguments", "Specify --permissions mail.read,... (empty string grants no applications)") }
            return Set(args[i + 1].split(separator: ",").map(String.init))
        }
        if command == "--agent-list" { return try .encoded(registry.list()) }
        guard args.count >= 2 else { throw ServiceError("invalid_arguments", "Agent name or ID required") }
        switch command {
        case "--agent-create":
            let agent = try registry.create(name: args[1], permissions: permissions())
            return .object(["agent": try .encoded(agent), "credential_file": .string(registry.credentialURL(agent.id).path), "configuration": registry.configuration(agent)])
        case "--agent-update": try registry.update(args[1], permissions: permissions())
        case "--agent-revoke": try registry.revoke(args[1])
        case "--agent-config":
            guard let agent = try registry.list().first(where: { $0.id == args[1] && !$0.revoked }) else { throw ServiceError("not_found", "Active Agent not found") }
            return registry.configuration(agent)
        default: throw ServiceError("invalid_arguments", "Unknown local Agent management command")
        }
        return .object(["updated": .bool(true)])
    }
}

final class AgentManagement: NSObject {
    private let registry: AgentRegistry
    private var agents: [AgentRecord] = []
    private let window: NSWindow
    private let selection = NSPopUpButton()
    private let name = NSTextField()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var permissions: [String: NSButton] = [:]
    init(registry: AgentRegistry) throws {
        self.registry = registry
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Apple Personal MCP · Agent 管理"; window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "一个 App 连接多个 Agent\n每个 Agent 单独授权，配置只引用本机私密凭据文件。撤销后，已有连接和排队请求也会重新检查。"))
        selection.target = self; selection.action = #selector(selected); selection.widthAnchor.constraint(equalToConstant: 660).isActive = true; stack.addArrangedSubview(selection)
        name.placeholderString = "新 Agent 名称"; name.setAccessibilityLabel("Agent 名称"); name.widthAnchor.constraint(equalToConstant: 660).isActive = true; stack.addArrangedSubview(name)
        for (app, label) in zip(AgentRegistry.applications, ["邮件", "日历", "提醒事项", "备忘录", "信息", "语音备忘录"]) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 20
            let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 180).isActive = true; row.addArrangedSubview(title)
            for (suffix, caption) in [("read", "读取"), ("write", "修改")] + (["mail", "messages"].contains(app) ? [("send", "发送（另需本机确认）")] : []) {
                let button = NSButton(checkboxWithTitle: caption, target: nil, action: nil)
                button.setAccessibilityLabel("\(app).\(suffix)"); permissions["\(app).\(suffix)"] = button; row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        for (title, action) in [("创建 Agent", #selector(create)), ("保存权限", #selector(save)), ("复制 MCP 配置", #selector(copyConfiguration)), ("撤销接入", #selector(revoke)), ("刷新", #selector(refresh))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons); stack.addArrangedSubview(summary)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "修改自动包含读取，发送自动包含修改。删除与发送需本机确认，录音控制需配置专用快捷指令。\n本机文件属于当前 macOS 用户；拥有该用户完整终端权限的程序仍可访问文件，这不是进程沙箱。\n读取最多四路并行，官方自动化按应用串行。未下载录音及原始转写会明确报告不可用。"))
        try reload()
    }
    func show() { try? reload(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    private func reload(id: String? = nil) throws {
        let target = id ?? current?.id
        agents = try registry.list(); selection.removeAllItems(); selection.addItem(withTitle: "新建 Agent…")
        for agent in agents { selection.addItem(withTitle: "\(agent.name)\(agent.revoked ? " · 已撤销" : "") · \(agent.id.prefix(8))") }
        selection.selectItem(at: target.flatMap { value in agents.firstIndex { $0.id == value }.map { $0 + 1 } } ?? 0)
        selected()
    }
    private var current: AgentRecord? { let i = selection.indexOfSelectedItem - 1; return agents.indices.contains(i) ? agents[i] : nil }
    private func grants() -> Set<String> {
        var values = Set(permissions.filter { $0.value.state == .on }.keys)
        for app in AgentRegistry.applications {
            if values.contains("\(app).send") { values.insert("\(app).write") }
            if values.contains("\(app).write") { values.insert("\(app).read") }
        }
        return values
    }
    private func perform(_ work: () throws -> Void) {
        do { try work() }
        catch { let a = NSAlert(); a.messageText = "操作未完成"; a.informativeText = String(describing: error); a.runModal() }
    }
    @objc private func selected() {
        let agent = current; name.stringValue = agent?.name ?? ""
        for (permission, button) in permissions { button.state = agent?.permissions.contains(permission) == true ? .on : .off; button.isEnabled = agent?.revoked != true }
        summary.stringValue = agent.map { "Agent ID：\($0.id)\n\($0.revoked ? "已撤销；旧凭据不再有效。" : "保存权限后立即作用于新的请求，无需重启。")" } ?? "输入名称并选择权限。默认不授权任何应用。"
    }
    @objc private func create() { perform { let agent = try registry.create(name: name.stringValue, permissions: grants()); try reload(id: agent.id); summary.stringValue += "\n已创建。点击“复制 MCP 配置”后，粘贴到对应 Agent。" } }
    @objc private func save() { perform { guard let agent = current else { throw ServiceError("select_agent", "请先选择 Agent") }; try registry.update(agent.id, permissions: grants()); try reload(id: agent.id) } }
    @objc private func copyConfiguration() { perform {
        guard let agent = current, !agent.revoked else { throw ServiceError("select_agent", "请选择有效 Agent") }
        let data = try registry.configuration(agent).data()
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: pretty, as: UTF8.self), forType: .string)
        summary.stringValue = "已复制 MCP 配置（只含入口和凭据文件路径，不含密钥）。"
    } }
    @objc private func revoke() { perform {
        guard let agent = current, !agent.revoked else { throw ServiceError("select_agent", "请选择有效 Agent") }
        let alert = NSAlert(); alert.messageText = "撤销 \(agent.name) 的接入？"; alert.informativeText = "旧凭据将失效。已发生的操作不会撤回；录音未知状态需在语音备忘录中人工处理。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "撤销")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        try registry.revoke(agent.id); try reload(id: agent.id)
    } }
    @objc private func refresh() { perform { try reload() } }
}
