import AVFoundation
import CoreAudio
import Foundation

/// Where one output device's audio goes in the aggregate.
struct TapOutput: Equatable {
    let device: AudioDeviceID
    let uid: String
    /// For each of this device's output channels: 0 = left, 1 = right, -1 = silent.
    let channelMap: [Int32]
}

/// Captures the audio of one app (one or more processes) and plays it through an effect chain
/// to one or more output devices.
///
/// Pipeline: process tap (muted at the source) -> private aggregate device (outputs + tap)
/// -> IO callback running ChainEngine.
final class AppTap {
    let processObjectIDs: [AudioObjectID]
    let outputs: [TapOutput]
    let auEffectIDs: [UUID]
    let muteSource: Bool
    let global: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var engine: ChainEngine?
    private let shared: ChainShared
    private(set) var sampleRate: Double = 48000

    /// `muteSource == false` builds a listen-only tap (used for level meters).
    /// `global` captures every app (used for the output meter).
    init(name: String, processObjectIDs: [AudioObjectID], global: Bool = false, outputs: [TapOutput], shared: ChainShared,
         audioUnits: [(UUID, AUAudioUnit)], muteSource: Bool = true) throws {
        self.processObjectIDs = processObjectIDs
        self.global = global
        self.outputs = outputs
        self.shared = shared
        self.muteSource = muteSource
        auEffectIDs = audioUnits.map(\.0)
        do {
            try start(name: name, audioUnits: audioUnits.map(\.1))
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(name: String, audioUnits: [AUAudioUnit]) throws {
        guard let main = outputs.first else { throw CAError("No output device") }

        let desc = global ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                          : CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = UUID()
        desc.name = "iSound – \(name)"
        desc.isPrivate = true
        desc.muteBehavior = muteSource ? .mutedWhenTapped : .unmuted

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CAError("Creating audio tap", err) }

        var tapChannels = 2
        if let fmt = CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) {
            guard fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0, fmt.mBitsPerChannel == 32 else {
                throw CAError("Unsupported tap audio format")
            }
            tapChannels = max(1, Int(fmt.mChannelsPerFrame))
        }

        var subDevices: [[String: Any]] = []
        for (i, o) in outputs.enumerated() {
            var d: [String: Any] = [kAudioSubDeviceUIDKey: o.uid]
            if i > 0 { d[kAudioSubDeviceDriftCompensationKey] = 1 }   // keep grouped outputs in sync
            subDevices.append(d)
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "iSound \(name)",
            kAudioAggregateDeviceUIDKey: "\(DeviceManager.privatePrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceClockDeviceKey: main.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard err == noErr else { throw CAError("Creating output device", err) }

        if let rate = CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)), rate > 0 {
            sampleRate = rate
        }

        // Prepare hosted plug-ins for this sample rate.
        var slots: [AUSlot] = []
        if let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) {
            for unit in audioUnits {
                unit.deallocateRenderResources()
                try? unit.inputBusses[0].setFormat(format)
                try? unit.outputBusses[0].setFormat(format)
                unit.maximumFramesToRender = AUAudioFrameCount(ChainEngine.maxFrames)
                // Without this, plug-ins refuse to render ("no input connection") and audio passes through untouched.
                unit.inputBusses[0].isEnabled = true
                unit.outputBusses[0].isEnabled = true
                do {
                    try unit.allocateRenderResources()
                    slots.append(AUSlot(unit: unit))
                } catch {
                    throw CAError("Couldn't start plug-in \(unit.audioUnitName ?? "")")
                }
            }
        }

        // Output channel map across all subdevices, in aggregate order.
        let outMap = outputs.flatMap(\.channelMap)
        let engine = ChainEngine(shared: shared, sampleRate: sampleRate, tapChannels: tapChannels,
                                 outMap: outMap, auSlots: slots)
        self.engine = engine

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            engine.process(input: input, output: output)
        }
        guard err == noErr, let ioProcID else { throw CAError("Creating audio callback", err) }

        // Output devices' own inputs (e.g. an AirPods mic) come before the tap. Switch them
        // off so we never open a headset mic (which would drop it to low-quality call mode).
        let deviceInputs = outputs.reduce(0) { $0 + CA.inputStreamCount($1.device) }
        disableLeadingInputStreams(count: deviceInputs, procID: ioProcID)

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw CAError("Starting audio", err) }
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
        engine = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Sets kAudioDevicePropertyIOProcStreamUsage so the first `count` input streams are off.
    private func disableLeadingInputStreams(count: Int, procID: AudioDeviceIOProcID) {
        guard count > 0 else { return }
        let total = CA.inputStreamCount(aggregateID)
        guard total > count else { return }

        // struct AudioHardwareIOProcStreamUsage { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let headerSize = MemoryLayout<UnsafeRawPointer>.size + MemoryLayout<UInt32>.size
        let byteCount = headerSize + MemoryLayout<UInt32>.size * total
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)

        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size = UInt32(byteCount)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else { return }
        let flags = (raw + headerSize).bindMemory(to: UInt32.self, capacity: total)
        for i in 0..<total { flags[i] = i < count ? 0 : 1 }
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(byteCount), raw)
    }
}
