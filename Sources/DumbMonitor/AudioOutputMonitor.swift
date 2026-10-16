// SPDX-License-Identifier: MPL-2.0
import CoreAudio
import Foundation

struct AudioOutput: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class AudioOutputMonitor: ObservableObject {
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var defaultUID = ""
    var onChange: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]

    init() {
        reload()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reload() }
        }
        listener = block
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    func stop() {
        guard let listener else { return }
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = nil
    }

    func reload() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &current)
        defaultUID = Self.string(current, kAudioDevicePropertyDeviceUID)

        address = Self.address(kAudioHardwarePropertyDevices)
        size = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return }
        outputs = devices.compactMap { device in
            var streamAddress = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let uid = Self.string(device, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { return nil }
            return AudioOutput(id: uid, name: Self.string(device, kAudioObjectPropertyName))
        }
        onChange?()
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : ""
    }
}
