import AppKit
import SwiftUI
import PersonalCore

@MainActor final class DashboardWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: DashboardModel
    init(registry: AgentRegistry, serviceRunning: @escaping () -> Bool, action: @escaping (String) -> Void) throws {
        model = try DashboardModel(registry: registry, serviceRunning: serviceRunning, action: action)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Apple Personal MCP"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = NSColor(calibratedWhite: 20/255, alpha: 1)
        window.minSize = NSSize(width: 1000, height: 690); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model)); window.delegate = self; window.center()
    }
    func show(_ page: DashboardPage? = nil) {
        if let page { model.page = page }
        if !window.isVisible { model.refresh() }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func refresh() { model.refresh() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.canDiscard() else { return false }
        model.discardEdits(); return true
    }
}
