import AppKit

final class PointerDispatchProbe: FloatingActionSurface {
    var received: [NSEvent.EventType] = []
    override func mouseDown(with event: NSEvent) { received.append(event.type) }
    override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    override func mouseUp(with event: NSEvent) { received.append(event.type) }
    override func rightMouseDown(with event: NSEvent) { received.append(event.type) }
    override func mouseMoved(with event: NSEvent) { received.append(event.type) }
}

@main
struct FloatingActionTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let domain = "local.mivo.floating-tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let model = HoldModel(preferences: preferences, developerMode: true)
        var openedMain = 0
        var quitRequests = 0

        func makePanel() -> (FloatingActionController, NSWindow) {
            let existing = Set(NSApp.windows.map(\.windowNumber))
            let controller = FloatingActionController(model: model, preferences: preferences,
                                                     openMainWindow: { openedMain += 1 },
                                                     quitApplication: { quitRequests += 1 })
            let window = NSApp.windows.first { !existing.contains($0.windowNumber) && $0.identifier?.rawValue == "floating-actions" }!
            return (controller, window)
        }

        let (first, panel) = makePanel()
        precondition(!panel.canBecomeKey && !panel.canBecomeMain)
        precondition(panel.styleMask.contains(.nonactivatingPanel))
        precondition(!panel.hidesOnDeactivate && panel.level == .floating)
        precondition(panel.frame.size == NSSize(width: 44, height: 44))
        let content = panel.contentView!
        precondition(content.hitTest(NSPoint(x: content.frame.midX, y: content.frame.midY)) === content)
        print("PASS: passive floating panel cannot take keyboard focus and keeps fixed dimensions.")

        let surface = content as! FloatingActionSurface
        let probe = PointerDispatchProbe(model: model)
        panel.contentView = probe
        let eventTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved]
        for type in eventTypes {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 22, y: 22), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(event)
        }
        precondition(probe.received == eventTypes && !panel.isKeyWindow && !panel.ignoresMouseEvents)
        panel.contentView = surface
        print("PASS: window-level dispatch delivers click, drag, release, right-click and cursor movement without keyboard focus.")
        let beforeDrag = panel.frame.origin
        surface.beginPointerPress(at: NSPoint(x: 100, y: 100))
        precondition(surface.interaction.pressed && !surface.interaction.dragging)
        surface.dragPointer(to: NSPoint(x: 101, y: 101))
        precondition(panel.frame.origin == beforeDrag)
        surface.dragPointer(to: NSPoint(x: 50, y: 124))
        precondition(surface.interaction.dragging)
        precondition(panel.frame.origin == NSPoint(x: beforeDrag.x - 50, y: beforeDrag.y + 24))
        surface.endPointerPress()
        precondition(!surface.interaction.pressed && !surface.interaction.dragging && !panel.isKeyWindow)
        let draggedPosition = preferences.dictionary(forKey: "floatingPanelOrigin")!
        precondition(draggedPosition["x"] as? Double == panel.frame.origin.x)
        print("PASS: native drag moves the panel, ignores click jitter, saves position and clears pressed feedback.")

        let menu = surface.menu!
        precondition(menu.items.map(\.title) == ["打开主窗口", "退出"])
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        precondition(openedMain == 1 && quitRequests == 1)
        print("PASS: the context menu has exactly the two requested actions and routes both callbacks.")

        model.floatingStyle = .standard
        precondition(panel.frame.size == NSSize(width: 300, height: 82))
        model.floatingStyle = .mini
        precondition(panel.frame.size == NSSize(width: 44, height: 44))
        model.floatingVisible = false
        first.show()
        precondition(!panel.isVisible)
        precondition(panel.frame.size == NSSize(width: 44, height: 44))
        model.floatingVisible = true
        print("PASS: style changes resize the native window; reopening respects the hidden preference.")

        let initial = panel.frame.origin
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        let saved = preferences.dictionary(forKey: "floatingPanelOrigin")!
        precondition(saved["x"] as? Double == initial.x && saved["y"] as? Double == initial.y)
        let (second, restored) = makePanel()
        precondition(restored.frame.origin == initial)
        print("PASS: a moved panel position is persisted and restored.")

        preferences.set(["x": -1e10, "y": -1e10], forKey: "floatingPanelOrigin")
        let (third, recovered) = makePanel()
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(recovered.frame) })
        print("PASS: a saved position outside connected displays is recovered on screen.")
        withExtendedLifetime([first, second, third]) {}
    }
}
