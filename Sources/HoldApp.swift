import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import SwiftUI

let vendorID = 0x2CA3
let productID = 0x4011
let volumeIncrement: UInt32 = 0xE9
let volumeDecrement: UInt32 = 0xEA
let consumerPage: UInt32 = 0x0C
let returnKey: CGKeyCode = 0x24
let samePressWindow: TimeInterval = 0.05
let sendWindow: TimeInterval = 3

enum Phase: String {
    case idle = "空闲"
    case holding = "按住中"
    case released = "已松开"
}

enum SimulatedDevice: String, CaseIterable, Identifiable {
    case ready = "已连接且已授权"
    case disconnected = "未连接"
    case needsPermissions = "需要授权"
    var id: String { rawValue }
}

enum Pending {
    case holdDown
    case release
    case send
    case tap
}

enum SimulationMode: String, CaseIterable, Identifiable {
    case hold, tap
    var id: String { rawValue }
    var title: String { self == .hold ? "按住" : "点按" }
}

enum ShortcutPreset: String, CaseIterable, Identifiable {
    case leftCommand, rightCommand, fn, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftCommand: return "左 Command ⌘"
        case .rightCommand: return "右 Command ⌘"
        case .fn: return "Fn / 🌐（实验）"
        case .custom: return "自定义…"
        }
    }
    var shortcut: SimulatedShortcut? {
        switch self {
        case .leftCommand: return SimulatedShortcut(keys: [0x37])
        case .rightCommand: return SimulatedShortcut(keys: [0x36])
        case .fn: return SimulatedShortcut(keys: [0x3F])
        case .custom: return nil
        }
    }
}

struct SimulatedShortcut: Codable, Equatable {
    let keys: [CGKeyCode]
    static let modifierNames: [CGKeyCode: String] = [
        0x37: "左 Command", 0x36: "右 Command", 0x3A: "左 Option", 0x3D: "右 Option",
        0x3B: "左 Control", 0x3E: "右 Control", 0x38: "左 Shift", 0x3C: "右 Shift", 0x3F: "Fn"
    ]
    static let names: [CGKeyCode: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
        12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
        24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
        36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",
        48:"Tab",49:"Space",50:"`",51:"Backspace",53:"Escape",65:"KeypadDecimal",67:"KeypadMultiply",
        69:"KeypadPlus",71:"KeypadClear",75:"KeypadDivide",76:"KeypadEnter",78:"KeypadMinus",
        81:"KeypadEquals",82:"Keypad0",83:"Keypad1",84:"Keypad2",85:"Keypad3",86:"Keypad4",
        87:"Keypad5",88:"Keypad6",89:"Keypad7",91:"Keypad8",92:"Keypad9",
        64:"F17",79:"F18",80:"F19",90:"F20",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",
        103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Help",
        115:"Home",116:"PageUp",117:"Delete",118:"F4",119:"End",120:"F2",121:"PageDown",122:"F1",
        123:"Left",124:"Right",125:"Down",126:"Up"
    ]
    var isValid: Bool {
        !keys.isEmpty && keys.count <= 5 && Set(keys).count == keys.count &&
        keys.allSatisfy { Self.names[$0] != nil || Self.modifierNames[$0] != nil } &&
        keys.filter { Self.modifierNames[$0] == nil }.count <= 1 &&
        !keys.dropLast().contains { Self.modifierNames[$0] == nil }
    }
    var title: String { keys.map { Self.modifierNames[$0] ?? Self.names[$0] ?? "?" }.joined(separator: " + ") }
    var includesFn: Bool { keys.contains(0x3F) }

    static func parse(_ text: String) -> SimulatedShortcut? {
        let aliases: [String: CGKeyCode] = ["command":0x37,"cmd":0x37,"⌘":0x37,"option":0x3A,"alt":0x3A,"⌥":0x3A,
            "control":0x3B,"ctrl":0x3B,"⌃":0x3B,"shift":0x38,"⇧":0x38,"enter":36,"spacebar":49,
            "leftcommand":0x37,"rightcommand":0x36,"leftoption":0x3A,"rightoption":0x3D,
            "leftcontrol":0x3B,"rightcontrol":0x3E,"leftshift":0x38,"rightshift":0x3C,"🌐":0x3F]
        func normalized(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        let known = Dictionary(uniqueKeysWithValues: (names.merging(modifierNames) { _, next in next }).map { (normalized($0.value), $0.key) })
        let tokens = text.components(separatedBy: "+").map(normalized)
        let keys = tokens.compactMap { known[$0] ?? aliases[$0] }
        let result = SimulatedShortcut(keys: keys)
        return keys.count == tokens.count && result.isValid ? result : nil
    }

    static func modifierFlags(for key: CGKeyCode) -> CGEventFlags {
        switch key {
        case 0x37: return CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        case 0x36: return CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        case 0x38: return CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        case 0x3C: return CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04)
        case 0x3A: return CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        case 0x3D: return CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        case 0x3B: return CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01)
        case 0x3E: return CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
        case 0x3F: return .maskSecondaryFn
        default: return []
        }
    }

    func events(pressed: Bool) -> [CGEvent]? {
        guard isValid else { return nil }
        let source = CGEventSource(stateID: .privateState)
        var active: [CGKeyCode] = pressed ? [] : keys
        var result: [CGEvent] = []
        for key in pressed ? keys : Array(keys.reversed()) {
            if pressed { active.append(key) } else { active.removeAll { $0 == key } }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: pressed) else { return nil }
            if Self.modifierNames[key] != nil { event.type = .flagsChanged }
            event.flags = active.reduce(CGEventFlags()) { $0.union(Self.modifierFlags(for: $1)) }
            event.setIntegerValueField(.eventSourceUserData, value: mivoEventTag)
            result.append(event)
        }
        return result
    }
}

// F20 is only a transport key for receiver reports, never the user's selected output.
let carrierKey: CGKeyCode = 90
let mivoEventTag: Int64 = 0x4D49564F

// Each lease owns only one HID service and preserves its pre-existing mappings.
typealias KeyMappings = [[String: UInt64]]
let mappingSource = "HIDKeyboardModifierMappingSrc"
let mappingDestination = "HIDKeyboardModifierMappingDst"

struct MappingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class KeyMappingLease {
    let read: () throws -> KeyMappings
    let write: (KeyMappings) throws -> Void
    private var original: KeyMappings?
    private var applied: KeyMappings?

    init(read: @escaping () throws -> KeyMappings, write: @escaping (KeyMappings) throws -> Void) {
        self.read = read
        self.write = write
    }

    func apply() throws {
        guard original == nil else { throw MappingError(message: "旧按键映射尚未恢复。") }
        let previous = try read()
        let sources: Set<UInt64> = [0xC000000E9, 0xC000000EA]
        var next = previous.filter { !sources.contains($0[mappingSource] ?? 0) }
        next += sources.sorted().map { [mappingSource: $0, mappingDestination: 0x70000006F] }
        original = previous
        applied = next
        try write(next)
    }

    // A subsequent external edit takes precedence over our snapshot.
    @discardableResult
    func restore() throws -> Bool {
        guard let original, let applied else { return true }
        let unchanged = try read() == applied
        if unchanged { try write(original) }
        self.original = nil
        self.applied = nil
        return unchanged
    }
}

final class ReceiverKeyMappings {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var leases: [(id: UInt64, lease: KeyMappingLease)] = []

    private var services: [IOHIDServiceClient] {
        IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
    }

    func apply() throws {
        guard leases.isEmpty else { throw MappingError(message: "旧按键映射尚未恢复，请暂停后重试。") }
        let targets = services.filter { service in
            (IOHIDServiceClientCopyProperty(service, "VendorID" as CFString) as? NSNumber)?.intValue == vendorID &&
            (IOHIDServiceClientCopyProperty(service, "ProductID" as CFString) as? NSNumber)?.intValue == productID
        }
        guard !targets.isEmpty else { throw MappingError(message: "未找到接收器按键服务。") }
        for service in targets {
            guard let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber else {
                throw MappingError(message: "无法读取接收器服务标识。")
            }
            let lease = KeyMappingLease(read: {
                guard let raw = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
                guard let mappings = raw as? KeyMappings else {
                    throw MappingError(message: "无法识别原按键映射，未覆盖。")
                }
                return mappings
            }, write: { mappings in
                guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, mappings as NSArray) else {
                    throw MappingError(message: "设置接收器按键映射失败。")
                }
            })
            leases.append((id.uint64Value, lease))
            try lease.apply()
        }
    }

    func restore() throws -> Bool {
        let connected = Set(services.compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value })
        var pending: [(id: UInt64, lease: KeyMappingLease)] = []
        var failure: Error?
        var unchanged = true
        for entry in leases where connected.contains(entry.id) {
            do { if try !entry.lease.restore() { unchanged = false } }
            catch { pending.append(entry); failure = error }
        }
        leases = pending
        if let failure { throw failure }
        return unchanged
    }
}

func receiverIsConnected() -> Bool {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey as String: vendorID,
        kIOHIDProductIDKey as String: productID,
    ] as CFDictionary)
    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == 0 else { return false }
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    return !devices.isEmpty
}

struct SystemPermissions {
    let accessibility: Bool
    let inputMonitoring: Bool

    static func current() -> SystemPermissions {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return SystemPermissions(
            accessibility: AXIsProcessTrustedWithOptions([prompt: false] as CFDictionary),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }
}

enum NextButtonAction {
    case unavailable, startListening, stopListening, sendReturn, tapShortcut

    var title: String {
        switch self {
        case .unavailable: return "暂不可用"
        case .startListening: return "按住快捷键"
        case .stopListening: return "松开快捷键"
        case .sendReturn: return "发送回车"
        case .tapShortcut: return "点按快捷键"
        }
    }

    var symbol: String {
        switch self {
        case .unavailable: return "exclamationmark.circle"
        case .startListening: return "mic"
        case .stopListening: return "stop"
        case .sendReturn: return "return"
        case .tapShortcut: return "keyboard"
        }
    }
}

enum FloatingHUDStyle: String, CaseIterable, Identifiable {
    case standard, mini
    var id: String { rawValue }
    var title: String { self == .mini ? "迷你" : "标准" }
    var size: NSSize { self == .mini ? NSSize(width: 44, height: 44) : NSSize(width: 300, height: 82) }
}

final class HoldModel: ObservableObject {
    private let permissionProbe: () -> SystemPermissions
    private let preferences: UserDefaults
    private let observeOutput: (([CGEvent]) -> Void)?
    @Published private(set) var simulationMode: SimulationMode
    @Published private(set) var shortcutPreset: ShortcutPreset
    @Published private(set) var customShortcut: SimulatedShortcut
    var selectedShortcut: SimulatedShortcut { shortcutPreset.shortcut ?? customShortcut }
    private(set) var heldShortcut: SimulatedShortcut?
    private var outputGeneration = 0
    @Published var floatingVisible: Bool {
        didSet { preferences.set(floatingVisible, forKey: "floatingVisible") }
    }
    @Published var floatingStyle: FloatingHUDStyle {
        didSet { preferences.set(floatingStyle.rawValue, forKey: "floatingStyle") }
    }
    @Published var sendOnRepress: Bool {
        didSet {
            preferences.set(sendOnRepress, forKey: "sendOnRepress")
        }
    }
    @Published private(set) var developerMode: Bool
    @Published var simulatedDevice: SimulatedDevice = .ready {
        didSet { if developerMode { stopControl(); reconcile() } }
    }
    @Published private(set) var controlEnabled: Bool
    @Published var uptime = ProcessInfo.processInfo.systemUptime
    @Published var controlError: String?
    @Published var permissionRepairMessage = ""
    @Published var repairingPermission = false
    @Published var osVersion = ""
    @Published var hostName = ""
    @Published var receiverConnected = false
    @Published var controlling = false
    @Published private(set) var systemAccessibilityOK = false
    @Published private(set) var systemInputMonitorOK = false
    @Published var accessibilityOK = false
    @Published var inputMonitorOK = false
    @Published var tapReady = false
    @Published private(set) var pairingKeyDown = false
    @Published private(set) var buttonEventCount = 0
    @Published var phase: Phase = .idle
    @Published var logs: [String] = []
    @Published var status = "正在启动…"

    var lastHIDAt: TimeInterval = 0
    var releasedAt: TimeInterval = 0
    var gesture: Phase = .idle
    var pending: Pending?
    var swallowUp = false
    var held: [UInt32: Bool] = [:]
    lazy var receiverMappings = ReceiverKeyMappings()
    var manager: IOHIDManager?
    var keyTap: CFMachPort?
    var timer: Timer?
    var countdownTimer: Timer?
    var tapSource: CFRunLoopSource?

    init(preferences: UserDefaults = .standard,
         developerMode: Bool = ProcessInfo.processInfo.arguments.contains("--dev"),
         permissionProbe: @escaping () -> SystemPermissions = SystemPermissions.current,
         observeOutput: (([CGEvent]) -> Void)? = nil) {
        self.permissionProbe = permissionProbe
        self.preferences = preferences
        self.observeOutput = observeOutput
        self.simulationMode = SimulationMode(rawValue: preferences.string(forKey: "simulationMode") ?? "") ?? .hold
        self.shortcutPreset = ShortcutPreset(rawValue: preferences.string(forKey: "shortcutPreset") ?? "") ?? .rightCommand
        if let data = preferences.data(forKey: "customShortcut"),
           let saved = try? JSONDecoder().decode(SimulatedShortcut.self, from: data), saved.isValid {
            self.customShortcut = saved
        } else { self.customShortcut = SimulatedShortcut(keys: [0x3A, 49]) }
        self.developerMode = developerMode
        self.sendOnRepress = preferences.object(forKey: "sendOnRepress") as? Bool ?? true
        self.controlEnabled = preferences.object(forKey: "controlEnabled") as? Bool ?? true
        self.floatingVisible = preferences.object(forKey: "floatingVisible") as? Bool ?? true
        self.floatingStyle = FloatingHUDStyle(rawValue: preferences.string(forKey: "floatingStyle") ?? "") ?? .mini
    }

    func refreshSystem() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        receiverConnected = developerMode ? simulatedDevice != .disconnected : receiverIsConnected()
    }

    func refreshPermissions() {
        let permissions = permissionProbe()
        if systemAccessibilityOK != permissions.accessibility || systemInputMonitorOK != permissions.inputMonitoring {
            note("系统权限：辅助功能=\(permissions.accessibility)，输入监控=\(permissions.inputMonitoring)")
        }
        systemAccessibilityOK = permissions.accessibility
        systemInputMonitorOK = permissions.inputMonitoring
        if developerMode {
            accessibilityOK = simulatedDevice != .needsPermissions
            inputMonitorOK = simulatedDevice != .needsPermissions
            tapReady = controlling
        } else {
            accessibilityOK = permissions.accessibility
            inputMonitorOK = permissions.inputMonitoring
            tapReady = keyTap != nil
        }
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    var sendRemaining: TimeInterval { max(0, sendWindow - (uptime - releasedAt)) }
    var canSend: Bool { simulationMode == .hold && controlling && phase == .released && sendOnRepress && sendRemaining > 0 }
    var nextButtonAction: NextButtonAction {
        guard receiverConnected, accessibilityOK, inputMonitorOK, controlEnabled,
              controlling, controlError == nil else { return .unavailable }
        if simulationMode == .tap { return .tapShortcut }
        if phase == .holding { return .stopListening }
        return canSend ? .sendReturn : .startListening
    }
    var title: String {
        if !receiverConnected { return "等待接收器" }
        if !accessibilityOK || !inputMonitorOK { return "还需完成授权" }
        if !controlEnabled { return "已暂停" }
        if !controlling { return "暂时无法使用" }
        if phase == .holding { return "保持按下" }
        if phase == .released { return "已松开" }
        return "已就绪"
    }
    var detail: String {
        if !receiverConnected { return "通过 USB 连接 DJI Mic Mini 2" }
        if !accessibilityOK || !inputMonitorOK { return "接收器已连接，授权后即可使用" }
        if let controlError { return controlError }
        return developerMode ? "模拟接收器 · 开发模式" : "DJI Mic Mini 2 已连接"
    }
    var guideInstruction: String {
        if !receiverConnected { return "先通过 USB 连接接收器" }
        if !accessibilityOK || !inputMonitorOK { return "先在设置中完成授权" }
        if !controlEnabled { return "先开启下方麦克风控制" }
        if simulationMode == .tap { return "短按高亮键，点按快捷键" }
        if phase == .holding { return "短按高亮配对键，松开快捷键" }
        if canSend { return "3 秒内再短按高亮键，发送回车" }
        return "短按高亮配对键，按住快捷键"
    }

    var hint: String {
        if !receiverConnected { return "连接接收器后自动就绪" }
        if !accessibilityOK || !inputMonitorOK { return "开启辅助功能和输入监控" }
        if !controlEnabled { return "开启控制后恢复使用" }
        if !controlling { return "请重试，或查看诊断日志" }
        if simulationMode == .tap { return "按一下，点按快捷键" }
        if phase == .holding { return "再按一下，松开快捷键" }
        if canSend { return "再按一下，发送回车" }
        return "按一下配对键，按住快捷键"
    }
    var symbol: String {
        if !receiverConnected { return "cable.connector" }
        if !accessibilityOK || !inputMonitorOK || controlError != nil { return "exclamationmark.circle" }
        if !controlEnabled { return "pause.circle" }
        return phase == .holding ? "mic.fill" : "mic"
    }

    func startWatching() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发"
        note("Mivo 构建 \(build) · 开始检查设备与系统权限。")
        reconcile()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard gesture == .released else { return }
        uptime = now
        if gesture == .released, sendRemaining <= 0 {
            gesture = .idle
            phase = .idle
        }
    }

    func reconcile() {
        refreshSystem()
        refreshPermissions()
        if controlling && (!receiverConnected || !accessibilityOK || !inputMonitorOK) {
            stopControl()
            note("设备断开或权限不可用，已结束控制。")
        }
        if controlEnabled && receiverConnected && accessibilityOK && inputMonitorOK && !controlling {
            startControl()
        }
    }

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
        preferences.set(enabled, forKey: "controlEnabled")
        if enabled { reconcile() } else { stopControl() }
    }

    func setDeveloperMode(_ enabled: Bool) {
        guard developerMode != enabled else { return }
        stopControl()
        developerMode = enabled
        controlError = nil
        reconcile()
        note(enabled ? "开发模式已开启：所有键盘输出仅记录日志。" : "已退出开发模式，恢复真实设备。")
    }

    var shortcutDescription: String { "\(simulationMode.title) · \(selectedShortcut.title)" }
    var nextActionTitle: String { nextButtonAction.title }
    var modeInstruction: String {
        simulationMode == .hold ? "短按一次按住快捷键，再按一次松开。" : "每次短按，发送一次完整按键。"
    }

    func configureShortcut(mode: SimulationMode? = nil, preset: ShortcutPreset? = nil,
                           custom: SimulatedShortcut? = nil) {
        guard custom?.isValid != false else { return }
        // Release the OLD shortcut before replacing preferences, and invalidate queued output.
        outputGeneration += 1
        releaseOutput()
        gesture = .idle; phase = .idle; pending = nil; releasedAt = 0
        if let mode { simulationMode = mode }
        if let custom { customShortcut = custom }
        if let preset { shortcutPreset = preset }
        preferences.set(simulationMode.rawValue, forKey: "simulationMode")
        preferences.set(shortcutPreset.rawValue, forKey: "shortcutPreset")
        preferences.set(try? JSONEncoder().encode(customShortcut), forKey: "customShortcut")
        note("按键设置：\(shortcutDescription)")
    }

    func simulatePress() {
        guard developerMode, controlling else { return }
        handleHID(page: consumerPage, usage: volumeIncrement, value: 1)
        handleHID(page: consumerPage, usage: volumeIncrement, value: 0)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: carrierKey, keyDown: down) else { continue }
            _ = handleCarrier(event)
        }
    }

    private func emit(_ events: [CGEvent], description: String) {
        observeOutput?(events)
        if developerMode { note("[模拟] \(description)（未向系统发送）") }
        else { for event in events { event.post(tap: .cghidEventTap) } }
    }

    private func releaseOutput() {
        guard let shortcut = heldShortcut else { return }
        if let events = shortcut.events(pressed: false) {
            emit(events, description: "松开 \(shortcut.title)")
        }
        heldShortcut = nil
    }

    private func perform(_ action: Pending) {
        switch action {
        case .holdDown:
            let shortcut = selectedShortcut
            guard let events = shortcut.events(pressed: true) else { return }
            heldShortcut = shortcut
            emit(events, description: "按住 \(shortcut.title)")
        case .release: releaseOutput()
        case .tap, .send:
            let shortcut = action == .send ? SimulatedShortcut(keys: [returnKey]) : selectedShortcut
            guard let down = shortcut.events(pressed: true), let up = shortcut.events(pressed: false) else { return }
            emit(down + up, description: action == .send ? "发送回车" : "点按 \(shortcut.title)")
        }
    }

    func openPermissionSettings(_ pane: String) {
        if pane == "Privacy_Accessibility" {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        } else if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func restartForPermissionCheck() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$@\"", "mivo-relaunch", Bundle.main.bundleURL.path]
            + (developerMode ? ["--args", "--dev"] : [])
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            permissionRepairMessage = "无法重启，请退出 Mivo 后重新打开。"
        }
    }

    func repairAccessibilityPermission() {
        guard !repairingPermission, let bundleID = Bundle.main.bundleIdentifier else { return }
        repairingPermission = true
        stopControl()
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Accessibility", bundleID]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var succeeded = false
            var detail = ""
            do {
                try task.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                succeeded = task.terminationStatus == 0
                detail = String(data: output, encoding: .utf8) ?? ""
            } catch { detail = error.localizedDescription }
            let result = succeeded
            let output = detail
            DispatchQueue.main.async {
                self.repairingPermission = false
                self.permissionRepairMessage = result
                    ? "已清理 Mivo 的旧辅助功能授权。请在系统设置中为当前 Mivo 重新授权，再点重启。"
                    : "重置失败，请在系统设置中移除旧 Mivo，再添加当前应用。"
                self.note("辅助功能修复：\(output)")
                self.refreshPermissions()
                if result { self.openPermissionSettings("Privacy_Accessibility") }
            }
        }
    }

    func startControl() {
        refreshSystem()
        refreshPermissions()
        guard receiverConnected else {
            status = "没有找到大疆接收器。请用 USB 插上。"
            return
        }
        guard !controlling else { return }
        guard accessibilityOK else {
            status = "请在系统设置 → 隐私与安全性 → 辅助功能 中勾选 Mivo，授权后会自动恢复。"
            return
        }
        guard inputMonitorOK else {
            status = "请在系统设置 → 隐私与安全性 → 输入监控 中勾选 Mivo，授权后会自动恢复。"
            return
        }
        controlError = nil
        if developerMode {
            controlling = true
            tapReady = true
            note("模拟控制已开启。")
            return
        }
        do {
            try receiverMappings.apply()
        } catch {
            restoreReceiverMappings()
            controlError = "按键映射失败，请重试。"
            note("音量键改写失败：\(error.localizedDescription)")
            return
        }
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hid, [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ] as CFDictionary)
        let callback: IOHIDValueCallback = { _, _, _, value in
            let element = IOHIDValueGetElement(value)
            HoldModel.shared.handleHID(
                page: IOHIDElementGetUsagePage(element),
                usage: IOHIDElementGetUsage(element),
                value: IOHIDValueGetIntegerValue(value)
            )
        }
        IOHIDManagerRegisterInputValueCallback(hid, callback, nil)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == 0 else {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
            restoreReceiverMappings()
            controlError = "无法打开接收器，请重试。"
            note("打不开接收器。")
            return
        }
        manager = hid
        guard installTap() else {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
            restoreReceiverMappings()
            controlError = "按键控制未就绪，请检查权限。"
            note("按键拦截未生效。")
            return
        }
        controlling = true
        refreshPermissions()
        note("已开启：\(shortcutDescription)。")
    }

    func restoreReceiverMappings() {
        do {
            if try !receiverMappings.restore() { note("检测到外部按键映射变更，已保留外部设置。") }
        } catch {
            note("恢复原按键映射失败：\(error.localizedDescription)。请暂停后重试。")
        }
    }

    func stopControl() {
        outputGeneration += 1
        releaseOutput()
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        if let keyTap { CFMachPortInvalidate(keyTap) }
        keyTap = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        if !developerMode { restoreReceiverMappings() }
        held.removeAll()
        pairingKeyDown = false
        lastHIDAt = 0
        releasedAt = 0
        controlError = nil
        gesture = .idle
        phase = .idle
        pending = nil
        swallowUp = false
        controlling = false
        refreshPermissions()
        note("已暂停。")
    }

    @discardableResult
    func installTap() -> Bool {
        guard !developerMode else { return true }
        if keyTap != nil { return true }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        keyTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let keyTap = HoldModel.shared.keyTap {
                        CGEvent.tapEnable(tap: keyTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if HoldModel.shared.handleCarrier(event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        guard let keyTap else {
            refreshPermissions()
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: keyTap, enable: true)
        refreshPermissions()
        return true
    }

    func handleHID(page: UInt32, usage: UInt32, value: CFIndex) {
        guard controlling else { return }
        guard page == consumerPage else { return }
        guard usage == volumeIncrement || usage == volumeDecrement else { return }
        let isDown = value != 0
        if held[usage] == isDown { return }
        held[usage] = isDown
        pairingKeyDown = held.values.contains(true)
        guard isDown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHIDAt < samePressWindow { return }
        lastHIDAt = now
        buttonEventCount += 1
        uptime = now
        if simulationMode == .tap {
            gesture = .idle
            phase = .idle
            pending = .tap
            note("点按 \(selectedShortcut.title)")
            return
        }
        switch gesture {
        case .holding:
            gesture = .released
            releasedAt = now
            pending = .release
            publish(.released, "松开快捷键")
        case .released where sendOnRepress && now - releasedAt <= sendWindow:
            gesture = .idle
            pending = .send
            publish(.idle, "发送回车")
        default:
            gesture = .holding
            pending = .holdDown
            publish(.holding, "按住快捷键")
        }
    }

    func handleCarrier(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != mivoEventTag,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(carrierKey) else { return false }
        if event.type == .keyUp {
            guard swallowUp else { return false }
            swallowUp = false
            return true
        }
        guard event.type == .keyDown else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return swallowUp }
        let now = ProcessInfo.processInfo.systemUptime
        guard controlling, lastHIDAt > 0, now - lastHIDAt < 0.3, let action = pending else { return false }
        pending = nil
        swallowUp = true
        if developerMode { perform(action) }
        else {
            // Wait until the transport event has been swallowed before injecting output.
            let generation = outputGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controlling, self.outputGeneration == generation else { return }
                self.perform(action)
            }
        }
        return true
    }

    func publish(_ next: Phase, _ text: String) {
        phase = next
        note(text)
    }

    func note(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("\(stamp)  \(text)", at: 0)
        if logs.count > 500 { logs.removeLast() }
        status = text
    }

    static let shared = HoldModel()
}

struct LogPanelView: View {
    @ObservedObject var model: HoldModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("诊断日志").font(.title2.weight(.semibold))
                Text("macOS \(model.osVersion) · \(model.hostName)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.developerMode {
                    Label("开发模式 · 键盘输出仅记录日志", systemImage: "hammer")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.logs.isEmpty {
                        Text("暂无日志").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }.padding(20)
            }
        }.frame(minWidth: 460, minHeight: 320)
    }
}

struct DeveloperControls: View {
    @ObservedObject var model: HoldModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("开发模式", systemImage: "hammer.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Picker("模拟设备", selection: $model.simulatedDevice) {
                ForEach(SimulatedDevice.allCases) { device in
                    Text(device.rawValue).tag(device)
                }
            }
            Button { model.simulatePress() } label: {
                Label("按一下接收器", systemImage: "radio")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.controlling)
            Text("复用真实按键处理流程；不会映射硬件或向其他应用发送按键。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusPanel: View {
    @ObservedObject var model: HoldModel
    @Environment(\.openWindow) private var openWindow

    private var statusColor: Color {
        if !model.receiverConnected || !model.accessibilityOK || !model.inputMonitorOK || model.controlError != nil { return .orange }
        return model.controlling ? .accentColor : .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Mivo", systemImage: "mic").font(.headline)
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.vertical, 18)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                MicMini2Guide(model: model)
                    .padding(.bottom, 18)
                Text(model.title).font(.system(size: 25, weight: .semibold))
                Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 5).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.controlling ? model.guideInstruction : model.hint).font(.subheadline.weight(.medium))
                    if model.canSend {
                        Text("发送窗口剩余 \(model.sendRemaining, specifier: "%.1f") 秒")
                            .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: model.sendRemaining, total: sendWindow)
                            .accessibilityLabel("发送窗口剩余时间")
                    } else {
                        Text(model.phase == .holding && model.controlling
                             ? "\(model.selectedShortcut.title) 保持按下"
                             : model.shortcutDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 24)
                if model.receiverConnected && (!model.accessibilityOK || !model.inputMonitorOK) {
                    Button("前往授权") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
                    }.buttonStyle(.borderedProminent).padding(.top, 14)
                } else if model.controlError != nil {
                    Button("重试") { model.reconcile() }.padding(.top, 14)
                }
            }.padding(24)
            Divider()
            HStack {
                Text("麦克风控制")
                Spacer()
                Toggle("麦克风控制", isOn: Binding(get: { model.controlEnabled }, set: { model.setControlEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            if model.developerMode {
                DeveloperControls(model: model).padding(.horizontal, 16).padding(.bottom, 16)
            }
            HStack {
                if model.developerMode {
                    Text("DEV").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                }
                Spacer()
                Menu {
                    Button("诊断日志…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "logs")
                    }
                    Divider()
                    Button("退出 Mivo") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("更多操作")
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 22).padding(.bottom, 12)
        }
        .frame(width: 350)
    }
}

struct ShortcutEditor: View {
    @ObservedObject var model: HoldModel
    let dismiss: () -> Void
    @State private var draft = ""

    private var parsed: SimulatedShortcut? { SimulatedShortcut.parse(draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义模拟按键").font(.headline)
            TextField("例如 Option + Space", text: $draft)
                .textFieldStyle(.roundedBorder)
            ShortcutRecorder { shortcut in draft = shortcut.title }.frame(height: 26)
            Text("可输入键名或录入组合键，左右修饰键分别识别。")
                .font(.caption).foregroundStyle(.secondary)
            if !draft.isEmpty && parsed == nil {
                Text("请输入一个按键，或修饰键与一个普通键的组合。")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: dismiss)
                Button("使用此按键") {
                    guard let shortcut = parsed else { return }
                    model.configureShortcut(preset: .custom, custom: shortcut)
                    dismiss()
                }.disabled(parsed == nil)
            }
        }
        .padding(18).frame(width: 330)
        .onAppear { draft = model.customShortcut.title }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (SimulatedShortcut) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(title: "从键盘录入…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(ShortcutRecorderButton.toggleRecording)
        button.onCapture = onCapture
        return button
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) { button.onCapture = onCapture }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.stopRecording() }
}

final class ShortcutRecorderButton: NSButton {
    var onCapture: ((SimulatedShortcut) -> Void)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var recordedModifiers: [CGKeyCode] = []
    override var acceptsFirstResponder: Bool { true }

    @objc func toggleRecording() {
        if monitor != nil { stopRecording(); return }
        title = "请按快捷键，Esc 取消…"
        recordedModifiers = []
        window?.makeFirstResponder(self)
        // NSPopover's content window need not be the key window: AppKit can route
        // its keyboard events through the parent settings window (or no window).
        // A local monitor is already app-scoped; its lifetime defines capture scope.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard NSApp.isActive, self.window?.isVisible == true else {
                self.stopRecording()
                return event
            }
            return self.consumeRecordingEvent(event)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.stopRecording()
        }
    }

    func consumeRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard monitor != nil else { return event }
        if event.type == .keyDown && event.keyCode == 53 { stopRecording(); return nil }
        let keys = Self.shortcutKeys(for: event, knownModifiers: recordedModifiers)
        recordedModifiers = keys.filter { SimulatedShortcut.modifierNames[$0] != nil }
        let shortcut = SimulatedShortcut(keys: keys)
        if shortcut.isValid { onCapture?(shortcut) }
        if event.type == .keyDown { stopRecording() }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    static func shortcutKeys(for event: NSEvent, knownModifiers: [CGKeyCode] = []) -> [CGKeyCode] {
        let flags = UInt64(event.modifierFlags.rawValue)
        var keys: [CGKeyCode] = []
        let families: [(CGEventFlags, [CGKeyCode])] = [
            (.maskControl, [0x3B,0x3E]), (.maskAlternate, [0x3A,0x3D]),
            (.maskShift, [0x38,0x3C]), (.maskCommand, [0x37,0x36])
        ]
        for (aggregate, sides) in families where flags & aggregate.rawValue != 0 {
            let physical = sides.filter { key in
                let mask = SimulatedShortcut.modifierFlags(for: key).rawValue & 0xFFFF
                return flags & mask != 0
            }
            if !physical.isEmpty { keys += physical }
            else if event.type == .flagsChanged && sides.contains(event.keyCode) {
                // A modifier's own event identifies its side even without device flags.
                keys.append(event.keyCode)
            } else {
                let remembered = sides.filter { knownModifiers.contains($0) }
                // AppKit / synthetic events may expose only aggregate modifier flags.
                keys += remembered.isEmpty ? [sides[0]] : remembered
            }
        }
        if flags & CGEventFlags.maskSecondaryFn.rawValue != 0 { keys.append(0x3F) }
        if event.type == .keyDown && SimulatedShortcut.modifierNames[event.keyCode] == nil {
            keys.append(event.keyCode)
        }
        return keys
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        title = "从键盘录入…"
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: HoldModel
    @Environment(\.openWindow) private var openWindow
    @State private var showShortcutEditor = false
    @State private var showPermissionHelp = false
    @State private var versionClicks = 0
    @State private var lastVersionClick = Date.distantPast

    private func revealDeveloperMode() {
        let now = Date()
        versionClicks = now.timeIntervalSince(lastVersionClick) < 2 ? versionClicks + 1 : 1
        lastVersionClick = now
        if versionClicks >= 5 {
            versionClicks = 0
            model.setDeveloperMode(!model.developerMode)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mivo").font(.title2.weight(.semibold))
                    Text("用麦克风按键，控制你的输入快捷键")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("模拟方式")
                        Spacer()
                        Picker("模拟方式", selection: Binding(get: { model.simulationMode }, set: { model.configureShortcut(mode: $0) })) {
                            ForEach(SimulationMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 144)
                    }
                    HStack {
                        Text("模拟按键")
                        Spacer()
                        Menu {
                            ForEach(ShortcutPreset.allCases) { preset in
                                Button {
                                    if preset == .custom { showShortcutEditor = true }
                                    else { model.configureShortcut(preset: preset) }
                                } label: {
                                    if model.shortcutPreset == preset { Label(preset.title, systemImage: "checkmark") }
                                    else { Text(preset.title) }
                                }
                            }
                        } label: {
                            Text(model.shortcutPreset == .custom ? model.customShortcut.title : model.shortcutPreset.title)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .trailing)
                        }.frame(width: 180)
                            .popover(isPresented: $showShortcutEditor) {
                                ShortcutEditor(model: model) { showShortcutEditor = false }
                            }
                    }
                    Text(model.modeInstruction)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("结束后再按发送")
                        Spacer()
                        Text(model.simulationMode == .tap ? "仅按住模式可用" : "3 秒内发送回车")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("结束后再按发送", isOn: $model.sendOnRepress)
                            .labelsHidden().toggleStyle(.switch)
                    }.disabled(model.simulationMode == .tap)
                    Divider().padding(.vertical, 3)
                    HStack {
                        Text("显示悬浮提示")
                        Spacer()
                        Toggle("显示悬浮提示", isOn: $model.floatingVisible)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    HStack {
                        Text("显示样式")
                        Spacer()
                        Picker("显示样式", selection: $model.floatingStyle) {
                            ForEach(FloatingHUDStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 144)
                            .disabled(!model.floatingVisible)
                    }
                }.padding(10)
            } label: { Text("按键行为").font(.subheadline.weight(.medium)) }
            GroupBox {
                VStack(spacing: 14) {
                    HStack {
                        Label(model.developerMode ? "DJI Mic Mini 2（模拟）" : "DJI Mic Mini 2", systemImage: "cable.connector")
                        Spacer()
                        Text(model.receiverConnected ? "已连接" : "未连接")
                            .foregroundStyle(model.receiverConnected ? Color.green : Color.secondary)
                    }
                    Divider()
                    permissionRow("辅助功能", granted: model.systemAccessibilityOK, pane: "Privacy_Accessibility")
                    permissionRow("输入监控", granted: model.systemInputMonitorOK, pane: "Privacy_ListenEvent")
                }.padding(10)
            } label: {
                HStack {
                    Text("设备与权限").font(.subheadline.weight(.medium))
                    if model.developerMode { Text("权限为真实状态").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { showPermissionHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.plain).accessibilityLabel("权限帮助")
                        .popover(isPresented: $showPermissionHelp) { PermissionHelpView(model: model) }
                }
            }
            Text(model.selectedShortcut.includesFn ? "Fn / 🌐 为实验支持，需在目标应用中验证。" : "请在目标应用中设置相同的按键与触发方式。")
                .font(.caption).foregroundStyle(.secondary)
            if model.developerMode {
                DeveloperControls(model: model)
                HStack {
                    Button("预览菜单栏面板") { openWindow(id: "panel") }
                    Spacer()
                    Button("退出开发模式") { model.setDeveloperMode(false) }
                }.font(.caption)
            }
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "panel")
                } label: { Label("显示面板", systemImage: "macwindow") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    openWindow(id: "logs")
                } label: { Label("诊断日志", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(action: revealDeveloperMode) {
                    Text(model.developerMode ? "Mivo 1.0 · DEV" : "Mivo 1.0")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("连续点击 5 次，切换开发模式")
            }
        }
        .padding(28)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.shield" : "lock.shield")
            Spacer()
            if granted {
                Text("已开启").foregroundStyle(.green)
            } else {
                Text("未开启").foregroundStyle(.orange)
                Button("去开启") { model.openPermissionSettings(pane) }
            }
        }
    }
}

/// A passive HUD must never take keyboard focus from the editor receiving dictation.
final class FloatingActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Non-key panels need a direct pointer route: AppKit/hosting-view dispatch can
        // otherwise discard clicks or reset the cursor after tracking-area callbacks.
        if let surface = contentView as? FloatingActionSurface {
            switch event.type {
            case .leftMouseDown: surface.mouseDown(with: event); return
            case .leftMouseDragged: surface.mouseDragged(with: event); return
            case .leftMouseUp: surface.mouseUp(with: event); return
            case .rightMouseDown: surface.rightMouseDown(with: event); return
            case .mouseMoved, .cursorUpdate: surface.mouseMoved(with: event); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

final class FloatingHUDInteraction: ObservableObject {
    @Published var hovered = false
    @Published var pressed = false
    @Published var dragging = false
}

/// Keep native mouse handling outside NSHostingView's SwiftUI event routing.
class FloatingActionSurface: NSView {
    let interaction = FloatingHUDInteraction()
    var didFinishDragging: (() -> Void)?
    private var pointerStart: NSPoint?
    private var windowStart: NSPoint?
    private var tracking: NSTrackingArea?
    private var pushedCursor = false

    init(model: HoldModel) {
        super.init(frame: NSRect(origin: .zero, size: model.floatingStyle.size))
        let hosting = NSHostingView(rootView: FloatingActionView(model: model, interaction: interaction))
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The entire passive HUD is a drag surface, including its text and symbols.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        beginPointerPress(at: window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
        NSCursor.closedHand.push()
        pushedCursor = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragPointer(to: window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        endPointerPress()
        if pushedCursor { NSCursor.pop(); pushedCursor = false }
        if interaction.hovered { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    func beginPointerPress(at point: NSPoint) {
        pointerStart = point
        windowStart = window?.frame.origin
        interaction.pressed = true
    }

    func dragPointer(to point: NSPoint) {
        guard let pointerStart, let windowStart else { return }
        let dx = point.x - pointerStart.x, dy = point.y - pointerStart.y
        guard interaction.dragging || hypot(dx, dy) >= 3 else { return }
        interaction.dragging = true
        window?.setFrameOrigin(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy))
    }

    func endPointerPress() {
        let moved = interaction.dragging
        interaction.pressed = false
        interaction.dragging = false
        pointerStart = nil
        windowStart = nil
        if moved { didFinishDragging?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                 owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        interaction.hovered = true
        if !interaction.pressed { NSCursor.openHand.set() }
    }
    override func mouseMoved(with event: NSEvent) {
        if interaction.pressed { NSCursor.closedHand.set() } else { NSCursor.openHand.set() }
    }
    override func mouseExited(with event: NSEvent) {
        interaction.hovered = false
        if !interaction.pressed { NSCursor.arrow.set() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

extension Notification.Name {
    static let mivoOpenMainWindow = Notification.Name("MivoOpenMainWindow")
}

struct MivoMenuBarLabel: View {
    @ObservedObject var model: HoldModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.symbol)
            .accessibilityLabel("Mivo · \(model.title)")
            .onReceive(NotificationCenter.default.publisher(for: .mivoOpenMainWindow)) { _ in
                openWindow(id: "panel")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

final class FloatingActionController: NSObject, NSWindowDelegate {
    private let panel: FloatingActionPanel
    private let preferences: UserDefaults
    private var screenObserver: NSObjectProtocol?
    private var preferenceObserver: AnyCancellable?
    private var helpObserver: AnyCancellable?
    private var wantsVisible: Bool
    private let openMainWindow: () -> Void
    private let quitApplication: () -> Void
    private let positionKey = "floatingPanelOrigin"

    init(model: HoldModel, preferences: UserDefaults = .standard,
         openMainWindow: @escaping () -> Void = {
             NotificationCenter.default.post(name: .mivoOpenMainWindow, object: nil)
         }, quitApplication: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.preferences = preferences
        self.openMainWindow = openMainWindow
        self.quitApplication = quitApplication
        wantsVisible = model.floatingVisible
        panel = FloatingActionPanel(
            contentRect: NSRect(origin: .zero, size: model.floatingStyle.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "Mivo 悬浮提示"
        panel.identifier = NSUserInterfaceItemIdentifier("floating-actions")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        // The surface handles dragging explicitly; automatic background dragging would compete.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let surface = FloatingActionSurface(model: model)
        surface.didFinishDragging = { [weak self] in
            self?.keepOnScreen()
            if let self { self.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: self.panel)) }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "打开主窗口", action: #selector(openMainFromMenu(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "退出", action: #selector(quitFromMenu(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        surface.menu = menu
        panel.contentView = surface
        updateHelp(model: model)
        restorePosition()
        panel.delegate = self
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.keepOnScreen() }
        preferenceObserver = model.$floatingVisible.combineLatest(model.$floatingStyle)
            .dropFirst()
            .sink { [weak self] visible, style in self?.update(visible: visible, style: style) }
        helpObserver = model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in
                if let model { self?.updateHelp(model: model) }
            }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        if wantsVisible { panel.orderFrontRegardless() }
    }

    @objc private func openMainFromMenu(_ sender: NSMenuItem) { openMainWindow() }
    @objc private func quitFromMenu(_ sender: NSMenuItem) { quitApplication() }

    private func updateHelp(model: HoldModel) {
        let action = model.nextButtonAction
        let text = action == .unavailable
            ? (model.controlError == nil ? model.title : "暂时无法使用")
            : "下一次短按配对键：\(model.nextActionTitle)"
        let help = (model.developerMode ? "开发模式（模拟） · " : "") + text
        if panel.contentView?.toolTip != help { panel.contentView?.toolTip = help }
    }

    private func update(visible: Bool, style: FloatingHUDStyle) {
        wantsVisible = visible
        if panel.frame.size != style.size {
            let previous = panel.frame
            panel.setContentSize(style.size)
            // Keep the top-right corner anchored while changing between sizes.
            keepOnScreen(origin: NSPoint(x: previous.maxX - style.size.width,
                                         y: previous.maxY - style.size.height))
            windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        }
        if visible { show() } else { panel.orderOut(nil) }
    }

    private func restorePosition() {
        var origin = panel.frame.origin
        if let saved = preferences.dictionary(forKey: positionKey),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double,
           x.isFinite, y.isFinite {
            origin = NSPoint(x: x, y: y)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            origin = NSPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - 24,
                y: screen.visibleFrame.minY + 24
            )
        }
        keepOnScreen(origin: origin)
    }

    private func keepOnScreen(origin: NSPoint? = nil) {
        var frame = panel.frame
        if let origin { frame.origin = origin }
        guard let screen = NSScreen.screens.max(by: { a, b in
            let first = a.visibleFrame.intersection(frame)
            let second = b.visibleFrame.intersection(frame)
            return (first.isNull ? 0 : first.width * first.height)
                < (second.isNull ? 0 : second.width * second.height)
        }) else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width)),
            y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        ))
    }

    func windowDidMove(_ notification: Notification) {
        preferences.set(["x": panel.frame.origin.x, "y": panel.frame.origin.y], forKey: positionKey)
    }
}

struct FloatingActionView: View {
    @ObservedObject var model: HoldModel
    @ObservedObject var interaction: FloatingHUDInteraction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var action: NextButtonAction { model.nextButtonAction }
    private var tint: Color {
        switch action {
        case .unavailable: return .secondary
        case .startListening, .tapShortcut: return .blue
        case .stopListening: return .orange
        case .sendReturn: return .green
        }
    }
    private var actionTitle: String {
        if action == .unavailable { return model.controlError == nil ? model.title : "暂时无法使用" }
        return model.nextActionTitle
    }

    var body: some View {
        Group {
            if model.floatingStyle == .mini { mini } else { standard }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.developerMode ? "模拟，" : "")下一次短按配对键：\(actionTitle)")
        .accessibilityValue(action == .sendReturn ? "剩余 \(String(format: "%.1f", model.sendRemaining)) 秒" : "")
        .scaleEffect(interaction.dragging ? 0.96 : interaction.pressed ? 0.92 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction.pressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction.dragging)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction.hovered)
    }

    private var mini: some View {
        Image(systemName: action == .unavailable ? model.symbol : action.symbol)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(tint)
            .offset(y: model.developerMode ? -4 : 0)
            .frame(width: 44, height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(tint.opacity(interaction.hovered || interaction.dragging ? 0.13 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if action == .sendReturn {
                    RoundedRectangle(cornerRadius: 13).inset(by: 1)
                        .stroke(tint.opacity(0.12), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 13).inset(by: 1)
                        .trim(from: 0, to: min(1, max(0, model.sendRemaining / sendWindow)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: model.sendRemaining)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(interaction.hovered || interaction.dragging ? tint.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if model.developerMode {
                    Text("DEV").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint).padding(.bottom, 2)
                }
            }
    }

    private var standard: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(90)).frame(width: 10)
            Image(systemName: action == .unavailable ? model.symbol : action.symbol)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 42, height: 46)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.developerMode ? "模拟 · 下次短按配对键" : "下一次短按配对键")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(actionTitle).font(.system(size: 18, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if action != .unavailable {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(action == .sendReturn ? "可发送" : model.title)
                        .font(.system(size: 11)).foregroundStyle(tint)
                    if action == .sendReturn {
                        Text("\(model.sendRemaining, specifier: "%.1f") 秒")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(model.developerMode ? "DEV" : "短按")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 9).padding(.trailing, 16)
        .frame(width: 300, height: 82)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if action == .sendReturn {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        tint.opacity(0.10)
                        tint.frame(width: geometry.size.width * min(1, max(0, model.sendRemaining / sendWindow)))
                    }
                }.frame(height: 3).padding(.horizontal, 18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(interaction.hovered || interaction.dragging ? tint.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingActions: FloatingActionController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HoldModel.shared.startWatching()
        floatingActions = FloatingActionController(model: HoldModel.shared)
        floatingActions?.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        HoldModel.shared.reconcile()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingActions?.show()
        NSApp.windows.first { $0.title == "Mivo 面板" }?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HoldModel.shared.stopControl()
    }
}

@main
struct HoldMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = HoldModel.shared

    var body: some Scene {
        Window("Mivo 面板", id: "panel") {
            StatusPanel(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
        }

        Window("Mivo 设置", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Mivo 诊断日志", id: "logs") {
            LogPanelView(model: model)
        }
        .defaultSize(width: 520, height: 380)

        MenuBarExtra {
            StatusPanel(model: model)
        } label: {
            MivoMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }.keyboardShortcut(",", modifiers: .command)
    }
}

/// Mic Mini 2 transmitter, matching the approved textured front and side-button design.
struct MicMini2Guide: View {
    @ObservedObject var model: HoldModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showGuide = false
    @State private var feedbackFlash = false

    private var pressed: Bool { model.pairingKeyDown || feedbackFlash }
    private var listening: Bool { model.controlling && model.phase == .holding }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("DJI Mic Mini 2")
                Spacer()
                Label(model.receiverConnected ? "已连接" : "未连接", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(model.receiverConnected ? Color.green : Color.secondary)
            }.font(.caption).foregroundStyle(.secondary)
            ZStack {
                transmitter
                    .rotationEffect(.degrees(-5))
                    .offset(y: pressed && !reduceMotion ? 2 : 0)
                    .opacity(model.controlEnabled ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("配对键").font(.caption.weight(.medium))
                        Rectangle().frame(width: 21, height: 1)
                    }.foregroundStyle(Color.accentColor)
                    Text(model.developerMode ? "点击模拟" : "短按这里")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).offset(y: -24)
                HStack(spacing: 7) {
                    Text("电源键").font(.caption2)
                    Rectangle().frame(width: 26, height: 1).opacity(0.4)
                }.foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).offset(y: 33)
                Text("麦克风发射器 · 侧面按钮示意")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }.frame(height: 156)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: listening)
        .task(id: model.buttonEventCount) {
            feedbackFlash = false
            guard model.buttonEventCount > 0,
                  ProcessInfo.processInfo.systemUptime - model.lastHIDAt < 0.25 else { return }
            feedbackFlash = true
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            feedbackFlash = false
        }
        .onReceive(model.$controlling) { active in
            if !active { feedbackFlash = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DJI Mic Mini 2 麦克风发射器按钮示意")
    }

    private var transmitter: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.43))
                .frame(width: 25, height: 84).offset(x: -5, y: 22)
            RoundedRectangle(cornerRadius: 27)
                .fill(LinearGradient(colors: [Color(white: 0.68), Color(white: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 27)
                        .stroke(Color.accentColor.opacity(listening ? 0.18 : 0), lineWidth: 7)
                }
                .frame(width: 114, height: 114).offset(x: 23, y: 4)
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(white: 0.29), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { MicFrontTexture().clipShape(RoundedRectangle(cornerRadius: 23)) }
                .overlay {
                    RoundedRectangle(cornerRadius: 23).strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                }
                .overlay {
                    Text("DJ").font(.system(size: 39, weight: .heavy)).italic()
                        .tracking(-3).foregroundStyle(Color(white: 0.95))
                }
                .frame(width: 104, height: 104).offset(x: 28, y: 9)
            RoundedRectangle(cornerRadius: 13)
                .fill(LinearGradient(colors: [Color(white: 0.46), Color(white: 0.64)], startPoint: .leading, endPoint: .trailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 13).strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
                .frame(width: 32, height: 101).offset(x: 2, y: 13)
            Capsule().fill(Color(white: 0.2)).frame(width: 4, height: 6).offset(x: 13, y: 20)
            Button {
                if model.developerMode {
                    model.simulatePress()
                } else {
                    showGuide = true
                }
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium)).rotationEffect(.degrees(90))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 27)
                    .background(pressed ? Color(red: 0.5, green: 0.75, blue: 1) : Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.accentColor.opacity(pressed ? 0.4 : 0.2), lineWidth: pressed ? 7 : 4)
                            .padding(-3)
                    }
                    .frame(width: 40, height: 39)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -2 + (pressed && !reduceMotion ? 2 : 0), y: 31)
            .accessibilityLabel(model.developerMode ? "模拟短按麦克风配对键" : "麦克风配对键操作说明")
            .accessibilityValue(model.pairingKeyDown ? "按下" : "松开")
            .popover(isPresented: $showGuide) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("短按麦克风侧面配对键").font(.headline)
                    Text(model.guideInstruction)
                    Text("操作发射器上带链环标记的键；下方为电源键。请短按，不要长按进入配对。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(width: 280)
            }
            Image(systemName: "power").font(.system(size: 10))
                .foregroundStyle(Color(white: 0.83))
                .frame(width: 20, height: 25)
                .background(Color(white: 0.46), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                .offset(x: 8, y: 77)
                .accessibilityLabel("电源键，无需操作")
        }
        .frame(width: 137, height: 123)
        .shadow(color: .black.opacity(0.15), radius: 5, x: 3, y: 6)
    }
}

struct MicFrontTexture: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<580 {
                let x = CGFloat((index * 37) % 997) / 997 * size.width
                let y = CGFloat((index * 71) % 991) / 991 * size.height
                let dot = CGRect(x: x, y: y, width: 0.65, height: 0.65)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.12)))
            }
        }
        .accessibilityHidden(true)
    }
}

struct PermissionHelpView: View {
    @ObservedObject var model: HoldModel
    @State private var confirmRepair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("权限不生效？").font(.headline)
            Text("这里检测当前 Mivo 进程的权限，不读取系统设置开关的外观。更新版本后，旧授权可能与新签名不匹配。")
                .font(.subheadline)
            Text("先重启重新检测；若仍不一致，在系统设置中移除旧 Mivo，再添加当前应用。")
                .font(.subheadline)
            Text(Bundle.main.bundleURL.path)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("在访达中显示") { model.revealApplication() }
                Button("重新检测") { model.reconcile() }
            }
            HStack {
                Button("重启 Mivo") { model.restartForPermissionCheck() }
                Button("修复辅助功能授权…") { confirmRepair = true }
                    .disabled(model.repairingPermission)
            }
            if !model.permissionRepairMessage.isEmpty {
                Text(model.permissionRepairMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 340)
        .alert("清理 Mivo 的旧辅助功能授权？", isPresented: $confirmRepair) {
            Button("取消", role: .cancel) {}
            Button("清理并重新授权", role: .destructive) { model.repairAccessibilityPermission() }
        } message: {
            Text("仅重置 Mivo 的辅助功能授权，不影响其他应用和输入监控。之后需要你在系统设置中重新开启当前 Mivo，再重启应用。")
        }
    }
}
