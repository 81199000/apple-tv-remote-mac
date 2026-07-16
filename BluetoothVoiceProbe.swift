import Foundation
import Darwin

let address = "78-9f-70-74-38-01"
let start = CommandLine.arguments.dropFirst().first == "start"
let paths = [
    "/System/Library/PrivateFrameworks/MobileBluetooth.framework/MobileBluetooth",
    "/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager"
]
for path in paths {
    guard dlopen(path, RTLD_NOW) != nil else { print("load failed: \(path)"); exit(2) }
}
guard let cls = NSClassFromString("BluetoothManager") as? NSObject.Type else { print("manager class unavailable"); exit(3) }
let q = DispatchQueue(label: "com.remotastic.voice-probe")
_ = cls.perform(NSSelectorFromString("setSharedInstanceQueue:"), with: q)
guard let value = cls.perform(NSSelectorFromString("sharedInstance")),
      let manager = value.takeUnretainedValue() as? NSObject else { print("manager unavailable"); exit(4) }
_ = manager.perform(NSSelectorFromString("_attach"))
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))

func boolValue(_ name: String) -> Bool? {
    let selector = NSSelectorFromString(name)
    guard let imp = manager.method(for: selector) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(manager, selector)
}

print("manager available=\(boolValue("available") as Any) powered=\(boolValue("powered") as Any) connected=\(boolValue("connected") as Any)")
let devices = (manager.perform(NSSelectorFromString("connectedDevices"))?.takeUnretainedValue() as? [NSObject]) ?? []
print("connectedDevices=\(devices.count)")
for device in devices {
    let name = device.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String ?? "?"
    let addr = device.perform(NSSelectorFromString("address"))?.takeUnretainedValue() as? String ?? "?"
    print("device \(name) \(addr)")
}

guard let deviceValue = manager.perform(NSSelectorFromString("deviceFromAddressString:"), with: address),
      let device = deviceValue.takeUnretainedValue() as? NSObject else {
    print("target device object unavailable")
    exit(5)
}

let command = start ? "startVoiceCommand:" : "endVoiceCommand:"
_ = manager.perform(NSSelectorFromString(command), with: device)
print("sent \(command)")
