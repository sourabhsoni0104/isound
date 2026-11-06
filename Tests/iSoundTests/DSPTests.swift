import AVFoundation
import CoreAudio
import XCTest
@testable import iSound

/// Runs audio through the real-time engine exactly like the app does, without any devices.
struct EngineHarness {
    let sampleRate = 48000.0
    let block = 512
    let engine: ChainEngine
    let shared: ChainShared
    let outChannels: Int

    init(effects: [EffectConfig] = [], gain: Float = 1, fade: Float = 0.015, outMap: [Int32] = [0, 1],
         auSlots: [AUSlot] = [], auIndex: [UUID: Int] = [:]) {
        shared = ChainShared()
        let compiled = ChainCompiler.compile(effects, sampleRate: 48000) { auIndex[$0] }
        shared.publish(gain: gain, fadeSeconds: fade, outputEnabled: true, stages: compiled.stages, biquads: compiled.biquads)
        engine = ChainEngine(shared: shared, sampleRate: 48000, tapChannels: 2, outMap: outMap, auSlots: auSlots)
        outChannels = outMap.count
    }

    /// Feeds `seconds` of a stereo signal; returns every output channel.
    func run(seconds: Double, left: @escaping (Double) -> Double, right: ((Double) -> Double)? = nil) -> [[Float]] {
        let input = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: block * outChannels)
        defer { input.deallocate(); output.deallocate() }
        var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(block * 8), mData: input))
        var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(outChannels),
                                                                               mDataByteSize: UInt32(block * 4 * outChannels), mData: output))
        var result = [[Float]](repeating: [], count: outChannels)
        let blocks = Int(seconds * sampleRate) / block
        for b in 0..<blocks {
            for f in 0..<block {
                let t = Double(b * block + f) / sampleRate
                input[2 * f] = Float(left(t))
                input[2 * f + 1] = Float((right ?? left)(t))
            }
            engine.process(input: &inList, output: &outList)
            for c in 0..<outChannels { for f in 0..<block { result[c].append(output[f * outChannels + c]) } }
        }
        return result
    }

    static func sine(_ freq: Double, _ amp: Double) -> (Double) -> Double { { amp * sin(2 * .pi * freq * $0) } }
}

/// Peak of the last `seconds` (steady state).
func tailPeak(_ x: [Float], seconds: Double = 0.25) -> Float {
    x.suffix(Int(seconds * 48000)).map(abs).max() ?? 0
}

func db(_ ratio: Float) -> Float { 20 * log10(max(ratio, 1e-9)) }

final class DSPTests: XCTestCase {
    func testUnityIsBitTransparentAfterLatency() {
        let out = EngineHarness().run(seconds: 0.5, left: EngineHarness.sine(440, 0.5))
        XCTAssertEqual(tailPeak(out[0]), 0.5, accuracy: 0.001)
    }

    func testVolumeGain() {
        let out = EngineHarness(gain: 0.5).run(seconds: 0.5, left: EngineHarness.sine(440, 0.4))
        XCTAssertEqual(tailPeak(out[0]), 0.2, accuracy: 0.002)
    }

    func testMuteIsSilent() {
        let out = EngineHarness(gain: 0).run(seconds: 0.3, left: EngineHarness.sine(440, 0.8))
        XCTAssertEqual(tailPeak(out[0]), 0)
    }

    func testFadeInTakesRequestedTime() {
        // Start muted, then ask for full volume over 1 second.
        let h = EngineHarness(gain: 0)
        _ = h.run(seconds: 0.1, left: EngineHarness.sine(440, 0.5))
        h.shared.publish(gain: 1, fadeSeconds: 1.0, outputEnabled: true, stages: [], biquads: [])
        let out = h.run(seconds: 0.5, left: EngineHarness.sine(440, 0.5))
        let midway = out[0].suffix(4800).map(abs).max()!   // around 0.5 s into the fade
        XCTAssertEqual(midway, 0.25, accuracy: 0.03, "should be about halfway after half the fade time")
    }

    func testLimiterKeepsPeaksSafeAt6x() {
        let out = EngineHarness(gain: 6).run(seconds: 1, left: EngineHarness.sine(110, 0.9))
        XCTAssertLessThanOrEqual(tailPeak(out[0]), 0.95)
        XCTAssertGreaterThan(tailPeak(out[0]), 0.9)
    }

    func testEQBandBoostsItsFrequencyOnly() {
        var eq = EQ10()
        eq.gains[5] = 6   // 1 kHz
        let h = EngineHarness(effects: [EffectConfig(kind: .eq10(eq))])
        let at1k = tailPeak(h.run(seconds: 0.5, left: EngineHarness.sine(1000, 0.1))[0])
        XCTAssertEqual(db(at1k / 0.1), 6, accuracy: 0.3)
        let h2 = EngineHarness(effects: [EffectConfig(kind: .eq10(eq))])
        let at60 = tailPeak(h2.run(seconds: 0.5, left: EngineHarness.sine(60, 0.1))[0])
        XCTAssertEqual(db(at60 / 0.1), 0, accuracy: 0.3)
    }

    func testEQPreamp() {
        var eq = EQ10()
        eq.preampDB = -6
        let out = EngineHarness(effects: [EffectConfig(kind: .eq10(eq))]).run(seconds: 0.3, left: EngineHarness.sine(440, 0.4))
        XCTAssertEqual(db(tailPeak(out[0]) / 0.4), -6, accuracy: 0.1)
    }

    func testBypassedEffectDoesNothing() {
        var eq = EQ10()
        eq.gains = Array(repeating: 12, count: 10)
        let out = EngineHarness(effects: [EffectConfig(kind: .eq10(eq), bypassed: true)]).run(seconds: 0.3, left: EngineHarness.sine(440, 0.3))
        XCTAssertEqual(tailPeak(out[0]), 0.3, accuracy: 0.001)
    }

    func testParametricFilters() {
        let hp = ParametricEQ(name: "hp", preampDB: 0, filters: [FilterSpec(type: .highPass, freq: 1000, gainDB: 0, q: 0.707)])
        let low = tailPeak(EngineHarness(effects: [EffectConfig(kind: .parametric(hp))]).run(seconds: 0.5, left: EngineHarness.sine(100, 0.5))[0])
        XCTAssertLessThan(db(low / 0.5), -35, "100 Hz should be cut hard by a 1 kHz high-pass")
        let shelf = ParametricEQ(name: "ls", preampDB: 0, filters: [FilterSpec(type: .lowShelf, freq: 200, gainDB: 6, q: 0.7)])
        let bass = tailPeak(EngineHarness(effects: [EffectConfig(kind: .parametric(shelf))]).run(seconds: 0.5, left: EngineHarness.sine(40, 0.1))[0])
        XCTAssertEqual(db(bass / 0.1), 6, accuracy: 0.5)
        let treble = tailPeak(EngineHarness(effects: [EffectConfig(kind: .parametric(shelf))]).run(seconds: 0.5, left: EngineHarness.sine(5000, 0.1))[0])
        XCTAssertEqual(db(treble / 0.1), 0, accuracy: 0.3)
    }

    func testBalance() {
        let fx = EffectConfig(kind: .balancePan(BalancePan(mode: .balance, value: 0.5)))
        let out = EngineHarness(effects: [fx]).run(seconds: 0.3, left: EngineHarness.sine(440, 0.4))
        XCTAssertEqual(tailPeak(out[0]), 0.2, accuracy: 0.002, "left halved")
        XCTAssertEqual(tailPeak(out[1]), 0.4, accuracy: 0.002, "right untouched")
    }

    func testPanFullLeft() {
        let fx = EffectConfig(kind: .balancePan(BalancePan(mode: .pan, value: -1)))
        let out = EngineHarness(effects: [fx]).run(seconds: 0.3, left: EngineHarness.sine(440, 0.3))
        XCTAssertGreaterThan(tailPeak(out[0]), 0.4)
        XCTAssertLessThan(tailPeak(out[1]), 0.001)
    }

    func testMagicBoostLiftsQuietLeavesLoud() {
        let fx = EffectConfig(kind: .magicBoost(MagicBoost(amount: 1)))
        let quiet = tailPeak(EngineHarness(effects: [fx]).run(seconds: 4, left: EngineHarness.sine(440, 0.02))[0])
        XCTAssertGreaterThan(quiet / 0.02, 4, "quiet sound should be lifted a lot")
        let loud = tailPeak(EngineHarness(effects: [fx]).run(seconds: 4, left: EngineHarness.sine(440, 0.6))[0])
        XCTAssertEqual(loud, 0.6, accuracy: 0.05, "loud sound should stay about the same")
    }

    func testChannelMaps() {
        let l = EngineHarness.sine(440, 0.5), r = EngineHarness.sine(440, 0.1)
        let swapped = EngineHarness(outMap: [1, 0]).run(seconds: 0.3, left: l, right: r)
        XCTAssertEqual(tailPeak(swapped[0]), 0.1, accuracy: 0.002)
        XCTAssertEqual(tailPeak(swapped[1]), 0.5, accuracy: 0.002)
        let quad = EngineHarness(outMap: [0, 1, 0, 1]).run(seconds: 0.3, left: l, right: r)
        XCTAssertEqual(tailPeak(quad[2]), 0.5, accuracy: 0.002)
        XCTAssertEqual(tailPeak(quad[3]), 0.1, accuracy: 0.002)
        let mono = EngineHarness(outMap: [2, -1]).run(seconds: 0.3, left: l, right: r)
        XCTAssertEqual(tailPeak(mono[0]), 0.3, accuracy: 0.002, "mono mix = (L+R)/2")
        XCTAssertEqual(tailPeak(mono[1]), 0)
    }

    func testMetersReportPeak() {
        let h = EngineHarness()
        _ = h.run(seconds: 0.2, left: EngineHarness.sine(440, 0.5))
        let (l, r) = h.shared.takeMeters()
        XCTAssertEqual(l, 0.5, accuracy: 0.01)
        XCTAssertEqual(r, 0.5, accuracy: 0.01)
        XCTAssertEqual(h.shared.takeMeters().0, 0, "meters reset after reading")
    }

    func testChangingEffectsWhilePlayingStaysFinite() {
        let h = EngineHarness()
        for i in 0..<20 {
            var eq = EQ10()
            eq.gains = (0..<10).map { _ in Double.random(in: -12...12) }
            let c = ChainCompiler.compile([EffectConfig(kind: .eq10(eq))], sampleRate: 48000) { _ in nil }
            h.shared.publish(gain: Float(i % 4) * 0.5, fadeSeconds: 0.015, outputEnabled: true, stages: c.stages, biquads: c.biquads)
            let out = h.run(seconds: 0.05, left: EngineHarness.sine(300, 0.5))
            XCTAssertTrue(out[0].allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    /// Hosts Apple's Low Pass Audio Unit inside the chain, like a third-party plug-in.
    func testAudioUnitPlugin() throws {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_LowPassFilter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let unit = try AUAudioUnit(componentDescription: desc, options: [])
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 4096
        unit.inputBusses[0].isEnabled = true
        unit.outputBusses[0].isEnabled = true
        try unit.allocateRenderResources()
        unit.parameterTree?.parameter(withAddress: AUParameterAddress(kLowPassParam_CutoffFrequency))?.value = 500

        let id = UUID()
        let fx = EffectConfig(id: id, kind: .audioUnit(AUEffect(type: desc.componentType, subType: desc.componentSubType,
                                                                 manufacturer: desc.componentManufacturer, name: "AULowpass")))
        let slot = AUSlot(unit: unit)
        let high = tailPeak(EngineHarness(effects: [fx], auSlots: [slot], auIndex: [id: 0]).run(seconds: 0.5, left: EngineHarness.sine(8000, 0.5))[0])
        XCTAssertLessThan(db(high / 0.5), -20, "8 kHz should be filtered out by the plug-in")
        let low = tailPeak(EngineHarness(effects: [fx], auSlots: [slot], auIndex: [id: 0]).run(seconds: 0.5, left: EngineHarness.sine(100, 0.5))[0])
        XCTAssertEqual(db(low / 0.5), 0, accuracy: 1.5, "100 Hz should pass")
    }
}
