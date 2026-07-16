import Foundation
import Darwin

/// Small runtime bridge to macOS's private Bluetooth voice-command API.
/// The first-generation remote does not expose microphone data merely because
/// the Siri HID button was pressed; the host must set the VoiceCommand service
/// state while the button is held.
final class BluetoothVoiceCommand {
    static let shared = BluetoothVoiceCommand()

    private let address = "78-9f-70-74-38-01"
    private let queue = DispatchQueue(label: "com.remotastic.bluetooth.voice")
    private let logPath = "/tmp/remotastic-voice-command.log"
    private var manager: NSObject?
    private var initialized = false

    private init() {}

    func start() {
        queue.async { [weak self] in self?.attemptStart(remaining: 12) }
    }

    func end() {
        queue.async { [weak self] in
            guard let self, self.prepare(), let device = self.device() else { return }
            self.invoke("endVoiceCommand:", on: self.manager, argument: device)
            self.log("end: VoiceCommand.State=false sent")
        }
    }

    private func prepare() -> Bool {
        if initialized { return manager != nil }
        initialized = true

        let paths = [
            "/System/Library/PrivateFrameworks/MobileBluetooth.framework/MobileBluetooth",
            "/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager"
        ]
        for path in paths {
            guard dlopen(path, RTLD_NOW) != nil else {
                log("load failed: \(path)")
                return false
            }
        }
        guard let cls = NSClassFromString("BluetoothManager") as? NSObject.Type else {
            log("BluetoothManager class unavailable")
            return false
        }
        _ = cls.perform(NSSelectorFromString("setSharedInstanceQueue:"), with: queue)
        guard let value = cls.perform(NSSelectorFromString("sharedInstance")) else {
            log("sharedInstance unavailable")
            return false
        }
        manager = value.takeUnretainedValue() as? NSObject
        _ = manager?.perform(NSSelectorFromString("_attach"))
        log("manager initialized; object=\(manager != nil)")
        return manager != nil
    }

    private func attemptStart(remaining: Int) {
        guard prepare() else { return }
        if let device = device() {
            invoke("startVoiceCommand:", on: manager, argument: device)
            log("start: VoiceCommand.State=true sent")
            return
        }
        if remaining > 0 {
            log("start: device object not ready; retry \(remaining)")
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attemptStart(remaining: remaining - 1)
            }
        } else {
            log("start: device object unavailable after retries")
        }
    }

    private func device() -> NSObject? {
        guard let manager else { return nil }
        if let value = manager.perform(NSSelectorFromString("deviceFromAddressString:"), with: address) {
            return value.takeUnretainedValue() as? NSObject
        }
        let selector = NSSelectorFromString("connectedDevices")
        let devices = (manager.perform(selector)?.takeUnretainedValue() as? [NSObject]) ?? []
        return devices.first { object in
            let value = object.perform(NSSelectorFromString("address"))?.takeUnretainedValue() as? String
            return value?.lowercased() == address.lowercased()
        }
    }

    private func invoke(_ selectorName: String, on target: NSObject?, argument: NSObject) {
        guard let target else { return }
        _ = target.perform(NSSelectorFromString(selectorName), with: argument)
    }

    private func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let file = FileHandle(forWritingAtPath: logPath) {
            file.seekToEndOfFile()
            file.write(Data(line.utf8))
            file.closeFile()
        }
    }
}
