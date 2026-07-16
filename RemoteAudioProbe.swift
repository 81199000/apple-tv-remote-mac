import Foundation
import IOKit
import IOKit.hid

/// Minimal diagnostic for the private Audio HID interface created by
/// AppleBluetoothRemote.kext for a first-generation Siri Remote.
final class RemoteAudioProbe {
    private let outputPath = "/tmp/remotastic-root-hid-audio2.log"
    private var manager: IOHIDManager?
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var file: FileHandle?
    private var reportCount = 0

    func run(for duration: TimeInterval) {
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        file = FileHandle(forWritingAtPath: outputPath)
        write("# Remote Audio HID probe; uid=\(getuid()) euid=\(geteuid())\n")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // Match all Apple HID interfaces first, then log/filter in code.
        // On this Mac: first-gen Siri Remote is ProductID 0x0266 (often disconnected),
        // second-gen Siri Remote is BLE ProductID 0x0314, and 0x0265 is Magic Trackpad.
        // Product-specific matching is too easy to get wrong during reverse engineering.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x004C
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            audioDeviceAddedCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        write(String(format: "# manager open: 0x%08X\n", UInt32(bitPattern: openResult)))
        guard openResult == kIOReturnSuccess else {
            finish()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            CFRunLoopStop(CFRunLoopGetMain())
        }
        print("Audio HID 探针已启动（\(Int(duration)) 秒），请按住语音键讲话。")
        CFRunLoopRun()
        finish()
        print("Audio HID 探针结束：\(outputPath)，共 \(reportCount) 个报告。")
    }

    func add(device: IOHIDDevice) {
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let maxSize = max(
            IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0,
            209
        )
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? ""
        write(String(
            format: "# device product=0x%04X serial=%@ page=0x%X usage=0x%X max=%d open=0x%08X\n",
            product,
            serial,
            page,
            usage,
            maxSize,
            UInt32(bitPattern: openResult)
        ))
        guard openResult == kIOReturnSuccess else { return }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        buffer.initialize(repeating: 0, count: maxSize)
        buffers[device] = buffer
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            maxSize,
            audioInputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
    }

    func received(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        let bytes = UnsafeBufferPointer(start: report, count: length)
        let nonzero = bytes.reduce(into: 0) { count, byte in
            if byte != 0 { count += 1 }
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        write(String(
            format: "%.6f id=%02X length=%d nonzero=%d %@\n",
            ProcessInfo.processInfo.systemUptime,
            reportID,
            length,
            nonzero,
            hex
        ))
        reportCount += 1
    }

    private func write(_ string: String) {
        file?.write(Data(string.utf8))
        file?.synchronizeFile()
    }

    private func finish() {
        for (device, buffer) in buffers {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 0, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
        }
        buffers.removeAll()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        file?.closeFile()
        file = nil
    }
}

private func audioDeviceAddedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RemoteAudioProbe>.fromOpaque(context).takeUnretainedValue().add(device: device)
}

private func audioInputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess, let context, reportLength > 0 else { return }
    Unmanaged<RemoteAudioProbe>
        .fromOpaque(context)
        .takeUnretainedValue()
        .received(reportID: reportID, report: report, length: reportLength)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let requestedDuration = arguments.compactMap(TimeInterval.init).first ?? 90
RemoteAudioProbe().run(for: max(10, requestedDuration))
