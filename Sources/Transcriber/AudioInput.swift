import AVFoundation
import CoreAudio

/// Delivers PCM buffers from the system audio tap or an input device.
protocol AudioCapture: AnyObject {
    /// `onBuffer` runs on a background thread. The buffer is only valid for the duration of the call.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// A Core Audio device with at least one input channel (built-in microphone, headset, USB interface, …).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func all() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = string(of: id, kAudioDevicePropertyDeviceUID),
                  let name = string(of: id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Calls `handler` on the main queue whenever a device is connected or disconnected.
    static func observeChanges(_ handler: @escaping () -> Void) {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(of id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Captures a specific input device through `AVAudioEngine`. Requires the Microphone permission.
final class MicrophoneCapture: AudioCapture {
    enum CaptureError: LocalizedError {
        case notAuthorized
        case disconnected
        case deviceUnavailable(String, OSStatus)
        case noInput(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Microphone access is not allowed. Enable Transcriber in System Settings › Privacy & Security › Microphone."
            case .disconnected:
                return "The selected microphone isn't connected. Choose another source in the toolbar."
            case let .deviceUnavailable(name, status):
                return "Couldn't use “\(name)” (OSStatus \(status))."
            case let .noInput(name):
                return "“\(name)” doesn't provide any audio input."
            }
        }
    }

    private let device: AudioInputDevice
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    init(device: AudioInputDevice) {
        self.device = device
    }

    static func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.deviceUnavailable(device.name, -1) }
        var deviceID = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.deviceUnavailable(device.name, status) }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput(device.name) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    deinit { stop() }
}
