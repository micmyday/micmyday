import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
    /// True for AirPods and other wireless headsets.
    ///
    /// They matter because a Bluetooth headset carries no microphone in the
    /// profile it plays music over. Opening its input makes macOS renegotiate
    /// the link into a headset profile, which takes a few hundred milliseconds
    /// and audibly degrades whatever is playing. That cost cannot be paid in
    /// advance without holding the headset in call mode the whole time.
    let isWireless: Bool

    var id: String { uid }
}

enum AudioInputDeviceError: LocalizedError {
    case propertyReadFailed(String, OSStatus)
    case noInputDevices
    case selectedDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case let .propertyReadFailed(property, status):
            return "Core Audio could not read \(property) (macOS error \(status))."
        case .noInputDevices:
            return "No microphone or audio input device is currently available."
        case .selectedDeviceUnavailable:
            return "The selected microphone is no longer connected. Choose another device in MicMyDay Settings → Voice."
        }
    }
}

enum AudioInputDeviceManager {
    /// CoreAudio spins up a throwaway aggregate device per process, named
    /// "CADefaultDeviceAggregate-<pid>-<n>". It has input streams, so it used
    /// to appear in the picker; its UID changes every launch, so anyone who
    /// selected it met "The selected microphone is no longer connected" on the
    /// next start with no way to tell why. Aggregates the user built in Audio
    /// MIDI Setup are deliberately still offered.
    private static func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
        guard
            let uid = try? stringProperty(
                kAudioDevicePropertyDeviceUID,
                deviceID: deviceID,
                propertyName: "device UID"
            )
        else { return false }
        return uid.hasPrefix("CADefaultDeviceAggregate")
    }

    private static func isWireless(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeAirPlay
    }

    static func inputDevices() throws -> [AudioInputDevice] {
        let deviceIDs = try allDeviceIDs()
        let defaultDeviceID = try? defaultInputDeviceID()
        var devices: [AudioInputDevice] = []

        for deviceID in deviceIDs where hasInputStreams(deviceID) && !isPrivateAggregate(deviceID) {
            guard
                let uid = try? stringProperty(
                    kAudioDevicePropertyDeviceUID,
                    deviceID: deviceID,
                    propertyName: "device UID"
                ),
                let name = try? stringProperty(
                    kAudioObjectPropertyName,
                    deviceID: deviceID,
                    propertyName: "device name"
                )
            else { continue }

            devices.append(
                AudioInputDevice(
                    deviceID: deviceID,
                    uid: uid,
                    name: name,
                    isDefault: deviceID == defaultDeviceID,
                    isWireless: isWireless(deviceID)
                )
            )
        }

        return devices.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolveInputDevice(uid: String?) throws -> AudioInputDevice {
        let devices = try inputDevices()
        guard !devices.isEmpty else { throw AudioInputDeviceError.noInputDevices }

        let requestedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requestedUID.isEmpty {
            guard let device = devices.first(where: { $0.isDefault }) else {
                throw AudioInputDeviceError.noInputDevices
            }
            return device
        }

        guard let device = devices.first(where: { $0.uid == requestedUID }) else {
            throw AudioInputDeviceError.selectedDeviceUnavailable
        }
        return device
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            throw AudioInputDeviceError.propertyReadFailed("audio device list", sizeStatus)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        let readStatus = deviceIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard readStatus == noErr else {
            throw AudioInputDeviceError.propertyReadFailed("audio device list", readStatus)
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioInputDeviceError.propertyReadFailed("default input device", status)
        }
        return deviceID
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        propertyName: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedValue: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &unmanagedValue
        )
        guard status == noErr, let unmanagedValue else {
            throw AudioInputDeviceError.propertyReadFailed(propertyName, status)
        }
        return unmanagedValue.takeUnretainedValue() as String
    }
}
