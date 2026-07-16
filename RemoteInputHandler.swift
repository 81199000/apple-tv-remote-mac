//
//  RemoteInputHandler.swift
//  Remotastic
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

class RemoteInputHandler {
    private let cursorController: CursorController
    private let mediaController: MediaController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []
    private var reportBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var previousButtonMask: UInt8 = 0
    private var activeButtons: Set<String> = []
    private var lastAcceptedPressTime: [String: TimeInterval] = [:]
    private let buttonDebounceInterval: TimeInterval = 0.18

    // First-generation Siri Remotes expose several 0xFF vendor reports.  Keep a
    // short, bounded trace after the Siri button is pressed so we can determine
    // whether the microphone packets are available through IOHID (which would
    // avoid requiring PacketLogger/root access in the finished app).
    private let voiceProbePath = "/tmp/remotastic-hid-voice.log"
    private let voiceProbeDuration: TimeInterval = 5.0
    private let voiceProbeMaximumReports = 1_000
    private var voiceProbeUntil: TimeInterval = 0
    private var voiceProbeReportCount = 0
    private var voiceProbeFile: FileHandle?
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private let clickThreshold: Double = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0
    
    init(cursorController: CursorController, mediaController: MediaController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.mediaController = mediaController
        self.menuBarManager = menuBarManager
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            // Release any held keyboard mappings before clearing state so a
            // disconnect cannot leave Command/Shift/etc. logically stuck.
            for buttonName in activeButtons {
                let mapping = menuBarManager?.getMapping(for: buttonName) ?? ButtonAction.none.rawValue
                menuBarManager?.handleMapping(mapping, pressed: false)
            }
            activeButtons.removeAll()
            lastAcceptedPressTime.removeAll()

            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                if let buffer = reportBuffers[d] {
                    IOHIDDeviceRegisterInputReportCallback(d, buffer, 0, nil, nil)
                }
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
                reportBuffers.removeValue(forKey: d)?.deallocate()
            }
            devices.removeAll()
            previousButtonMask = 0
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        // Do not seize the Siri Remote. The first-generation remote exposes
        // buttons, touch, sensors and device management as sibling interfaces;
        // taking exclusive access can starve Apple's multitouch driver and make
        // the remote disconnect. A passive open is enough for raw reports.
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }

        IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())

        // First-generation Siri Remotes mark the eight button usages in report
        // 0xFA as constant HID elements. macOS therefore does not emit value
        // callbacks for TV, Siri, Menu and Select. Read the raw report as well.
        let maxReportSize = max(
            IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0,
            2
        )
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReportSize)
        buffer.initialize(repeating: 0, count: maxReportSize)
        reportBuffers[device] = buffer
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            maxReportSize,
            inputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        devices.append(device)
        CursorController.playKeyPressFeedback()
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        
        guard let buttonName = identifyButton(page: usagePage, usage: usage) else { return }
        
        // Any button activity may cause the remote to re-enumerate; re-scan MT so trackpad can reconnect.
        onButtonActivity?()
        
        // Handle select button (trackpad click) - distinguish click vs drag
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }
        
        performMappedAction(for: buttonName, pressed: intValue == 1)
    }

    func handleInputReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        captureVoiceProbeReport(reportID: reportID, report: report, length: length)
        guard reportID == 0xFA, length > 0 else { return }

        // Depending on the macOS driver version, the report buffer either starts
        // with the report ID or directly with the one-byte button mask.
        let mask: UInt8
        if length > 1 && report[0] == 0xFA {
            mask = report[1]
        } else {
            mask = report[0]
        }

        let changed = mask ^ previousButtonMask
        guard changed != 0 else { return }
        previousButtonMask = mask
        onButtonActivity?()

        let buttons: [(bit: UInt8, name: String)] = [
            (0, "tv"),
            (1, "volumeUp"),
            (2, "volumeDown"),
            (3, "playPause"),
            (4, "siri"),
            (5, "menu"),
            (6, "power"),
            (7, "select")
        ]

        for button in buttons where changed & (1 << button.bit) != 0 {
            let pressed = mask & (1 << button.bit) != 0
            if button.name == "select" {
                handleSelectButton(pressed: pressed)
            } else {
                performMappedAction(for: button.name, pressed: pressed)
            }
        }
    }

    private func performMappedAction(for buttonName: String, pressed: Bool) {
        if pressed {
            // The first-generation remote can surface the same physical button
            // through both the element callback and raw report 0xFA. Accept a
            // single key-down until release, plus a short post-press debounce
            // window for callbacks that arrive out of order.
            guard !activeButtons.contains(buttonName) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let lastPress = lastAcceptedPressTime[buttonName],
               now - lastPress < buttonDebounceInterval {
                return
            }
            activeButtons.insert(buttonName)
            lastAcceptedPressTime[buttonName] = now
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()

            if buttonName == "siri" {
                BluetoothVoiceCommand.shared.start()
                startVoiceProbe()
            }
        } else {
            // Ignore duplicate releases from the second HID event path.
            guard activeButtons.remove(buttonName) != nil else { return }
            if buttonName == "siri" {
                BluetoothVoiceCommand.shared.end()
            }
        }

        let mapping = menuBarManager?.getMapping(for: buttonName) ?? ButtonAction.none.rawValue
        if pressed { print("🔘 Raw button: \(buttonName) → \(mapping)") }
        if pressed && mapping != ButtonAction.none.rawValue {
            CursorController.playKeyPressFeedback()
        }
        menuBarManager?.handleMapping(mapping, pressed: pressed)
    }

    private func startVoiceProbe() {
        voiceProbeFile?.closeFile()
        voiceProbeFile = nil
        voiceProbeReportCount = 0
        voiceProbeUntil = ProcessInfo.processInfo.systemUptime + voiceProbeDuration

        FileManager.default.createFile(atPath: voiceProbePath, contents: nil)
        guard let file = FileHandle(forWritingAtPath: voiceProbePath) else { return }
        voiceProbeFile = file
        let started = String(
            format: "# Siri HID probe started %.6f; duration %.1fs\n",
            ProcessInfo.processInfo.systemUptime,
            voiceProbeDuration
        )
        file.write(Data(started.utf8))

        DispatchQueue.main.asyncAfter(deadline: .now() + voiceProbeDuration) { [weak self] in
            self?.finishVoiceProbe()
        }
    }

    private func captureVoiceProbeReport(
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        length: Int
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now <= voiceProbeUntil,
              reportID != 0xFA,
              length > 0,
              voiceProbeReportCount < voiceProbeMaximumReports,
              let file = voiceProbeFile else { return }

        let bytes = UnsafeBufferPointer(start: report, count: length)
        let nonzeroCount = bytes.reduce(into: 0) { count, byte in
            if byte != 0 { count += 1 }
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = String(
            format: "%.6f id=%02X length=%d nonzero=%d %@\n",
            now,
            reportID,
            length,
            nonzeroCount,
            hex
        )
        file.write(Data(line.utf8))
        voiceProbeReportCount += 1

        if voiceProbeReportCount >= voiceProbeMaximumReports {
            finishVoiceProbe()
        }
    }

    private func finishVoiceProbe() {
        guard let file = voiceProbeFile else { return }
        let finished = "# Finished; captured \(voiceProbeReportCount) reports\n"
        file.write(Data(finished.utf8))
        file.closeFile()
        voiceProbeFile = nil
        voiceProbeUntil = 0
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            
            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                CursorController.playKeyPressFeedback()
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }
    
    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: ButtonAction) {
        switch action {
        case .none:
            break
        case .playPause:
            // In .app the remote also sends Play/Pause over AVRCP; skip our send so only AVRCP fires (once).
            if !Bundle.main.bundlePath.hasSuffix(".app") {
                mediaController.sendMediaKey(.playPause)
            }
        case .nextTrack:
            mediaController.sendMediaKey(.next)
        case .previousTrack:
            mediaController.sendMediaKey(.previous)
        case .volumeUp:
            mediaController.sendMediaKey(.volumeUp)
        case .volumeDown:
            mediaController.sendMediaKey(.volumeDown)
        case .mute:
            mediaController.sendMediaKey(.mute)
        case .click:
            cursorController.performClick()
        case .rightClick:
            cursorController.performRightClick()
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
    
    private func sendMissionControlKey() {
        openMissionControl()
    }
    
    private func sendKey(_ keyCode: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)?.post(tap: .cghidEventTap)
        usleep(10000)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)?.post(tap: .cghidEventTap)
    }
}

/// Opens Mission Control (one path for CLI and app).
func openMissionControl() {
    let bundleID = "com.apple.exposelauncher"
    if Bundle.main.bundlePath.hasSuffix(".app"),
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["-b", bundleID]
    try? proc.run()
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}

private func inputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess,
          let context,
          reportLength > 0 else { return }
    Unmanaged<RemoteInputHandler>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleInputReport(reportID: reportID, report: report, length: reportLength)
}
