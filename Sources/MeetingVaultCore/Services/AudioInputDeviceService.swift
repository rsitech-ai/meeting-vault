import CoreAudio
import Foundation

public protocol AudioInputDeviceProviding: Sendable {
    func snapshot() async -> [AudioInputDevice]
}

public final class MockAudioInputDeviceProvider: AudioInputDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [AudioInputDevice]
    private var reads = 0

    public init(devices: [AudioInputDevice]) {
        self.devices = devices
    }

    public var snapshotReadCount: Int {
        lock.withLock { reads }
    }

    public func update(devices: [AudioInputDevice]) {
        lock.withLock {
            self.devices = devices
        }
    }

    public func snapshot() async -> [AudioInputDevice] {
        lock.withLock {
            reads += 1
            return devices
        }
    }
}

public struct SystemAudioInputDeviceProvider: AudioInputDeviceProviding {
    public init() {}

    public func snapshot() async -> [AudioInputDevice] {
        Self.coreAudioInputDevices()
    }

    private static func coreAudioInputDevices() -> [AudioInputDevice] {
        let defaultDeviceID = defaultInputDeviceID()
        return allAudioDeviceIDs()
            .filter(hasInputStreams(deviceID:))
            .map { deviceID in
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
                let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
                    ?? "Audio Input \(deviceID)"
                let id = uid?.isEmpty == false ? uid! : "\(deviceID)"
                let isDefault = defaultDeviceID == deviceID
                return AudioInputDevice(
                    id: id,
                    displayName: name,
                    transportLabel: transportLabel(for: transportType(deviceID: deviceID), name: name),
                    isDefault: isDefault,
                    isConnected: isDeviceAlive(deviceID: deviceID),
                    level: isDefault ? 0.72 : 0.38
                )
            }
            .sorted {
                if $0.isDefault != $1.isDefault {
                    return $0.isDefault && !$1.isDefault
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var devices = Array(repeating: AudioDeviceID(), count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        return status == noErr ? devices : []
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.stride)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.stride)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func isDeviceAlive(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : true
    }

    private static func transportLabel(for transportType: UInt32?, name: String) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:
            return "AirPlay"
        default:
            return transportLabelFromName(name)
        }
    }

    private static func transportLabelFromName(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("airpods") || lowered.contains("bluetooth") {
            return "Bluetooth"
        }
        if lowered.contains("usb") {
            return "USB"
        }
        if lowered.contains("mac") || lowered.contains("built-in") {
            return "Built-in"
        }
        return "Input"
    }
}

public struct AudioInputDeviceService: Sendable {
    private let provider: AudioInputDeviceProviding

    public init(provider: AudioInputDeviceProviding) {
        self.provider = provider
    }

    public func refresh() async -> [AudioInputDevice] {
        await provider.snapshot()
    }
}
