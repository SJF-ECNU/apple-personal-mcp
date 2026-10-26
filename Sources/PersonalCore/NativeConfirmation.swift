import AppKit
import Foundation

public enum NativeConfirmation {
    public static func ask(_ title: String, _ detail: String) -> Bool {
        let show = {
            let alert = NSAlert(); alert.messageText = title
            if detail.count > 600 {
                alert.informativeText = "请核对以下完整内容。可滚动查看。"
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 260)); scroll.hasVerticalScroller = true
                let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 13); text.string = detail
                text.isVerticallyResizable = true; text.autoresizingMask = [.width]; scroll.documentView = text; alert.accessoryView = scroll
            } else { alert.informativeText = detail }
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertSecondButtonReturn
        }
        return Thread.isMainThread ? show() : DispatchQueue.main.sync(execute: show)
    }
}
