import AudioToolbox
import Foundation

// MARK: - Effect models (saved to disk)

struct EQ10: Codable, Hashable {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    var preampDB: Double = 0
    var gains: [Double] = Array(repeating: 0, count: 10)

    static let presets: [(String, [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Bass Cut", [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Loudness", [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        ("Podcast", [-4, -3, -1, 1, 3, 3, 2, 1, -1, -2]),
        ("Acoustic", [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]),
        ("Electronic", [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        ("Classical", [3, 2, 1, 0, 0, 0, -1, -1, 1, 2]),
        ("Rock", [4, 3, -1, -2, -1, 1, 3, 4, 4, 4]),
    ]
}

struct ParametricEQ: Codable, Hashable {
    var name = "Headphone EQ"
    var preampDB: Double = 0
    var filters: [FilterSpec] = []
}

struct BalancePan: Codable, Hashable {
    enum Mode: String, Codable { case balance, pan }
    var mode: Mode = .balance
    var value: Double = 0   // -1 (left) … 1 (right)
}

struct MagicBoost: Codable, Hashable {
    var amount: Double = 0.5   // 0…1
}

struct AUEffect: Codable, Hashable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var name: String
    var manufacturerName: String = ""
    var state: Data?

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

enum EffectKind: Codable, Hashable {
    case eq10(EQ10)
    case parametric(ParametricEQ)
    case balancePan(BalancePan)
    case magicBoost(MagicBoost)
    case audioUnit(AUEffect)

    var title: String {
        switch self {
        case .eq10: "10-Band EQ"
        case .parametric(let p): p.name
        case .balancePan(let b): b.mode == .balance ? "Balance" : "Pan"
        case .magicBoost: "Magic Boost"
        case .audioUnit(let a): a.name
        }
    }

    var symbol: String {
        switch self {
        case .eq10: "slider.vertical.3"
        case .parametric: "headphones"
        case .balancePan: "arrow.left.and.right"
        case .magicBoost: "wand.and.stars"
        case .audioUnit: "puzzlepiece.extension"
        }
    }

    var isAudioUnit: Bool { if case .audioUnit = self { return true }; return false }
}

struct EffectConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: EffectKind
    var bypassed = false
    var nickname: String?
    var displayName: String { nickname?.isEmpty == false ? nickname! : kind.title }
}

/// A named, saved effect setting.
struct EffectPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: EffectKind
}

// MARK: - Compiling an effect list into engine stages

enum ChainCompiler {
    /// `auSlotIndex` maps an AU effect id to its slot in the running tap (nil = not loaded yet: skipped).
    static func compile(_ effects: [EffectConfig], sampleRate: Double,
                        auSlotIndex: (UUID) -> Int?) -> (stages: [Stage], biquads: [Biquad]) {
        var stages: [Stage] = []
        var biquads: [Biquad] = []

        func addFilters(_ specs: [FilterSpec], preampDB: Double) {
            let start = biquads.count
            let room = ChainShared.maxBiquads - start
            let used = specs.prefix(room).filter { $0.type == .lowPass || $0.type == .highPass || abs($0.gainDB) > 0.01 }
            biquads += used.map { Biquad.design($0, sampleRate: sampleRate) }
            stages.append(Stage(op: Stage.Op.biquads.rawValue, i0: Int32(start), i1: Int32(used.count),
                                p0: Float(pow(10, preampDB / 20)), p1: 1))
        }

        for e in effects where !e.bypassed {
            switch e.kind {
            case .eq10(let eq):
                let specs = zip(EQ10.frequencies, eq.gains).map { FilterSpec(type: .peak, freq: $0, gainDB: $1, q: 1.41) }
                addFilters(specs, preampDB: eq.preampDB)
            case .parametric(let p):
                addFilters(p.filters, preampDB: p.preampDB)
            case .balancePan(let b):
                let v = min(max(b.value, -1), 1)
                if b.mode == .balance {
                    stages.append(Stage(op: Stage.Op.balance.rawValue, p0: Float(min(1, 1 - v)), p1: Float(min(1, 1 + v))))
                } else {
                    // Constant-power pan of the mono mix.
                    let angle = (v + 1) * Double.pi / 4
                    stages.append(Stage(op: Stage.Op.pan.rawValue, p0: Float(cos(angle) * sqrt(2)), p1: Float(sin(angle) * sqrt(2))))
                }
            case .magicBoost(let m):
                let amount = min(max(m.amount, 0), 1)
                guard amount > 0 else { continue }
                stages.append(Stage(op: Stage.Op.boost.rawValue,
                                    p0: Float(1 + amount * 5),     // up to 6x (+15.5 dB) for quiet parts
                                    p1: Float(0.12 + amount * 0.13)))
            case .audioUnit:
                if let slot = auSlotIndex(e.id) {
                    stages.append(Stage(op: Stage.Op.audioUnit.rawValue, i0: Int32(slot)))
                }
            }
        }
        return (Array(stages.prefix(ChainShared.maxStages)), biquads)
    }
}

// MARK: - Parsing AutoEq / Equalizer APO / REW filter files

enum FilterFileParser {
    /// Accepts lines like "Preamp: -6.2 dB" and "Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70".
    static func parse(_ text: String, name: String) -> ParametricEQ? {
        var eq = ParametricEQ(name: name)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                if let v = numbers(in: line).first { eq.preampDB = v }
                continue
            }
            guard lower.hasPrefix("filter"), lower.contains(" on ") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            func value(after key: String) -> Double? {
                guard let i = tokens.firstIndex(where: { $0.lowercased() == key }), i + 1 < tokens.count else { return nil }
                return Double(tokens[i + 1].replacingOccurrences(of: ",", with: "."))
            }
            let typeToken = tokens.first { ["pk", "peq", "lsc", "hsc", "ls", "hs", "lp", "hp", "lpq", "hpq"].contains($0.lowercased()) }?.lowercased()
            let type: FilterType
            switch typeToken {
            case "pk", "peq": type = .peak
            case "lsc", "ls": type = .lowShelf
            case "hsc", "hs": type = .highShelf
            case "lp", "lpq": type = .lowPass
            case "hp", "hpq": type = .highPass
            default: continue
            }
            guard let fc = value(after: "fc") else { continue }
            let gain = value(after: "gain") ?? 0
            let q = value(after: "q") ?? (type == .peak ? 1.0 : 0.71)
            eq.filters.append(FilterSpec(type: type, freq: fc, gainDB: gain, q: q))
        }
        return eq.filters.isEmpty ? nil : eq
    }

    private static func numbers(in s: String) -> [Double] {
        s.split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
    }
}
