import AppKit
import SwiftUI

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
        testShortcutRecorder()
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
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings-to"),
           CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settingsModel = HoldModel(preferences: preferences, developerMode: false,
                                          permissionProbe: { SystemPermissions(accessibility: false, inputMonitoring: false) })
            func capture<V: View>(_ view: V, name: String, expectedWidth: CGFloat) {
                let host = NSHostingView(rootView: view)
                let bounds = NSRect(origin: .zero, size: host.fittingSize)
                precondition(bounds.width == expectedWidth && bounds.height > 100)
                host.frame = bounds
                let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.display()
                let image = host.bitmapImageRepForCachingDisplay(in: bounds)!
                host.cacheDisplay(in: bounds, to: image)
                try! image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
                withExtendedLifetime(window) {}
            }
            for mode in SimulationMode.allCases {
                settingsModel.configureShortcut(mode: mode)
                capture(SettingsView(model: settingsModel), name: "settings-\(mode.rawValue).png", expectedWidth: 470)
            }
            capture(ShortcutEditor(model: settingsModel, dismiss: {}).background(Color(nsColor: .windowBackgroundColor)),
                    name: "shortcut-editor.png", expectedWidth: 330)
            print("PASS: settings keep 470-point width; rendered hold, tap and custom editor previews.")
        }
        withExtendedLifetime([first, second, third]) {}
    }
    static func testShortcutRecorder() {
        let rightCommand = NSEvent.ModifierFlags(rawValue: UInt(SimulatedShortcut.modifierFlags(for: 0x36).rawValue))
        let option = NSEvent.ModifierFlags(rawValue: UInt(SimulatedShortcut.modifierFlags(for: 0x3A).rawValue))
        let combination = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [rightCommand, option],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        precondition(ShortcutRecorderButton.shortcutKeys(for: combination) == [0x3A, 0x36, 49])
        let aggregateOnly = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        precondition(ShortcutRecorderButton.shortcutKeys(for: aggregateOnly) == [0x3B,0x3A,40])
        let rightOnly = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x36)!
        precondition(ShortcutRecorderButton.shortcutKeys(for: rightOnly) == [0x36])
        let commandChord = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        precondition(ShortcutRecorderButton.shortcutKeys(for: commandChord, knownModifiers: [0x36]) == [0x36,40])
        let fn = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .function,
                                 timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x3F)!
        precondition(ShortcutRecorderButton.shortcutKeys(for: fn) == [0x3F])
        // AppKit may associate popover input with its parent window or window 0.
        // Exercise the recorder state machine with both, not just the key decoder.
        let recorder = ShortcutRecorderButton(title: "从键盘录入…", target: nil, action: nil)
        var captured: [SimulatedShortcut] = []
        recorder.onCapture = { captured.append($0) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let fromParent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: parent.windowNumber, context: nil,
                                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        recorder.toggleRecording()
        precondition(recorder.consumeRecordingEvent(fromParent) == nil)
        precondition(captured.last?.keys == [0] && recorder.title == "从键盘录入…")
        precondition(recorder.consumeRecordingEvent(fromParent) === fromParent)
        recorder.toggleRecording()
        precondition(recorder.consumeRecordingEvent(fn) == nil && captured.last?.keys == [0x3F])
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        precondition(recorder.title == "从键盘录入…")
        recorder.toggleRecording()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        let beforeEscape = captured.count
        precondition(recorder.consumeRecordingEvent(escape) == nil && captured.count == beforeEscape)
        precondition(recorder.consumeRecordingEvent(combination) === combination)
        recorder.toggleRecording()
        _ = recorder.consumeRecordingEvent(aggregateOnly)
        precondition(captured.last?.keys == [0x3B,0x3A,40])
        recorder.toggleRecording()
        _ = recorder.consumeRecordingEvent(rightOnly)
        _ = recorder.consumeRecordingEvent(commandChord)
        precondition(captured.last?.keys == [0x36,40])
        recorder.toggleRecording()
        _ = recorder.consumeRecordingEvent(combination)
        precondition(captured.last?.keys == [0x3A,0x36,49])
        withExtendedLifetime(parent) {}
        print("PASS: recorder accepts parent-window and windowless input, cancels on Esc / app deactivation, and stops intercepting after capture.")
        print("PASS: shortcut recorder captures modifier sides, combinations and Fn.")
    }

}
