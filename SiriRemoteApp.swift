//
//  SiriRemoteApp.swift
//  Remotastic
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 遥控器助手正在启动……")
        
        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        menuBarManager.onSettingsChanged = { [weak self] in
            self?.applySettings()
        }
        
        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()
        let mediaController = MediaController()
        menuBarManager.mediaController = mediaController
        
        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            mediaController: mediaController,
            menuBarManager: menuBarManager
        )
        
        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        applySettings()
        touchHandler?.start()
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
            }
        }
        remoteDetector?.startDetection()
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
        
        // Wire up settings changes
    }

    private func applySettings() {
        CursorController.feedbackEnabled = menuBarManager.keyPressFeedbackEnabled
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        touchHandler?.cursorScale = menuBarManager.cursorSpeed.scale
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        let defaultAction: String
        
        switch keyType {
        case .playPause:
            buttonName = "playPause"
            defaultAction = "Play/Pause"
        case .next:
            buttonName = "nextTrack"
            defaultAction = "Next Track"
        case .previous:
            buttonName = "prevTrack"
            defaultAction = "Previous Track"
        case .volumeUp:
            buttonName = "volumeUp"
            defaultAction = "Volume Up"
        case .volumeDown:
            buttonName = "volumeDown"
            defaultAction = "Volume Down"
        case .mute:
            return false
        }
        
        // Check if RemoteInputHandler just processed this button (prevent double-processing)
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.2 { // Within 200ms debounce window
                // RemoteInputHandler already handled this, consume the event but don't process again
                return true
            }
        }
        
        let action = menuBarManager.getMapping(for: buttonName)
        
        if action == ButtonAction.none.rawValue {
            return true // Consume but do nothing
        }
        
        if action == defaultAction {
            // In .app, Play/Pause is also sent over AVRCP; we don't send from HID there. Let system handle once.
            if keyType == .playPause && Bundle.main.bundlePath.hasSuffix(".app") {
                return false // Let system handle (AVRCP); we don't send from HID in .app
            }
            return true // Consume; HID path is the single source (CLI or non–play/pause)
        }
        
        menuBarManager.executeAction(action)
        return true
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        guard !trusted else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "移动鼠标、模拟 Delete 和 Command 等键盘按键都需要辅助功能权限。请在系统设置中打开“遥控器助手”。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
