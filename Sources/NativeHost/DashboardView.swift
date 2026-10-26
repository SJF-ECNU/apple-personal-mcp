import SwiftUI
import PersonalCore

private enum Ink {
    static let background = Color(red: 20/255, green: 20/255, blue: 22/255)
    static let sidebar = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let panel = Color(red: 35/255, green: 35/255, blue: 38/255)
    static let selection = Color(red: 48/255, green: 48/255, blue: 52/255)
    static let text = Color(red: 245/255, green: 245/255, blue: 247/255)
    static let secondary = Color(red: 161/255, green: 161/255, blue: 166/255)
    static let line = Color.white.opacity(0.08)
}

private struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(Color.black.opacity(enabled ? 0.9 : 0.4))
            .background(Ink.text.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AppIcon: View {
    let app: ConnectedApp
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let icon = app.icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app").resizable().scaledToFit().padding(6).foregroundStyle(Ink.secondary) }
        }.frame(width: size, height: size).accessibilityLabel(app.name)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var showRevoked = false
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Ink.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Ink.line).frame(height: 1)
                Group {
                    switch model.page {
                    case .overview: overview
                    case .agents: agents
                    case .applications: applications
                    case .activity: activity
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.background).foregroundStyle(Ink.text).tint(Ink.text).preferredColorScheme(.dark)
        .alert("操作未完成", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("好") { model.failure = nil }
        } message: { Text(model.failure ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 24)).foregroundStyle(Ink.text)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Personal").font(.system(size: 13, weight: .semibold))
                    Text("MCP FOR MAC").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(Ink.secondary)
                }
            }.padding(.bottom, 32)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.secondary).padding(.leading, 12).padding(.bottom, 10)
            ForEach(DashboardPage.allCases) { page in
                Button { model.page = page; if page == .activity { model.refreshActivity() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 14)).frame(width: 18)
                        Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
                        .background(model.page == page ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.bottom, 5).accessibilityIdentifier("navigation.\(page.id)")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("本机连接 · 独立授权", systemImage: "lock.shield").font(.system(size: 11))
                Text("Apple Personal MCP  \(AppIdentity.version)").font(.system(size: 10)).foregroundStyle(Ink.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 20)
        }.padding(.horizontal, 16).padding(.top, 50).frame(width: 190).frame(maxHeight: .infinity).background(Ink.sidebar)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.page.rawValue).font(.system(size: 25, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            Spacer()
            if model.checking { ProgressView().controlSize(.small).accessibilityLabel("正在检查状态") }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("刷新状态与最近活动").disabled(model.checking).accessibilityLabel("刷新状态")
        }.padding(.horizontal, 30).padding(.top, 36).padding(.bottom, 22)
    }
    private var subtitle: String {
        switch model.page {
        case .overview: return "你的 Mac 应用，与 Agent 安全相连。"
        case .agents: return "为每个 Agent 分配独立的应用权限。"
        case .applications: return "查看系统访问状态，配置各应用的连接。"
        case .activity: return "查看最近请求的执行状态，不记录私人正文。"
        }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 14) {
                    metric("后台服务", model.serviceLabel, "本机用户会话", "bolt.horizontal")
                    metric("已授权 Agent", "\(model.activeAgents)", "每个 Agent 使用独立凭据", "person.2")
                    metric("应用检查", model.checkedAt == nil ? "尚未检查" : "\(model.access.values.filter(\.ready).count) / 6 可用", checkedTime, "app.badge.checkmark")
                }
                sectionTitle("你的应用", action: "查看全部") { model.page = .applications }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ConnectedApp.all) { app in
                        Button { model.page = .applications } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                AppIcon(app: app, size: 44)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(app.name).font(.system(size: 14, weight: .semibold))
                                    status(app.id)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                sectionTitle("开始连接", action: "添加 Agent") { model.newAgent() }
                HStack(alignment: .top, spacing: 18) {
                    step("1", "检查系统授权", "在「应用」中完成所需授权。")
                    step("2", "创建独立 Agent", "仅勾选它需要的应用权限。")
                    step("3", "复制 MCP 配置", "粘贴到客户端，建立本机连接。")
                }.padding(20).background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
                Text("系统访问状态与 Agent 权限分别生效。发送、删除和录音控制保留本机确认。")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }.padding(30)
        }
    }
    private func metric(_ label: String, _ value: String, _ detail: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(label); Spacer(); Image(systemName: symbol) }.font(.system(size: 11)).foregroundStyle(Ink.secondary)
            Text(value).font(.system(size: 19, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size: 10)).foregroundStyle(Ink.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Ink.secondary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Ink.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var agents: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("\(model.activeAgents) 个有效 Agent").font(.system(size: 11)).foregroundStyle(Ink.secondary); Spacer(); Button { model.newAgent() } label: { Image(systemName: "plus") }.help("新建 Agent").accessibilityLabel("新建 Agent") }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.agents.filter { showRevoked || !$0.revoked }, id: \.id) { agent in
                            Button { model.select(agent.id) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Image(systemName: agent.revoked ? "person.crop.circle.badge.xmark" : "person.crop.circle"); Text(agent.name).lineLimit(1) }.font(.system(size: 12, weight: .medium))
                                    Text(agent.revoked ? "已撤销" : "\(agent.permissions.count) 项权限").font(.system(size: 10)).foregroundStyle(Ink.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(model.selectedID == agent.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Toggle("显示已撤销", isOn: $showRevoked).toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(Ink.secondary)
                Button("新建 Agent") { model.newAgent() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }.padding(20).frame(width: 210)
            Rectangle().fill(Ink.line).frame(width: 1)
            ScrollView { agentEditor.padding(26) }
        }
    }
    private var agentEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.current?.name ?? "新建 Agent").font(.system(size: 20, weight: .semibold))
                Text(model.current == nil ? "默认不授予任何应用权限。" : model.current!.revoked ? "接入已撤销，旧凭据不再有效。" : "权限保存后立即作用于新请求。")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            if model.current == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("名称").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    TextField("例如：Claude Code", text: $model.name).textFieldStyle(.roundedBorder).accessibilityLabel("Agent 名称")
                }
            }
            VStack(spacing: 0) {
                HStack { Text("应用权限"); Spacer(); Text("读取").frame(width: 42); Text("修改").frame(width: 42); Text("发送").frame(width: 42) }
                    .font(.system(size: 10)).foregroundStyle(Ink.secondary).padding(.horizontal, 14).padding(.vertical, 14)
                ForEach(ConnectedApp.all) { app in
                    Rectangle().fill(Ink.line).frame(height: 1)
                    HStack(spacing: 8) {
                        AppIcon(app: app, size: 28)
                        Text(app.name).font(.system(size: 12))
                        Spacer(minLength: 0)
                        permission(app.id, "read", "读取")
                        permission(app.id, "write", "修改")
                        if ["mail", "messages"].contains(app.id) { permission(app.id, "send", "发送") }
                        else { Text("—").font(.system(size: 11)).foregroundStyle(Ink.secondary).frame(width: 42) }
                    }.padding(.horizontal, 14).padding(.vertical, 11)
                }
            }.background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
            Text("修改包含读取，发送包含修改。发送权限仍需本机确认；语音修改权限用于任务与控制，不授予录音库删除能力。")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(model.current == nil ? "创建 Agent" : "保存权限") { model.save() }.buttonStyle(PrimaryButton())
                    .disabled(model.current?.revoked == true || !model.dirty || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("复制 MCP 配置") { model.copyConfiguration() }.buttonStyle(.bordered).disabled(model.current == nil || model.current?.revoked == true || model.dirty)
            }
            if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let agent = model.current {
                Rectangle().fill(Ink.line).frame(height: 1)
                Text("AGENT ID").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Ink.secondary)
                Text(agent.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.secondary).textSelection(.enabled)
                if !agent.revoked { Button("撤销接入", role: .destructive) { model.revoke() }.buttonStyle(.bordered) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func permission(_ app: String, _ level: String, _ label: String) -> some View {
        Toggle("", isOn: Binding(get: { model.permissions.contains("\(app).\(level)") }, set: { model.setPermission(app, level, $0) }))
            .toggleStyle(.checkbox).labelsHidden().frame(width: 42).disabled(model.current?.revoked == true)
            .accessibilityLabel("\(app).\(level)").help("\(app) · \(label)")
    }
    private var applications: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("系统访问", systemImage: "lock.shield"); Spacer(); Text(checkedTime) }.font(.system(size: 11)).foregroundStyle(Ink.secondary)
                ForEach(ConnectedApp.all) { app in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            AppIcon(app: app, size: 44)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(app.name).font(.system(size: 14, weight: .semibold))
                                Text(app.capability).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                            }
                            Spacer(); status(app.id)
                        }
                        Text(model.access[app.id]?.detail ?? "点击刷新检查系统访问，不会自动请求授权。").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        HStack(spacing: 10) {
                            switch app.id {
                            case "mail": actionButton("完全磁盘访问", "privacy"); actionButton("授权 Mail 自动化", "mail")
                            case "calendar", "reminders": actionButton("授权日历与提醒事项", "eventkit")
                            case "notes": actionButton("授权备忘录", "notes")
                            case "messages": actionButton("完全磁盘访问", "privacy"); actionButton("授权信息自动化", "messages")
                            default: actionButton("完全磁盘访问", "privacy"); actionButton("配置录音快捷指令", "recording")
                            }
                            Spacer()
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                Button("打开应用") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.system(size: 11))
                            }
                        }
                    }.padding(18).background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(model.serviceLabel).font(.system(size: 12, weight: .medium)); Text("授权变更后刷新；完全磁盘访问变更后重启服务。").font(.system(size: 11)).foregroundStyle(Ink.secondary) }
                    Spacer(); actionButton("启用 / 重启服务", "service")
                }.padding(.vertical, 12)
                Text("这里是 macOS 系统访问状态。每个 Agent 还需在「Agent」页面单独授权；拥有当前用户完整终端权限的程序不在本服务隔离范围内。")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }.padding(30)
        }
    }
    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("最近 \(model.activity.count) 个请求"); Spacer(); Text("手动刷新 · 最多 80 条") }.font(.system(size: 11)).foregroundStyle(Ink.secondary)
                if model.activity.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "clock").font(.system(size: 32, weight: .light)).foregroundStyle(Ink.secondary)
                        Text("还没有调用记录").font(.system(size: 16, weight: .medium))
                        Text("接入 Agent 并调用工具后，在这里刷新查看。").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 90)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(model.activity) { event in activityRow(event) }
                    }.clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("仅显示工具名称、Agent、状态、时间与耗时。此处的「已开始」为最后一条记录，不代表请求当前仍在线。")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }.padding(30)
        }
    }
    private func activityRow(_ event: RecentActivity) -> some View {
        HStack(spacing: 14) {
            Image(systemName: event.phase == "finished" ? "checkmark.circle" : event.phase == "failed" || event.phase == "denied_before_execution" ? "exclamationmark.circle" : "clock")
                .foregroundStyle(event.phase == "failed" || event.phase == "denied_before_execution" ? Color.orange : Ink.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text(event.tool).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Text(model.agents.first { $0.id == event.agentID }?.name ?? "历史 Agent").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text(event.label + (event.duration.map { " · \($0) ms" } ?? "")).font(.system(size: 11))
                Text(event.time.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Ink.secondary)
            }
        }.padding(16).background(Ink.panel)
    }
    private var checkedTime: String { model.checkedAt.map { "检查于 " + $0.formatted(date: .omitted, time: .shortened) } ?? "尚未检查" }
    private func status(_ id: String) -> some View {
        let value = model.access[id]
        return Label(value?.title ?? "尚未检查", systemImage: value?.ready == true ? "checkmark.circle" : "minus.circle")
            .font(.system(size: 10)).foregroundStyle(value?.ready == false ? Color.orange : Ink.secondary)
    }
    private func sectionTitle(_ title: String, action: String, work: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); Button(action, action: work).font(.system(size: 11)).buttonStyle(.borderless) }
    }
    private func actionButton(_ title: String, _ action: String) -> some View {
        Button(title) { model.action(action) }.buttonStyle(.bordered).font(.system(size: 11))
    }
}
