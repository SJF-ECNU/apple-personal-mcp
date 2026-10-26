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
    private var dashboard: DashboardWindow?
    private var statusItem: NSStatusItem?
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        ownerEndpoint.openManagement = { [weak self] in self?.showDashboard() }
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
        configureMainMenu()
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
        menu.addItem(withTitle: "打开 Apple Personal MCP…", action: #selector(showOverview), keyEquivalent: "").target = self
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
    @MainActor @objc func showOverview() { showDashboard(.overview) }
    @MainActor @objc func showAgents() { showDashboard(.agents) }
    @MainActor @objc func showSettings() { showDashboard(.applications) }
    @MainActor private func configureMainMenu() {
        let menu = NSMenu()
        let app = NSMenu(); app.addItem(withTitle: "退出 Apple Personal MCP", action: #selector(quit), keyEquivalent: "q").target = self
        let edit = NSMenu()
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let window = NSMenu()
        window.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "刷新状态", action: #selector(refreshDashboard), keyEquivalent: "r").target = self
        for (title, submenu) in [("Apple Personal MCP", app), ("编辑", edit), ("窗口", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item)
        }
        NSApp.mainMenu = menu
    }
    @MainActor @objc private func refreshDashboard() { dashboard?.refresh() }
    @MainActor private func showDashboard(_ page: DashboardPage? = nil) {
        do {
            if dashboard == nil {
                dashboard = try DashboardWindow(registry: AgentRegistry(), serviceRunning: { [weak self] in self?.broker != nil }, action: { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case "privacy": self.openPrivacy()
                    case "mail": self.requestAutomation()
                    case "eventkit": self.requestEventKitFromUI()
                    case "notes": self.requestNotesFromUI()
                    case "messages": self.requestMessagesFromUI()
                    case "recording": self.configureRecording()
                    case "service": self.registerService()
                    default: break
                    }
                })
            }
            dashboard?.show(page)
        } catch { alert("管理界面不可用", error.localizedDescription) }
    }
    @MainActor @objc func registerService() {
        do {
            let agent = SMAppService.agent(plistName: "com.shjf.apple-personal-mcp.service.plist")
            if agent.status == .enabled { try agent.unregister() }
            try agent.register()
            alert("用户服务已注册", "现在可运行命令行 doctor 检查实际权限。")
        } catch { alert("注册失败", error.localizedDescription) }
    }
    @MainActor @objc func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    @MainActor @objc func requestAutomation() {
        Task {
            let value = await Task.detached { MailAutomation.permissionStatus(ask: true) }.value
            alert("Mail 自动化", value == 0 ? "已允许控制 Mail。发送仍需本机确认。" : "系统尚未允许控制 Mail，请检查隐私与安全性中的自动化设置，再刷新状态。")
        }
    }
    @MainActor @objc func requestEventKitFromUI() { requestEventKit(quitWhenDone: false) }
    @MainActor @objc func requestNotesFromUI() {
        Task {
            do {
                let data = try await OwnerClient().requestNotesPermission()
                DispatchQueue.main.async { self.showAutomationResult(data, application: "备忘录") }
            } catch { DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "备忘录授权失败"; alert.informativeText = String(describing: error); alert.runModal() } }
        }
    }
    @MainActor @objc func requestMessagesFromUI() {
        Task {
            do { let data = try await OwnerClient().requestMessagesPermission(); await MainActor.run { self.showAutomationResult(data, application: "信息") } }
            catch { await MainActor.run { self.alert("信息授权失败", String(describing: error)) } }
        }
    }
    @MainActor @objc func configureRecording() {
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
    @MainActor private func requestEventKit(quitWhenDone: Bool) {
        Task {
            do {
                let data = try await OwnerClient().requestEventKitPermissions()
                DispatchQueue.main.async {
                    if quitWhenDone { FileHandle.standardOutput.write(data + Data([10])); NSApp.terminate(nil) }
                    else {
                        let result = try? JSONDecoder().decode(JSON.self, from: data)
                        let calendar = result?["calendar_granted"].boolean == true ? "已允许" : "未允许"
                        let reminders = result?["reminders_granted"].boolean == true ? "已允许" : "未允许"
                        self.alert("日历与提醒事项", "日历：\(calendar)\n提醒事项：\(reminders)\n可在系统设置中调整，完成后刷新。")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if quitWhenDone { FileHandle.standardError.write(Data("Permission request failed: \(error)\n".utf8)); exit(1) }
                    else { let alert = NSAlert(); alert.messageText = "授权请求失败"; alert.informativeText = String(describing: error); alert.runModal() }
                }
            }
        }
    }
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    @MainActor private func showAutomationResult(_ data: Data, application: String) {
        let result = try? JSONDecoder().decode(JSON.self, from: data)
        alert("\(application)自动化", result?["status"].int == 0 ? "系统已允许控制\(application)。" : "系统尚未允许访问，请检查隐私与安全性中的自动化设置，再刷新状态。")
    }
    @MainActor private func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal(); dashboard?.refresh() }
    @MainActor @objc func quit() { NSApp.terminate(nil) }
}

final class OwnerEndpoint: NSObject, OwnerProtocol {
    var openManagement: (@MainActor () -> Void)? // Main queue only.
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
