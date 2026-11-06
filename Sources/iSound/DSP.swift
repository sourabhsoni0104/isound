import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// MARK: - Filters

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peak = "PK", lowShelf = "LSC", highShelf = "HSC", lowPass = "LP", highPass = "HP"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low pass"
        case .highPass: "High pass"
        }
    }
}

struct FilterSpec: Codable, Hashable {
    var type: FilterType
    var freq: Double
    var gainDB: Double
    var q: Double
}

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    /// RBJ "Audio EQ Cookbook" filters.
    static func design(_ f: FilterSpec, sampleRate fs: Double) -> Biquad {
        let freq = min(max(f.freq, 10), fs * 0.49)
        let A = pow(10, f.gainDB / 40)
        let w0 = 2 * Double.pi * freq / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(f.q, 0.05))
        let sA = sqrt(A)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch f.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cw + 2 * sA * alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cw)
            b2 = A * ((A + 1) - (A - 1) * cw - 2 * sA * alpha)
            a0 = (A + 1) + (A - 1) * cw + 2 * sA * alpha
            a1 = -2 * ((A - 1) + (A + 1) * cw)
            a2 = (A + 1) + (A - 1) * cw - 2 * sA * alpha
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cw + 2 * sA * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cw)
            b2 = A * ((A + 1) + (A - 1) * cw - 2 * sA * alpha)
            a0 = (A + 1) - (A - 1) * cw + 2 * sA * alpha
            a1 = 2 * ((A - 1) - (A + 1) * cw)
            a2 = (A + 1) - (A - 1) * cw - 2 * sA * alpha
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                      a1: Float(a1 / a0), a2: Float(a2 / a0))
    }
}

// MARK: - Chain description shared between the main thread and the audio thread

/// One processing step. Plain values only so the audio thread can read it without locks.
struct Stage {
    enum Op: Int32 { case biquads = 1, audioUnit, balance, pan, boost }
    var op: Int32 = 0
    var i0: Int32 = 0     // biquads: first index | audioUnit: slot index
    var i1: Int32 = 0     // biquads: count
    var p0: Float = 1     // biquads: preamp | balance/pan: left gain | boost: max gain
    var p1: Float = 1     // balance/pan: right gain | boost: target level
}

struct ChainScalars {
    var gain: Float = 1
    var fadeSeconds: Float = 0.015
    var stageCount: Int32 = 0
    var layout: Int32 = 0       // changes when the filter/stage structure changes (resets filter memory)
    var outputEnabled: Int32 = 1
}

/// Lock-free (triple-buffered) handoff of the effect chain from the UI to the audio thread,
/// plus level meters going the other way.
final class ChainShared {
    static let maxStages = 32
    static let maxBiquads = 128
    private static let slots = 3

    let scalars = UnsafeMutablePointer<ChainScalars>.allocate(capacity: slots)
    let stages = UnsafeMutablePointer<Stage>.allocate(capacity: slots * maxStages)
    let biquads = UnsafeMutablePointer<Biquad>.allocate(capacity: slots * maxBiquads)
    let published = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Peak levels written by the audio thread, read+reset by the UI. [L, R]
    let meters = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    private var lastKey: [Int32] = []
    private var layoutCounter: Int32 = 0

    init() {
        scalars.initialize(repeating: ChainScalars(), count: Self.slots)
        stages.initialize(repeating: Stage(), count: Self.slots * Self.maxStages)
        biquads.initialize(repeating: Biquad(), count: Self.slots * Self.maxBiquads)
        published.initialize(to: 0)
        meters.initialize(repeating: 0, count: 2)
    }

    deinit {
        scalars.deallocate(); stages.deallocate(); biquads.deallocate()
        published.deallocate(); meters.deallocate()
    }

    func publish(gain: Float, fadeSeconds: Float, outputEnabled: Bool, stages newStages: [Stage], biquads newBiquads: [Biquad]) {
        let slot = Int((published.pointee + 1) % Int32(Self.slots))
        let stageCount = min(newStages.count, Self.maxStages)
        let key = newStages.prefix(stageCount).flatMap { [$0.op, $0.i0, $0.i1] }
        if key != lastKey { layoutCounter &+= 1; lastKey = key }

        for i in 0..<stageCount { stages[slot * Self.maxStages + i] = newStages[i] }
        for i in 0..<min(newBiquads.count, Self.maxBiquads) { biquads[slot * Self.maxBiquads + i] = newBiquads[i] }
        scalars[slot] = ChainScalars(gain: gain, fadeSeconds: fadeSeconds, stageCount: Int32(stageCount),
                                     layout: layoutCounter, outputEnabled: outputEnabled ? 1 : 0)
        published.pointee = Int32(slot)
    }

    /// Returns and clears the peak levels since the last call.
    func takeMeters() -> (Float, Float) {
        let v = (meters[0], meters[1])
        meters[0] = 0; meters[1] = 0
        return v
    }
}

// MARK: - Audio Unit slot (runs a hosted plug-in inside the chain)

final class AUSlot {
    let unit: AUAudioUnit
    let render: AURenderBlock
    let pull: AURenderPullInputBlock
    /// The pull block hands the AU whatever buffers `source` points at.
    let source = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
    let outList: UnsafeMutableAudioBufferListPointer

    init(unit: AUAudioUnit) {
        self.unit = unit
        render = unit.renderBlock
        source.initialize(repeating: nil, count: 2)
        outList = AudioBufferList.allocate(maximumBuffers: 2)
        let src = source
        pull = { _, _, frames, _, list in
            let abl = UnsafeMutableAudioBufferListPointer(list)
            for i in 0..<min(abl.count, 2) {
                guard let s = src[i] else { continue }
                let bytes = Int(frames) * MemoryLayout<Float>.size
                if let d = abl[i].mData {
                    memcpy(d, s, bytes)
                } else {
                    abl[i].mData = UnsafeMutableRawPointer(s)
                }
                abl[i].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
    }

    deinit {
        source.deallocate()
        free(outList.unsafeMutablePointer)
    }
}

// MARK: - Real-time engine (audio thread only)

final class ChainEngine {
    static let maxFrames = 4096

    let shared: ChainShared
    private let sampleRate: Float
    private let outMap: [Int32]           // per aggregate output channel: 0 = L, 1 = R, 2 = mono mix, -1 = silent
    private let auSlots: [AUSlot]
    private let tapChannels: Int

    private var current: Float = 0
    private var rampStep: Float = 0
    private var rampTarget: Float = -1
    // Look-ahead limiter: sees peaks 2.5 ms early and turns down smoothly before they arrive.
    private static let ring = 1024
    private let lookahead: Int
    private let dl: UnsafeMutablePointer<Float>
    private let dr: UnsafeMutablePointer<Float>
    private let dqVal: UnsafeMutablePointer<Float>
    private let dqIdx: UnsafeMutablePointer<Int>
    private var dqHead = 0, dqCount = 0
    private var n = 0
    private var limGain: Float = 1
    private let attackCoeff: Float
    private let releaseCoeff: Float
    private var layout: Int32 = -1
    private var sampleTime: Float64 = 0

    private let z: UnsafeMutablePointer<Float>          // biquad memory: [biquad][channel][2]
    private let boostEnv: UnsafeMutablePointer<Float>
    private let boostGain: UnsafeMutablePointer<Float>
    private var l: UnsafeMutablePointer<Float>
    private var r: UnsafeMutablePointer<Float>
    private var l2: UnsafeMutablePointer<Float>
    private var r2: UnsafeMutablePointer<Float>

    init(shared: ChainShared, sampleRate: Double, tapChannels: Int, outMap: [Int32], auSlots: [AUSlot]) {
        self.shared = shared
        self.sampleRate = Float(sampleRate)
        self.tapChannels = max(1, tapChannels)
        self.outMap = outMap
        self.auSlots = auSlots
        lookahead = min(Self.ring / 2, max(16, Int(0.0025 * sampleRate)))
        attackCoeff = Float(exp(-1.0 / (Double(lookahead) / 5)))
        releaseCoeff = Float(exp(-1.0 / (0.2 * max(sampleRate, 8000))))
        dl = .allocate(capacity: Self.ring); dl.initialize(repeating: 0, count: Self.ring)
        dr = .allocate(capacity: Self.ring); dr.initialize(repeating: 0, count: Self.ring)
        dqVal = .allocate(capacity: Self.ring); dqVal.initialize(repeating: 1, count: Self.ring)
        dqIdx = .allocate(capacity: Self.ring); dqIdx.initialize(repeating: 0, count: Self.ring)
        z = .allocate(capacity: ChainShared.maxBiquads * 4); z.initialize(repeating: 0, count: ChainShared.maxBiquads * 4)
        boostEnv = .allocate(capacity: ChainShared.maxStages); boostEnv.initialize(repeating: 0, count: ChainShared.maxStages)
        boostGain = .allocate(capacity: ChainShared.maxStages); boostGain.initialize(repeating: 1, count: ChainShared.maxStages)
        l = .allocate(capacity: Self.maxFrames); r = .allocate(capacity: Self.maxFrames)
        l2 = .allocate(capacity: Self.maxFrames); r2 = .allocate(capacity: Self.maxFrames)
        current = shared.scalars[Int(shared.published.pointee)].gain
    }

    deinit {
        z.deallocate(); boostEnv.deallocate(); boostGain.deallocate()
        l.deallocate(); r.deallocate(); l2.deallocate(); r2.deallocate()
        dl.deallocate(); dr.deallocate(); dqVal.deallocate(); dqIdx.deallocate()
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buf in outs { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        // The tap's buffers are the last ones in the input list.
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var first = ins.count, inCh = 0
        while first > 0 && inCh < tapChannels { first -= 1; inCh += Int(ins[first].mNumberChannels) }
        guard inCh > 0 else { return }
        var frames = Self.maxFrames
        for i in first..<ins.count {
            guard ins[i].mData != nil else { return }
            frames = min(frames, Int(ins[i].mDataByteSize) / (4 * max(1, Int(ins[i].mNumberChannels))))
        }
        for buf in outs where buf.mData != nil && buf.mNumberChannels > 0 {
            frames = min(frames, Int(buf.mDataByteSize) / (4 * Int(buf.mNumberChannels)))
        }
        guard frames > 0 else { return }
        defer { sampleTime += Float64(frames) }

        deinterleave(ins, first: first, channels: inCh, frames: frames)

        let slot = Int(shared.published.pointee)
        let sc = shared.scalars[slot]
        if sc.layout != layout {
            layout = sc.layout
            z.update(repeating: 0, count: ChainShared.maxBiquads * 4)
            boostEnv.update(repeating: 0, count: ChainShared.maxStages)
            boostGain.update(repeating: 1, count: ChainShared.maxStages)
        }

        // Gain ramp setup.
        if sc.gain != rampTarget {
            rampTarget = sc.gain
            let n = max(1, sc.fadeSeconds * sampleRate)
            rampStep = (rampTarget - current) / n
        }
        let silent = current == 0 && rampTarget == 0

        if !silent {
            let stageBase = slot * ChainShared.maxStages
            for s in 0..<Int(sc.stageCount) {
                runStage(shared.stages[stageBase + s], index: s, slot: slot, frames: frames)
            }
        }

        // Volume, limiter, meters, output.
        var peakL: Float = 0, peakR: Float = 0
        let threshold: Float = 0.94
        let mask = Self.ring - 1
        for f in 0..<frames {
            if current != rampTarget {
                current += rampStep
                if (rampStep > 0 && current > rampTarget) || (rampStep < 0 && current < rampTarget) || rampStep == 0 {
                    current = rampTarget
                }
            }
            let a = l[f] * current, b = r[f] * current
            let peak = max(abs(a), abs(b))
            let req: Float = peak > threshold ? threshold / peak : 1

            // Sliding minimum of the required gain over the look-ahead window.
            while dqCount > 0 && dqVal[(dqHead + dqCount - 1) & mask] >= req { dqCount -= 1 }
            dqVal[(dqHead + dqCount) & mask] = req
            dqIdx[(dqHead + dqCount) & mask] = n
            dqCount += 1
            while dqIdx[dqHead & mask] < n - lookahead { dqHead = (dqHead + 1) & mask; dqCount -= 1 }
            let hold = dqVal[dqHead & mask]
            limGain = hold < limGain ? hold + (limGain - hold) * attackCoeff : hold + (limGain - hold) * releaseCoeff

            // Delay the audio by the look-ahead so the gain is already down when the peak arrives.
            let w = n & mask
            dl[w] = a; dr[w] = b
            let rd = (n - lookahead) & mask
            let oa = min(max(dl[rd] * limGain, -1), 1)
            let ob = min(max(dr[rd] * limGain, -1), 1)
            n &+= 1
            l[f] = oa; r[f] = ob
            peakL = max(peakL, abs(oa)); peakR = max(peakR, abs(ob))
        }
        if silent {
            peakL = 0; peakR = 0
            dl.update(repeating: 0, count: Self.ring); dr.update(repeating: 0, count: Self.ring)
        }
        shared.meters[0] = max(shared.meters[0], peakL)
        shared.meters[1] = max(shared.meters[1], peakR)

        guard sc.outputEnabled != 0, !silent else { return }
        var oc = 0
        for buf in outs {
            let n = Int(buf.mNumberChannels)
            defer { oc += n }
            guard let d = buf.mData, n > 0 else { continue }
            let out = d.assumingMemoryBound(to: Float.self)
            for c in 0..<n {
                let src = oc + c < outMap.count ? outMap[oc + c] : -1
                guard src >= 0 else { continue }
                if src == 2 {   // mono mix
                    for f in 0..<frames { out[f * n + c] = 0.5 * (l[f] + r[f]) }
                    continue
                }
                let p = src == 0 ? l : r
                for f in 0..<frames { out[f * n + c] = p[f] }
            }
        }
    }

    private func deinterleave(_ ins: UnsafeMutableAudioBufferListPointer, first: Int, channels: Int, frames: Int) {
        if ins.count - first == 1 {
            let n = Int(ins[first].mNumberChannels)
            let p = ins[first].mData!.assumingMemoryBound(to: Float.self)
            if n == 1 {
                for f in 0..<frames { l[f] = p[f]; r[f] = p[f] }
            } else {
                for f in 0..<frames { l[f] = p[f * n]; r[f] = p[f * n + 1] }
            }
        } else {
            // Planar or mixed: first channel of the first two buffers.
            let p0 = ins[first].mData!.assumingMemoryBound(to: Float.self)
            let n0 = Int(ins[first].mNumberChannels)
            let p1 = ins[first + 1].mData!.assumingMemoryBound(to: Float.self)
            let n1 = Int(ins[first + 1].mNumberChannels)
            for f in 0..<frames { l[f] = p0[f * n0]; r[f] = p1[f * n1] }
        }
    }

    private func runStage(_ st: Stage, index: Int, slot: Int, frames: Int) {
        switch Stage.Op(rawValue: st.op) {
        case .biquads:
            let pre = st.p0
            if pre != 1 { for f in 0..<frames { l[f] *= pre; r[f] *= pre } }
            let base = slot * ChainShared.maxBiquads
            for k in Int(st.i0)..<min(Int(st.i0 + st.i1), ChainShared.maxBiquads) {
                let q = shared.biquads[base + k]
                filter(l, frames, q, z + k * 4)
                filter(r, frames, q, z + k * 4 + 2)
            }
        case .balance, .pan:
            if st.op == Stage.Op.pan.rawValue {
                for f in 0..<frames { let m = 0.5 * (l[f] + r[f]); l[f] = m * st.p0; r[f] = m * st.p1 }
            } else {
                for f in 0..<frames { l[f] *= st.p0; r[f] *= st.p1 }
            }
        case .boost:
            // Upward compressor: lifts quiet passages toward `target`, leaves loud ones alone.
            let maxGain = st.p0, target = st.p1
            let att = Float(exp(-1.0 / (0.010 * Double(sampleRate))))
            let rel = Float(exp(-1.0 / (0.400 * Double(sampleRate))))
            let gainUp = Float(exp(-1.0 / (0.800 * Double(sampleRate))))
            let gainDown = Float(exp(-1.0 / (0.020 * Double(sampleRate))))
            var env = boostEnv[index], g = boostGain[index]
            let gate: Float = 0.001
            for f in 0..<frames {
                let x = max(abs(l[f]), abs(r[f]))
                env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x
                var want: Float = env > gate ? min(max(target / env, 1), maxGain) : 1
                if !want.isFinite { want = 1 }
                g = want > g ? gainUp * g + (1 - gainUp) * want : gainDown * g + (1 - gainDown) * want
                l[f] *= g; r[f] *= g
            }
            boostEnv[index] = env; boostGain[index] = g
        case .audioUnit:
            let i = Int(st.i0)
            guard i < auSlots.count else { return }
            renderAU(auSlots[i], frames: frames)
        case .none:
            break
        }
    }

    @inline(__always)
    private func filter(_ x: UnsafeMutablePointer<Float>, _ n: Int, _ q: Biquad, _ s: UnsafeMutablePointer<Float>) {
        var z1 = s[0], z2 = s[1]
        for f in 0..<n {
            let i = x[f]
            let o = q.b0 * i + z1
            z1 = q.b1 * i - q.a1 * o + z2
            z2 = q.b2 * i - q.a2 * o
            x[f] = o
        }
        if !z1.isFinite || !z2.isFinite { z1 = 0; z2 = 0 }
        s[0] = z1; s[1] = z2
    }

    private func renderAU(_ au: AUSlot, frames: Int) {
        au.source[0] = l; au.source[1] = r
        let out = au.outList
        out.count = 2
        out[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(l2))
        out[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(r2))
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        let status = au.render(&flags, &ts, AUAudioFrameCount(frames), 0, out.unsafeMutablePointer, au.pull)
        guard status == noErr else { return }   // on failure, pass audio through untouched
        // The AU may have pointed the buffers at its own memory.
        let ol = out[0].mData?.assumingMemoryBound(to: Float.self) ?? l2
        let or = out[1].mData?.assumingMemoryBound(to: Float.self) ?? r2
        if ol != l { memcpy(l, ol, frames * 4) }
        if or != r { memcpy(r, or, frames * 4) }
    }
}
