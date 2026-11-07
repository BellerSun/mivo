import Foundation

@main
struct HoldModelTests {
    static func main() {
        testMappingPreservation()
        let domain = "local.mivo.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        var permissions = SystemPermissions(accessibility: false, inputMonitoring: false)
        let model = HoldModel(preferences: preferences, developerMode: true, permissionProbe: { permissions })
        check(model.floatingVisible && model.floatingStyle == .mini, "悬浮提示默认显示迷你图标方块")
        model.floatingVisible = false
        model.floatingStyle = .standard
        let savedHUD = HoldModel(preferences: preferences, developerMode: true)
        check(!savedHUD.floatingVisible && savedHUD.floatingStyle == .standard, "悬浮显示开关与样式独立保存")
        check(model.controlEnabled, "隐藏悬浮提示不影响麦克风控制开关")
        model.floatingVisible = true
        model.floatingStyle = .mini
        model.reconcile()
        check(!model.systemAccessibilityOK && !model.systemInputMonitorOK && model.accessibilityOK && model.inputMonitorOK,
              "模拟授权不会把真实系统权限显示成已开启")
        permissions = SystemPermissions(accessibility: true, inputMonitoring: false)
        model.reconcile()
        check(model.systemAccessibilityOK && !model.systemInputMonitorOK, "系统权限可独立刷新")
        permissions = SystemPermissions(accessibility: true, inputMonitoring: true)
        model.reconcile()
        check(model.systemAccessibilityOK && model.systemInputMonitorOK, "开启真实权限后检测结果更新")
        let realModel = HoldModel(preferences: preferences, developerMode: false, permissionProbe: { permissions })
        realModel.refreshPermissions()
        check(realModel.accessibilityOK && realModel.inputMonitorOK, "真实模式采用系统检测结果")
        permissions = SystemPermissions(accessibility: false, inputMonitoring: false)
        realModel.refreshPermissions()
        check(!realModel.accessibilityOK && !realModel.inputMonitorOK, "关闭真实权限后检测结果更新")
        check(model.controlling && model.title == "已就绪", "模拟模式无需硬件和权限即可就绪")
        check(model.manager == nil && model.keyTap == nil, "模拟模式不安装 HID 管理器和系统按键拦截")
        check(model.nextButtonAction == .startListening, "就绪时悬浮提示下一次开始监听")
        press(model)
        check(model.phase == .holding && model.swallowUp == false, "第一次按键维持逻辑按下并吞掉松开事件")
        check(model.nextButtonAction == .stopListening, "监听中悬浮提示下一次结束监听")
        press(model)
        check(model.phase == .released && model.canSend, "第二次按键结束并开启发送窗口")
        check(model.nextButtonAction == .sendReturn, "发送窗口内悬浮提示下一次发送回车")
        press(model)
        check(model.phase == .idle && model.logs.contains { $0.contains("发送回车（未向系统发送）") }, "第三次按键只记录回车输出")

        model.sendOnRepress = false
        check(model.nextButtonAction == .startListening, "关闭发送设置后悬浮提示不显示发送")
        check(!HoldModel(preferences: preferences, developerMode: true).sendOnRepress, "关闭发送设置持久化")
        press(model); press(model); press(model)
        check(model.phase == .holding, "关闭再按发送立即生效，再按开始新的监听")
        model.sendOnRepress = true
        press(model)
        check(model.canSend, "重新开启设置立即恢复发送窗口")
        model.tick(now: model.releasedAt + sendWindow + 0.1)
        check(model.phase == .idle && !model.canSend, "窗口到期清除已结束状态")
        check(model.nextButtonAction == .startListening, "倒计时结束后悬浮提示恢复开始监听")
        press(model)
        check(model.phase == .holding, "窗口到期后再次按键开始监听")

        model.setControlEnabled(false)
        model.reconcile(); model.simulatePress()
        check(!model.controlling && model.phase == .idle && model.title == "已暂停", "暂停后轮询和模拟按键均不会重新开启")
        check(model.held.isEmpty && model.pending == nil, "停止时清空按键和待处理动作")
        check(model.nextButtonAction == .unavailable, "暂停时悬浮提示不提供可执行动作")
        let restored = HoldModel(preferences: preferences, developerMode: true)
        restored.reconcile()
        check(!restored.controlEnabled && !restored.controlling && restored.sendOnRepress, "偏好设置在重新创建模型后保留")

        model.setControlEnabled(true)
        press(model)
        model.simulatedDevice = .disconnected
        check(!model.controlling && model.phase == .idle && model.title == "等待接收器", "监听时模拟断连释放状态")
        check(model.nextButtonAction == .unavailable, "断连时悬浮提示不保留结束或发送动作")
        model.simulatedDevice = .ready
        check(model.controlling && model.title == "已就绪", "模拟重连后自动恢复")
        press(model)
        model.simulatedDevice = .needsPermissions
        check(!model.controlling && !model.accessibilityOK && model.title == "还需完成授权", "权限不可用时停止控制")
        check(model.nextButtonAction == .unavailable, "权限不足时悬浮提示不提供动作")
        model.simulatedDevice = .ready
        check(model.controlling, "模拟授权后恢复控制")
        model.controlError = "test failure"
        check(model.nextButtonAction == .unavailable, "控制异常时悬浮提示不提供动作")
        model.controlError = nil
        model.simulatedDevice = .disconnected
        model.setControlEnabled(false)
        model.setControlEnabled(true)
        check(model.controlEnabled && !model.controlling, "未连接时控制开关仍可修改启用偏好")
        model.simulatedDevice = .ready
        check(model.controlling, "离线启用后连接即恢复控制")
        check(model.guideInstruction.contains("开始监听"), "就绪指引高亮配对键开始监听")
        press(model)
        check(model.guideInstruction.contains("结束监听"), "监听指引随真实状态更新")
        press(model)
        check(model.guideInstruction.contains("发送回车"), "发送窗口指引随真实状态更新")
        model.sendOnRepress = false
        check(model.guideInstruction.contains("开始监听"), "关闭发送立即更新操作指引")
        check(model.nextButtonAction == .startListening, "结束后关闭发送设置，悬浮提示立即跳过发送")

        model.setControlEnabled(false)
        model.setDeveloperMode(false)
        model.setDeveloperMode(true)
        check(model.developerMode && !model.controlling && model.manager == nil && model.keyTap == nil, "切换开发模式不覆盖暂停选择")
        preferences.set(true, forKey: "controlEnabled")
        let feedback = HoldModel(preferences: preferences, developerMode: true)
        feedback.reconcile()
        feedback.handleHID(page: 0, usage: volumeIncrement, value: 1)
        check(!feedback.pairingKeyDown && feedback.buttonEventCount == 0, "非目标事件不触发设备动画")
        feedback.handleHID(page: consumerPage, usage: volumeIncrement, value: 1)
        check(feedback.pairingKeyDown && feedback.buttonEventCount == 1, "HID 按下驱动按钮外观与一次反馈")
        feedback.handleHID(page: consumerPage, usage: volumeIncrement, value: 1)
        feedback.handleHID(page: consumerPage, usage: volumeDecrement, value: 1)
        check(feedback.buttonEventCount == 1 && feedback.phase == .holding, "重复报告和同次双音量事件不重复触发手势")
        feedback.handleHID(page: consumerPage, usage: volumeIncrement, value: 0)
        check(feedback.pairingKeyDown, "同次按键仍有通道按下时不提前回弹")
        feedback.handleHID(page: consumerPage, usage: volumeDecrement, value: 0)
        check(!feedback.pairingKeyDown && feedback.phase == .holding, "松开只回弹按钮，不结束逻辑监听")
        press(feedback)
        check(!feedback.pairingKeyDown && feedback.buttonEventCount == 2 && feedback.phase == .released,
              "开发模式走相同按下松开反馈流程")
        feedback.lastHIDAt = 0
        feedback.handleHID(page: consumerPage, usage: volumeIncrement, value: 1)
        feedback.stopControl()
        check(!feedback.pairingKeyDown, "停止控制清除按钮按下外观")
        print("全部 HoldModel 行为检查通过。")
    }

    static func testMappingPreservation() {
        let custom: KeyMappings = [
            [mappingSource: 0xC000000E9, mappingDestination: 0x700000004],
            [mappingSource: 0x700000005, mappingDestination: 0x700000006],
        ]
        var current = custom
        let lease = KeyMappingLease(read: { current }, write: { current = $0 })
        do {
            try lease.apply()
            check(current.count == 3 && current.contains(custom[1]), "控制期间保留无关映射，仅替换目标音量键")
            check(tryRestore(lease) && current == custom, "停止后恢复包含自定义音量键的原始映射")
            try lease.apply()
            current = [[mappingSource: 1, mappingDestination: 2]]
            check(!tryRestore(lease) && current == [[mappingSource: 1, mappingDestination: 2]],
                  "外部修改优先，不用旧快照覆盖其他工具")
            current = []
            try lease.apply()
            check(tryRestore(lease) && current.isEmpty, "原来无映射时恢复为空")
            current = custom
            var failRestore = false
            let retry = KeyMappingLease(read: { current }, write: {
                if failRestore { throw MappingError(message: "injected failure") }
                current = $0
            })
            try retry.apply()
            failRestore = true
            do { _ = try retry.restore(); fatalError("FAIL: expected restore failure") } catch {}
            failRestore = false
            check(tryRestore(retry) && current == custom, "恢复失败保留快照，后续重试仍能恢复")
            let unreadable = KeyMappingLease(read: { throw MappingError(message: "unreadable") },
                                             write: { _ in fatalError("FAIL: wrote without snapshot") })
            do { try unreadable.apply(); fatalError("FAIL: expected read failure") } catch {}
            check(current == custom, "无法读取原映射时拒绝写入")
        } catch { fatalError("FAIL: mapping preservation: \(error)") }
    }

    static func tryRestore(_ lease: KeyMappingLease) -> Bool {
        do { return try lease.restore() } catch { fatalError("FAIL: restore: \(error)") }
    }

    static func press(_ model: HoldModel) {
        model.lastHIDAt = 0 // Avoid waiting for physical-switch debounce in deterministic tests.
        model.simulatePress()
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }
}
