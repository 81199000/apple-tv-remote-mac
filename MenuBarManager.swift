//
//  MenuBarManager.swift
//  Remotastic
//
//  Manages the menu bar icon and menu
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable {
    case none = "None"
    case playPause = "Play/Pause"
    case nextTrack = "Next Track"
    case previousTrack = "Previous Track"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case mute = "Mute"
    case click = "Mouse Click"
    case rightClick = "Right Click"
    case escape = "Escape"
    case space = "Space"
    case enter = "Enter"
    case missionControl = "Mission Control"

    var displayName: String {
        switch self {
        case .none: return "无操作"
        case .playPause: return "播放／暂停"
        case .nextTrack: return "下一曲"
        case .previousTrack: return "上一曲"
        case .volumeUp: return "增大音量"
        case .volumeDown: return "减小音量"
        case .mute: return "静音"
        case .click: return "鼠标左键"
        case .rightClick: return "鼠标右键"
        case .escape: return "Esc 键"
        case .space: return "空格键"
        case .enter: return "回车键"
        case .missionControl: return "调度中心"
        }
    }
}

// Scroll speed options
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var displayName: String {
        switch self {
        case .slow: return "慢"
        case .medium: return "中"
        case .fast: return "快"
        }
    }
    
    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }
}

enum CursorSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var displayName: String {
        switch self {
        case .slow: return "慢"
        case .medium: return "中"
        case .fast: return "快"
        }
    }

    var scale: CGFloat {
        switch self {
        case .slow: return 250.0
        case .medium: return 500.0
        case .fast: return 900.0
        }
    }
}

class MenuBarManager {
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let permissionMenuItem: NSMenuItem
    private var permissionTimer: Timer?
    
    // Button mappings (stored in UserDefaults)
    // Values are either a ButtonAction raw value or "key:<keyCode>:<flags>".
    // Keeping this string format makes existing preferences backward compatible
    // while allowing any keyboard key or key combination to be recorded.
    private var buttonMappings: [String: String] = [:]
    
    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium
    private(set) var cursorSpeed: CursorSpeed = .medium

    var keyPressFeedbackEnabled: Bool {
        get { CursorController.feedbackEnabled }
        set { CursorController.feedbackEnabled = newValue }
    }
    
    // Callback for when mappings change
    var onMappingsChanged: (([String: String]) -> Void)?
    var onSettingsChanged: (() -> Void)?
    
    /// Set by app delegate so menu bar can delegate media actions to MediaController (one path for CLI and app).
    var mediaController: MediaController?
    
    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "连接状态：未连接", action: nil, keyEquivalent: "")
        self.permissionMenuItem = NSMenuItem(title: "辅助功能权限：正在检查…", action: nil, keyEquivalent: "")
        
        loadMappings()
        loadSettings()
        setupMenuBar()
        startPermissionMonitor()
    }

    private func loadSettings() {
        if let raw = UserDefaults.standard.string(forKey: "cursorSpeed"),
           let saved = CursorSpeed(rawValue: raw) {
            cursorSpeed = saved
        } else {
            UserDefaults.standard.set(cursorSpeed.rawValue, forKey: "cursorSpeed")
        }
    }
    
    private func loadMappings() {
        // Default mappings (only used on first launch)
        let defaultMappings: [String: String] = [
            "playPause": ButtonAction.playPause.rawValue,
            "menu": ButtonAction.missionControl.rawValue,
            "select": ButtonAction.click.rawValue,
            "volumeUp": ButtonAction.volumeUp.rawValue,
            "volumeDown": ButtonAction.volumeDown.rawValue,
            "siri": keyboardMapping(keyCode: UInt16(kVK_RightCommand), flags: .command),
            "tv": keyboardMapping(keyCode: UInt16(kVK_Delete), flags: [])
        ]
        
        // Load saved mappings from UserDefaults
        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            // User has saved mappings - use those (migrate old "Toggle Trackpad Mode" to .escape)
            for (button, actionRaw) in saved {
                if ButtonAction(rawValue: actionRaw) != nil || parseKeyboardMapping(actionRaw) != nil {
                    buttonMappings[button] = actionRaw
                } else if actionRaw == "Toggle Trackpad Mode" {
                    buttonMappings[button] = ButtonAction.escape.rawValue
                }
            }
            // Fill in any missing buttons with defaults
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            // One-time migration: Menu was default Escape; prefer Mission Control for Expose
            if buttonMappings["menu"] == ButtonAction.escape.rawValue {
                buttonMappings["menu"] = ButtonAction.missionControl.rawValue
                saveMappings()
            }

            // Apply the user's requested mappings once when upgrading from the
            // upstream defaults. Later choices made in the menu are preserved.
            if buttonMappings["siri"] == ButtonAction.space.rawValue ||
               buttonMappings["siri"] == ButtonAction.nextTrack.rawValue {
                buttonMappings["siri"] = defaultMappings["siri"]
            }
            if buttonMappings["tv"] == ButtonAction.rightClick.rawValue {
                buttonMappings["tv"] = defaultMappings["tv"]
            }
            saveMappings()
        } else {
            // First launch - use defaults
            buttonMappings = defaultMappings
            saveMappings() // Save defaults immediately
        }
    }
    
    private func saveMappings() {
        UserDefaults.standard.set(buttonMappings, forKey: "buttonMappings")
        onMappingsChanged?(buttonMappings)
    }
    
    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }
        
        button.title = "SR"
        
        // Try SF Symbol if available
        if #available(macOS 11.0, *) {
            let symbolNames = ["appletvremote.gen4", "tv.and.mediabox", "remote"]
            for name in symbolNames {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Siri 遥控器") {
                    image.isTemplate = true
                    button.image = image
                    button.title = ""
                    break
                }
            }
        }
        
        rebuildMenu()
        statusItem.menu = menu
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Siri 遥控器助手", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        refreshPermissionStatus()
        menu.addItem(permissionMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Button Mappings submenu
        let mappingsItem = NSMenuItem(title: "按键映射", action: nil, keyEquivalent: "")
        let mappingsSubmenu = NSMenu()
        
        let buttons = [
            ("playPause", "播放／暂停键"),
            ("menu", "菜单键"),
            ("select", "触控板按压"),
            ("volumeUp", "音量加键"),
            ("volumeDown", "音量减键"),
            ("tv", "TV 键"),
            ("siri", "Siri 键")
        ]
        
        for (key, label) in buttons {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()
            
            for action in ButtonAction.allCases {
                let actionItem = NSMenuItem(title: action.displayName, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = [key, action.rawValue]
                
                // Mark current selection
                if buttonMappings[key] == action.rawValue {
                    actionItem.state = .on
                }
                
                actionSubmenu.addItem(actionItem)
            }

            actionSubmenu.addItem(NSMenuItem.separator())

            if let current = buttonMappings[key], parseKeyboardMapping(current) != nil {
                let currentItem = NSMenuItem(title: "当前键盘映射：\(keyboardMappingDisplayName(current))", action: nil, keyEquivalent: "")
                currentItem.isEnabled = false
                currentItem.state = .on
                actionSubmenu.addItem(currentItem)
            }

            let recordItem = NSMenuItem(title: "录制任意键或组合键…", action: #selector(recordKeyboardMapping(_:)), keyEquivalent: "")
            recordItem.target = self
            recordItem.representedObject = key
            actionSubmenu.addItem(recordItem)
            
            buttonItem.submenu = actionSubmenu
            mappingsSubmenu.addItem(buttonItem)
        }
        
        mappingsItem.submenu = mappingsSubmenu
        menu.addItem(mappingsItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsSubmenu = NSMenu()

        let soundItem = NSMenuItem(title: "按键音效", action: #selector(toggleKeyPressFeedback(_:)), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = keyPressFeedbackEnabled ? .on : .off
        settingsSubmenu.addItem(soundItem)

        let cursorSpeedItem = NSMenuItem(title: "触控板鼠标速度", action: nil, keyEquivalent: "")
        let cursorSpeedSubmenu = NSMenu()
        for speed in CursorSpeed.allCases {
            let item = NSMenuItem(title: speed.displayName, action: #selector(changeCursorSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed.rawValue
            item.state = speed == cursorSpeed ? .on : .off
            cursorSpeedSubmenu.addItem(item)
        }
        cursorSpeedItem.submenu = cursorSpeedSubmenu
        settingsSubmenu.addItem(cursorSpeedItem)

        let launchItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        settingsSubmenu.addItem(launchItem)

        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "退出遥控器助手", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func changeMapping(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else {
            return
        }
        buttonMappings[values[0]] = values[1]
        saveMappings()
        rebuildMenu()
    }

    @objc private func toggleKeyPressFeedback(_ sender: NSMenuItem) {
        keyPressFeedbackEnabled.toggle()
        onSettingsChanged?()
        rebuildMenu()
    }

    @objc private func changeCursorSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let speed = CursorSpeed(rawValue: raw) else { return }
        cursorSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "cursorSpeed")
        onSettingsChanged?()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let desiredState = !LaunchAtLoginManager.isEnabled
        _ = LaunchAtLoginManager.setEnabled(desiredState)
        rebuildMenu()
    }

    @objc private func recordKeyboardMapping(_ sender: NSMenuItem) {
        guard let buttonKey = sender.representedObject as? String else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "录制键盘映射"
        alert.informativeText = "请按下要映射的单个按键或组合键。\n支持字母、数字、功能键、方向键、Delete，以及 Command／Option／Control／Shift 组合。"
        alert.addButton(withTitle: "取消")

        var captured = false
        var candidateKeyCode: UInt16?
        var candidateFlags: NSEvent.ModifierFlags = []
        var pressedKeys = Set<UInt16>()
        var monitor: Any?

        // Do not save on the first key-down. Keep collecting the chord and
        // commit it only after every key has been released.
        func finishRecording() {
            guard !captured, let keyCode = candidateKeyCode else { return }
            captured = true
            self.buttonMappings[buttonKey] = self.keyboardMapping(keyCode: keyCode, flags: candidateFlags)
            self.saveMappings()
            self.rebuildMenu()
            alert.window.orderOut(nil)
            NSApp.abortModal()
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard !captured else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch event.type {
            case .keyDown:
                let keyCode = event.keyCode
                pressedKeys.insert(keyCode)
                if !Self.isModifierKeyCode(keyCode) {
                    // A normal key is the main key; modifier flags retain all
                    // Command/Option/Control/Shift keys held at that moment.
                    candidateKeyCode = keyCode
                    candidateFlags = flags
                }
                return nil

            case .keyUp:
                pressedKeys.remove(event.keyCode)
                if !pressedKeys.contains(where: { !Self.isModifierKeyCode($0) }) && flags.isEmpty {
                    finishRecording()
                }
                return nil

            case .flagsChanged:
                if Self.isModifierKeyCode(event.keyCode) {
                    if !flags.isEmpty {
                        // Modifier-only mappings are supported as well. A later
                        // normal key-down replaces this candidate.
                        if candidateKeyCode == nil {
                            candidateKeyCode = event.keyCode
                            candidateFlags = flags
                        }
                    } else if pressedKeys.isEmpty {
                        finishRecording()
                    }
                    return nil
                }
                return event

            default:
                return event
            }
        }

        _ = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMenuItem.title = connected ? "连接状态：已连接 ✓" : "连接状态：未连接"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }
    
    func getMapping(for button: String) -> String {
        return buttonMappings[button] ?? ButtonAction.none.rawValue
    }
    
    // Map HID codes to button names
    private let hidCodeToButton: [String: String] = [
        "0x000C:0x00CD": "playPause",    // Play/Pause
        "0x000C:0x00B5": "nextTrack",    // Next (not a physical button but for mapping)
        "0x000C:0x00B6": "prevTrack",    // Previous (not a physical button but for mapping)
        "0x000C:0x00E9": "volumeUp",     // Volume Up
        "0x000C:0x00EA": "volumeDown",   // Volume Down
        "0x0001:0x0086": "menu",         // Menu button (System Menu Main)
        "0x000C:0x0080": "select",       // Select button
        "0x000C:0x0040": "menu",         // Menu (alternate)
        "0x000C:0x0223": "menu",         // Home
        "0x000C:0x0224": "back",         // Back
    ]
    
    /// Get the action name for a given HID code (for event interception)
    func getMappingForHIDCode(_ hidCode: String) -> String? {
        guard let buttonName = hidCodeToButton[hidCode],
              let action = buttonMappings[buttonName] else {
            return nil
        }
        return action
    }
    
    /// Execute an action by name
    func executeAction(_ actionName: String) {
        if let key = parseKeyboardMapping(actionName) {
            sendKey(Int(key.keyCode), flags: key.flags)
            return
        }
        guard let action = ButtonAction(rawValue: actionName) else { return }
        
        switch action {
        case .none:
            break
        case .playPause:
            mediaController?.sendMediaKey(.playPause)
        case .nextTrack:
            mediaController?.sendMediaKey(.next)
        case .previousTrack:
            mediaController?.sendMediaKey(.previous)
        case .volumeUp:
            mediaController?.sendMediaKey(.volumeUp)
        case .volumeDown:
            mediaController?.sendMediaKey(.volumeDown)
        case .mute:
            mediaController?.sendMediaKey(.mute)
        case .click:
            performClick()
        case .rightClick:
            performRightClick()
        case .escape:
            sendKey(kVK_Escape)
        case .space:
            sendKey(kVK_Space)
        case .enter:
            sendKey(kVK_Return)
        case .missionControl:
            sendMissionControlKey()
        }
    }

    /// Handle a physical remote button with true key-down/key-up semantics for
    /// keyboard mappings. This lets a mapped modifier such as Right Command be
    /// held while another key is pressed, instead of merely generating a tap.
    func handleMapping(_ mapping: String, pressed: Bool) {
        if let key = parseKeyboardMapping(mapping) {
            sendKeyEvent(Int(key.keyCode), flags: key.flags, pressed: pressed)
        } else if pressed {
            executeAction(mapping)
        }
    }
    
    private func sendMissionControlKey() {
        openMissionControl()
    }
    
    private func performClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)
        
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }
    
    private func performRightClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)
        
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: cgPos, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: cgPos, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }
    
    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        sendKeyEvent(keyCode, flags: flags, pressed: true)
        usleep(10000)
        sendKeyEvent(keyCode, flags: flags, pressed: false)
    }

    private func sendKeyEvent(_ keyCode: Int, flags: CGEventFlags, pressed: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: pressed)
        event?.flags = pressed ? flags : []
        event?.post(tap: .cghidEventTap)
    }

    private func keyboardMapping(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
        "key:\(keyCode):\(flags.rawValue)"
    }

    private func parseKeyboardMapping(_ value: String) -> (keyCode: UInt16, flags: CGEventFlags)? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, parts[0] == "key",
              let keyCode = UInt16(parts[1]),
              let flagsValue = UInt64(parts[2]) else { return nil }
        return (keyCode, CGEventFlags(rawValue: flagsValue))
    }

    private func keyboardMappingDisplayName(_ value: String) -> String {
        guard let mapping = parseKeyboardMapping(value) else { return "未知按键" }
        let code = mapping.keyCode
        if let modifierName = Self.modifierKeyNames[code] { return modifierName }

        var prefix = ""
        if mapping.flags.contains(.maskControl) { prefix += "⌃" }
        if mapping.flags.contains(.maskAlternate) { prefix += "⌥" }
        if mapping.flags.contains(.maskShift) { prefix += "⇧" }
        if mapping.flags.contains(.maskCommand) { prefix += "⌘" }
        return prefix + (Self.keyNames[code] ?? "键码 \(code)")
    }

    private static func isModifierKeyCode(_ code: UInt16) -> Bool {
        modifierKeyNames[code] != nil
    }

    private static let modifierKeyNames: [UInt16: String] = [
        UInt16(kVK_Command): "左 Command", UInt16(kVK_RightCommand): "右 Command",
        UInt16(kVK_Shift): "左 Shift", UInt16(kVK_RightShift): "右 Shift",
        UInt16(kVK_Option): "左 Option", UInt16(kVK_RightOption): "右 Option",
        UInt16(kVK_Control): "左 Control", UInt16(kVK_RightControl): "右 Control",
        UInt16(kVK_CapsLock): "大写锁定", UInt16(kVK_Function): "Fn"
    ]

    private static let keyNames: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9", UInt16(kVK_Return): "回车", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Space): "空格", UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "向前删除",
        UInt16(kVK_Escape): "Esc", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End", UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionMonitor() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
        if let permissionTimer {
            RunLoop.main.add(permissionTimer, forMode: .common)
        }
    }

    private func refreshPermissionStatus() {
        let trusted = AXIsProcessTrusted()
        permissionMenuItem.title = trusted
            ? "辅助功能权限：已授权 ✓"
            : "辅助功能权限：未授权（点击打开设置）"
        permissionMenuItem.action = trusted ? nil : #selector(openAccessibilitySettings)
        permissionMenuItem.target = self
        permissionMenuItem.isEnabled = !trusted
    }
    
    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}
