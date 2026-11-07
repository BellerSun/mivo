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
let rightCommand: Int64 = 0x36
let returnKey: CGKeyCode = 0x24
let samePressWindow: TimeInterval = 0.05
let sendWindow: TimeInterval = 3

enum Phase: String {
    case idle = "空闲"
    case holding = "监听中"
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
}

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
        next += sources.sorted().map { [mappingSource: $0, mappingDestination: 0x7000000E7] }
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

func postReturn() {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func releaseStuckCommand() {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(rightCommand), keyDown: false) else { return }
    up.type = .flagsChanged
    up.flags = []
    up.setIntegerValueField(.keyboardEventKeycode, value: rightCommand)
    up.post(tap: .cghidEventTap)
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
    case unavailable, startListening, stopListening, sendReturn

    var title: String {
        switch self {
        case .unavailable: return "暂不可用"
        case .startListening: return "开始监听"
        case .stopListening: return "结束监听"
        case .sendReturn: return "发送回车"
        }
    }

    var symbol: String {
        switch self {
        case .unavailable: return "exclamationmark.circle"
        case .startListening: return "mic"
        case .stopListening: return "stop"
        case .sendReturn: return "return"
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
    var passUp = false
    var held: [UInt32: Bool] = [:]
    lazy var receiverMappings = ReceiverKeyMappings()
    var manager: IOHIDManager?
    var keyTap: CFMachPort?
    var timer: Timer?
    var countdownTimer: Timer?
    var tapSource: CFRunLoopSource?

    init(preferences: UserDefaults = .standard,
         developerMode: Bool = ProcessInfo.processInfo.arguments.contains("--dev"),
         permissionProbe: @escaping () -> SystemPermissions = SystemPermissions.current) {
        self.permissionProbe = permissionProbe
        self.preferences = preferences
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
    var canSend: Bool { controlling && phase == .released && sendOnRepress && sendRemaining > 0 }
    var nextButtonAction: NextButtonAction {
        guard receiverConnected, accessibilityOK, inputMonitorOK, controlEnabled,
              controlling, controlError == nil else { return .unavailable }
        if phase == .holding { return .stopListening }
        return canSend ? .sendReturn : .startListening
    }
    var title: String {
        if !receiverConnected { return "等待接收器" }
        if !accessibilityOK || !inputMonitorOK { return "还需完成授权" }
        if !controlEnabled { return "已暂停" }
        if !controlling { return "暂时无法使用" }
        if phase == .holding { return "正在监听" }
        if phase == .released { return "监听已结束" }
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
        if phase == .holding { return "短按高亮配对键，结束监听" }
        if canSend { return "3 秒内再短按高亮键，发送回车" }
        return "短按高亮配对键，开始监听"
    }

    var hint: String {
        if !receiverConnected { return "连接接收器后自动就绪" }
        if !accessibilityOK || !inputMonitorOK { return "开启辅助功能和输入监控" }
        if !controlEnabled { return "开启控制后恢复使用" }
        if !controlling { return "请重试，或查看诊断日志" }
        if phase == .holding { return "再按一下，结束语音输入" }
        if canSend { return "再按一下，发送回车" }
        return "按一下接收器，开始语音输入"
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

    func simulatePress() {
        guard developerMode, controlling else { return }
        handleHID(page: consumerPage, usage: volumeIncrement, value: 1)
        handleHID(page: consumerPage, usage: volumeIncrement, value: 0)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(rightCommand), keyDown: down) else { continue }
            event.type = .flagsChanged
            event.flags = down ? .maskCommand : []
            let swallowed = handleCommand(event)
            note("[模拟] 右 Command \(down ? "按下" : "松开") · \(swallowed ? "拦截" : "放行")")
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
        note(sendOnRepress
            ? "已开启。短按开始，再短按结束，3 秒内再按发送。"
            : "已开启。短按开始，再短按结束。")
    }

    func restoreReceiverMappings() {
        do {
            if try !receiverMappings.restore() { note("检测到外部按键映射变更，已保留外部设置。") }
        } catch {
            note("恢复原按键映射失败：\(error.localizedDescription)。请暂停后重试。")
        }
    }

    func stopControl() {
        if gesture == .holding {
            if developerMode { note("[模拟] 释放右 Command") } else { releaseStuckCommand() }
        }
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
        passUp = false
        controlling = false
        refreshPermissions()
        note("已暂停。")
    }

    @discardableResult
    func installTap() -> Bool {
        guard !developerMode else { return true }
        if keyTap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
                if HoldModel.shared.handleCommand(event) {
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
        switch gesture {
        case .holding:
            gesture = .released
            releasedAt = now
            pending = .release
            publish(.released, "松开，结束监听")
        case .released where sendOnRepress && now - releasedAt <= sendWindow:
            gesture = .idle
            pending = .send
            publish(.idle, "发送回车")
        default:
            gesture = .holding
            pending = .holdDown
            publish(.holding, "按下，开始监听")
        }
    }

    func handleCommand(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == rightCommand else { return false }
        let isDown = event.flags.contains(.maskCommand)
        if !isDown {
            if swallowUp {
                swallowUp = false
                return true
            }
            if passUp {
                passUp = false
                return false
            }
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastHIDAt > 0, now - lastHIDAt < 0.3, let action = pending else { return false }
        pending = nil
        switch action {
        case .holdDown:
            swallowUp = true
            return false
        case .release:
            passUp = true
            return true
        case .send:
            swallowUp = true
            if developerMode {
                note("[模拟] 发送回车（未向系统发送）")
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.developerMode, self.controlling else { return }
                    postReturn()
                }
            }
            return true
        }
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
                             ? "右 Command 保持按下"
                             : "千问 · 按住监听 · 右 Command")
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

struct SettingsView: View {
    @ObservedObject var model: HoldModel
    @Environment(\.openWindow) private var openWindow
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
                    Text("用接收器按键，轻松开始语音输入")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("结束后再按发送")
                        Spacer()
                        Toggle("结束后再按发送", isOn: $model.sendOnRepress)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Text("结束监听后，3 秒内再次按键发送回车。关闭后，再次按键开始新的语音输入。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            Text("千问需设为「按住监听」，快捷键为右 Command。")
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
            : "下一次短按配对键：\(action.title)"
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
        case .startListening: return .blue
        case .stopListening: return .orange
        case .sendReturn: return .green
        }
    }
    private var actionTitle: String {
        if action == .unavailable { return model.controlError == nil ? model.title : "暂时无法使用" }
        return action.title
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
