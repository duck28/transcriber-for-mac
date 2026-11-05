import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (minus this app) through a Core Audio process tap.
/// Requires macOS 14.4+ and the "System Audio Recording" permission (no Screen Recording needed).
final class SystemAudioCapture: AudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case let .coreAudio(step, status): return "\(step) failed (OSStatus \(status))."
            case .unsupportedFormat: return "The system audio tap returned an unsupported audio format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "Transcriber.SystemAudioCapture", qos: .userInitiated)

    /// `onBuffer` runs on a background queue. The buffer is only valid for the duration of the call.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        do {
            let ownProcess = try? Self.processObjectID(for: getpid())
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
            description.uuid = UUID()
            description.name = "Transcriber System Audio Tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

            var streamDescription = try Self.readProperty(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.unsupportedFormat
            }

            // The aggregate device provides the clock; its main sub-device is the current output device.
            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcriber Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                      "Creating the aggregate audio device")

            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
                onBuffer(buffer)
            }, "Registering the audio callback")

            try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: - Core Audio helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }

    private static func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID)
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw CaptureError.coreAudio("Looking up the Transcriber process", status)
        }
        return objectID
    }

    private static func defaultOutputDeviceUID() throws -> String {
        let deviceID = try readProperty(AudioObjectID(kAudioObjectSystemObject),
                                        kAudioHardwarePropertyDefaultSystemOutputDevice,
                                        as: AudioObjectID(kAudioObjectUnknown))
        let uid = try readProperty(deviceID, kAudioDevicePropertyDeviceUID, as: "" as CFString)
        return uid as String
    }

    private static func readProperty<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        as initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw CaptureError.coreAudio("Reading audio property \(selector)", status) }
        return value
    }
}
