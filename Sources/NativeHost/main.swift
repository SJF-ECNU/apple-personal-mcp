import AppKit
import Foundation
import EventKit
import PersonalCore
import ServiceManagement

final class HostEndpoint: NSObject, HostProtocol {
    let broker: RequestBroker
    let session = AgentSession()
    init(broker: RequestBroker) { self.broker = broker }
    func cancel(_ requestID: String) { session.cancel(requestID) }
    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        do {
            guard data.count <= 1048576 else { throw ServiceError("request_too_large", "Request exceeds 1 MiB") }
            let request = try JSONDecoder().decode(HostRequest.self, from: data)
            broker.request(request, session: session, reply: reply)
        } catch { reply((try? JSONEncoder().encode(ToolReply.failure(error))) ?? Data()) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSXPCListenerDelegate {
    private var listener: NSXPCListener?
    private var ownerListener: NSXPCListener?
    private let ownerEndpoint = OwnerEndpoint()
    private var broker: RequestBroker?
    private var agentManagement: AgentManagement?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        ownerEndpoint.openManagement = { [weak self] in self?.showAgents() }
        if let index = args.firstIndex(of: "--configure-recording-shortcuts"), args.count == index + 3 {
            do { try VoiceControl.configure(root: AppIdentity.support, start: args[index + 1], stop: args[index + 2]); FileHandle.standardOutput.write(Data("{\"configured\":true}\n".utf8)); exit(0) }
            catch { FileHandle.standardError.write(Data("Recording setup failed: \(error)\n".utf8)); exit(1) }
        }
        if args.contains("--request-messages-permission") {
            Task {
                do { let data = try await OwnerClient().requestMessagesPermission(); FileHandle.standardOutput.write(data + Data([10])); exit(0) }
                catch { FileHandle.standardError.write(Data("Messages authorization unavailable: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        if args.contains("--request-notes-permission") {
            Task {
                do { let data = try await OwnerClient().requestNotesPermission(); FileHandle.standardOutput.write(data + Data([10])); exit(0) }
                catch { FileHandle.standardError.write(Data("Notes authorization unavailable: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        if args.contains("--inspect-local-sources") {
            Task {
                do { let data = try await OwnerClient().inspectLocalSources(); FileHandle.standardOutput.write(data + Data([10])); exit(0) }
                catch { FileHandle.standardError.write(Data("Source inspection unavailable: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        if args.contains("--request-eventkit-permissions") { requestEventKit(quitWhenDone: true); return }
        if args.dropFirst().first?.hasPrefix("--agent-") == true {
            do {
                let result = try AgentAdministration.run(Array(args.dropFirst()))
                FileHandle.standardOutput.write(try result.data() + Data([10]))
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Agent management: \(error)\n".utf8)); exit(1)
            }
            return
        }
        if args.contains("--unregister") { try? SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist").unregister(); NSApp.terminate(nil); return }
        if args.contains("--register") {
            do {
                let agent = SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist")
                if agent.status == .enabled { try agent.unregister() }
                try agent.register()
                FileHandle.standardOutput.write(Data("User service status: \(agent.status.rawValue)\n".utf8))
            } catch { FileHandle.standardError.write(Data("Service registration: \(error)\n".utf8)) }
            NSApp.terminate(nil); return
        }
        if args.contains("--service") {
            let fixture = ProcessInfo.processInfo.environment["APPLE_PERSONAL_MCP_MAIL_ROOT"].map { URL(fileURLWithPath: $0) }
            do { broker = RequestBroker(registry: try AgentRegistry(), mailRoot: fixture) }
            catch { FileHandle.standardError.write(Data("Agent registry unavailable: \(error)\n".utf8)); exit(1) }
            listener = NSXPCListener(machServiceName: AppIdentity.service); listener?.delegate = self; listener?.resume()
            ownerListener = NSXPCListener(machServiceName: AppIdentity.ownerService); ownerListener?.delegate = self; ownerListener?.resume()
        }
        if !args.contains("--service") {
            if SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist").status == .enabled {
                Task {
                    do { _ = try await OwnerClient().showAgentManagement(); await MainActor.run { NSApp.terminate(nil) } }
                    catch { await MainActor.run { self.alert("后台服务不可用", "请在系统登录项中启用 ApplePersonalMCP，或重新注册用户服务。") } }
                }
            } else { showSettings() }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "APM"
        let menu = NSMenu()
        menu.addItem(withTitle: "Agent 管理…", action: #selector(showAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "状态与权限…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let owner = listener === ownerListener
        guard connection.effectiveUserIdentifier == getuid(), let broker, let requirement = try? AppIdentity.peerRequirement(identifier: owner ? AppIdentity.host : AppIdentity.bridge) else { return false }
        connection.setCodeSigningRequirement(requirement)
        if owner {
            connection.exportedInterface = NSXPCInterface(with: OwnerProtocol.self); connection.exportedObject = ownerEndpoint
            connection.resume(); return true
        }
        connection.exportedInterface = NSXPCInterface(with: HostProtocol.self)
        let endpoint = HostEndpoint(broker: broker)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak endpoint] in endpoint?.session.invalidate() }
        connection.interruptionHandler = { [weak endpoint] in endpoint?.session.invalidate() }
        connection.resume(); return true
    }
    @objc func showAgents() {
        do {
            if agentManagement == nil { agentManagement = try AgentManagement(registry: AgentRegistry()) }
            agentManagement?.show()
        } catch { alert("Agent 管理不可用", error.localizedDescription) }
    }
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Apple Personal MCP · 本机开发版"; w.center(); w.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 24)])
        let text = NSTextField(wrappingLabelWithString: "统一 App · 六应用 · 多 Agent\n每个 Agent 使用独立凭据与应用权限；读取并行，修改按应用排队。\n邮件、日历、提醒事项与备忘录支持读写；信息发送需单独授权并确认。\n语音支持原始转写、本地生成转写任务、转换和播放。录音控制需专用公开快捷指令，开始/停止都需本机确认。")
        stack.addArrangedSubview(text)
        for (label, action) in [("Agent 管理", #selector(showAgents)), ("启用 / 重启用户服务", #selector(registerService)), ("打开完全磁盘访问设置", #selector(openPrivacy)), ("请求 Mail 自动化授权", #selector(requestAutomation)), ("授权日历与提醒事项", #selector(requestEventKitFromUI)), ("授权备忘录", #selector(requestNotesFromUI)), ("授权信息自动化", #selector(requestMessagesFromUI)), ("配置录音快捷指令…", #selector(configureRecording))] {
            let button = NSButton(title: label, target: self, action: action); stack.addArrangedSubview(button)
        }
        w.makeKeyAndOrderFront(nil); window = w
    }
    @objc func registerService() {
        do {
            let agent = SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist")
            if agent.status == .enabled { try agent.unregister() }
            try agent.register()
            alert("用户服务已注册", "现在可运行命令行 doctor 检查实际权限。")
        } catch { alert("注册失败", error.localizedDescription) }
    }
    @objc func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    @objc func requestAutomation() {
        DispatchQueue.global().async { let value = MailAutomation.permissionStatus(ask: true); DispatchQueue.main.async { self.alert("Mail 自动化", "系统状态码：\(value)") } }
    }
    @objc func requestEventKitFromUI() { requestEventKit(quitWhenDone: false) }
    @objc func requestNotesFromUI() {
        Task {
            do {
                let data = try await OwnerClient().requestNotesPermission()
                DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "备忘录授权状态"; alert.informativeText = String(decoding: data, as: UTF8.self); alert.runModal() }
            } catch { DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "备忘录授权失败"; alert.informativeText = String(describing: error); alert.runModal() } }
        }
    }
    @objc func requestMessagesFromUI() {
        Task {
            do { let data = try await OwnerClient().requestMessagesPermission(); await MainActor.run { self.alert("信息授权状态", String(decoding: data, as: UTF8.self)) } }
            catch { await MainActor.run { self.alert("信息授权失败", String(describing: error)) } }
        }
    }
    @objc func configureRecording() {
        let alert = NSAlert(); alert.messageText = "配置专用录音快捷指令"
        alert.informativeText = "在快捷指令中分别创建：获取快捷指令输入文本→创建录音（名称=文本）；停止录音。这里只接受这两个专用快捷指令的 UUID，不接受命令或任意脚本。"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        let start = NSTextField(); start.placeholderString = "开始录音快捷指令 UUID"
        let stop = NSTextField(); stop.placeholderString = "停止录音快捷指令 UUID"
        let config = (try? Data(contentsOf: AppIdentity.support.appendingPathComponent("recording-shortcuts.json"))).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
        start.stringValue = config?["start"].string ?? ""; stop.stringValue = config?["stop"].string ?? ""
        for field in [start, stop] { field.widthAnchor.constraint(equalToConstant: 410).isActive = true; stack.addArrangedSubview(field) }
        stack.frame = NSRect(x: 0, y: 0, width: 410, height: 56); alert.accessoryView = stack
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "保存")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try VoiceControl.configure(root: AppIdentity.support, start: start.stringValue, stop: stop.stringValue) }
        catch { self.alert("配置失败", String(describing: error)) }
    }
    private func requestEventKit(quitWhenDone: Bool) {
        Task {
            do {
                let data = try await OwnerClient().requestEventKitPermissions()
                DispatchQueue.main.async {
                    if quitWhenDone { FileHandle.standardOutput.write(data + Data([10])); NSApp.terminate(nil) }
                    else { let alert = NSAlert(); alert.messageText = "日历与提醒事项授权状态"; alert.informativeText = String(decoding: data, as: UTF8.self); alert.runModal() }
                }
            } catch {
                DispatchQueue.main.async {
                    if quitWhenDone { FileHandle.standardError.write(Data("Permission request failed: \(error)\n".utf8)); exit(1) }
                    else { let alert = NSAlert(); alert.messageText = "授权请求失败"; alert.informativeText = String(describing: error); alert.runModal() }
                }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showAgents(); return true }
    private func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal() }
    @objc func quit() { NSApp.terminate(nil) }
}

final class OwnerEndpoint: NSObject, OwnerProtocol {
    var openManagement: (() -> Void)? // Main queue only.
    private var requesting = false // Main queue only.
    func showAgentManagement(_ reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async { self.openManagement?(); reply(Data("{\"shown\":true}".utf8)) }
    }
    func inspectLocalSources(_ reply: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply((try? SourceInspection.run().data()) ?? Data()) }
    }
    func requestNotesPermission(_ reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async {
            do {
                try NotesModule.ensureRunning()
                let code = NotesModule.permissionStatus(ask: true)
                reply((try? JSON.object(["status": .int(Int(code)), "notes": NotesModule.status()]).data()) ?? Data())
            } catch { reply((try? JSONEncoder().encode(ToolReply.failure(error))) ?? Data()) }
        }
    }
    func requestMessagesPermission(_ reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async {
            do {
                try MessagesAutomation.ensureRunning()
                reply((try? JSON.object(["status": .int(Int(MessagesAutomation.permissionStatus(ask: true)))]).data()) ?? Data())
            } catch { reply((try? JSONEncoder().encode(ToolReply.failure(error))) ?? Data()) }
        }
    }
    func requestEventKitPermissions(_ reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            guard !self.requesting else { reply((try? JSONEncoder().encode(ToolReply.failure(ServiceError("permission_request_pending", "A system authorization request is already pending")))) ?? Data()); return }
            self.requesting = true
            let store = EKEventStore()
            store.requestFullAccessToEvents { calendarGranted, calendarError in
                DispatchQueue.main.async {
                    store.requestFullAccessToReminders { remindersGranted, remindersError in
                        DispatchQueue.main.async {
                            self.requesting = false
                            store.reset()
                            let result = JSON.object(["calendar": EventKitModule.status("calendar"), "reminders": EventKitModule.status("reminders"), "calendar_granted": .bool(calendarGranted), "reminders_granted": .bool(remindersGranted), "calendar_error": calendarError.map { .string(String(describing: $0)) } ?? .null, "reminders_error": remindersError.map { .string(String(describing: $0)) } ?? .null])
                            reply((try? result.data()) ?? Data())
                        }
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
