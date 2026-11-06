import Combine
import Foundation
import SwiftUI

// MARK: - Saved settings

enum OutputTarget: Codable, Hashable {
    case system
    case device(String)   // device UID
    case group(UUID)
}

struct SourceSettings: Codable, Equatable {
    var volume: Float = 1        // 0…4 (0–400%)
    var muted = false
    var muteUntil: Date?
    var output: OutputTarget = .system
    var effects: [EffectConfig] = []
    var favorite = false
    var menuBarIndicator = false
    /// Remembered so favourites can be shown while the app isn't running.
    var displayName: String?
    var iconPath: String?

    var gain: Float { muted ? 0 : volume }
    var hasActiveEffects: Bool { effects.contains { !$0.bypassed } }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = c.value(.volume, SourceSettings().volume)
        muted = c.value(.muted, false)
        muteUntil = c.value(.muteUntil, nil)
        output = c.value(.output, .system)
        effects = c.value(.effects, [])
        favorite = c.value(.favorite, false)
        menuBarIndicator = c.value(.menuBarIndicator, false)
        displayName = c.value(.displayName, nil)
        iconPath = c.value(.iconPath, nil)
    }

    /// True when nothing about this app differs from normal playback.
    var isNeutral: Bool {
        volume == 1 && !muted && muteUntil == nil && output == .system && !hasActiveEffects
    }
}

enum ChannelMode: String, Codable, CaseIterable, Identifiable {
    case stereo, swapped, monoLeft, monoRight, allPairs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stereo: "Stereo (L / R)"
        case .swapped: "Swapped (R / L)"
        case .monoLeft: "Left channel only"
        case .monoRight: "Right channel only"
        case .allPairs: "Copy to every channel pair"
        }
    }
}

struct DeviceSettings: Codable, Equatable {
    var nickname: String?
    var icon: String?
    var hidden = false
    var outputOnly = false
    var maxVolume: Float?
    var locked = false
    var lockedOutputVolume: Float?
    var lockedInputVolume: Float?
    var lockedSampleRate: Double?
    var forceSoftwareVolume = false
    var softwareVolume: Float = 1
    var softwareMuted = false
    var channelMode: ChannelMode = .stereo
    var channelOffset = 0          // first output channel used (0-based)
    var effects: [EffectConfig] = []
    var autoReconnect = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeviceSettings()
        nickname = c.value(.nickname, nil)
        icon = c.value(.icon, nil)
        hidden = c.value(.hidden, d.hidden)
        outputOnly = c.value(.outputOnly, d.outputOnly)
        maxVolume = c.value(.maxVolume, nil)
        locked = c.value(.locked, d.locked)
        lockedOutputVolume = c.value(.lockedOutputVolume, nil)
        lockedInputVolume = c.value(.lockedInputVolume, nil)
        lockedSampleRate = c.value(.lockedSampleRate, nil)
        forceSoftwareVolume = c.value(.forceSoftwareVolume, d.forceSoftwareVolume)
        softwareVolume = c.value(.softwareVolume, d.softwareVolume)
        softwareMuted = c.value(.softwareMuted, d.softwareMuted)
        channelMode = c.value(.channelMode, d.channelMode)
        channelOffset = c.value(.channelOffset, d.channelOffset)
        effects = c.value(.effects, [])
        autoReconnect = c.value(.autoReconnect, d.autoReconnect)
    }
}

struct OutputGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var deviceUIDs: [String]
    var uid: String { "\(DeviceManager.groupPrefix)\(id.uuidString)" }
}

struct QuickConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sources: [String: SourceSettings]
    var devices: [String: DeviceSettings]
    var defaultOutputUID: String?
    var defaultInputUID: String?
    var callBoost: Float?
}

enum HotkeyAction: Codable, Hashable {
    case toggleMicMute
    case outputVolumeUp, outputVolumeDown, toggleOutputMute
    case appVolumeUp(String), appVolumeDown(String), appToggleMute(String)
    case setOutput(String), setInput(String)
    case applyQuickConfig(UUID)
    case showMixer
}

struct HotkeyBinding: Codable, Hashable, Identifiable {
    var id = UUID()
    var action: HotkeyAction
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }
}

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case app, speaker, device, meter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .app: "iSound icon"
        case .speaker: "Volume (like Sound)"
        case .device: "Current output device"
        case .meter: "Live level meter"
        }
    }
}

struct Prefs: Codable, Equatable {
    var callBoost: Float = 2
    var smoothUnmute = true
    var recentSeconds: Double = 60
    var showMeters = true
    var compact = false
    var accent: AccentChoice = .system
    var menuBarIcon: MenuBarIconStyle = .app
    var superVolumeKeys = false
    var volumeKeyStep: Float = 1.0 / 16
    var preferredOrderEnabled = false
    var preferredOutputs: [String] = []
    var preferredInputs: [String] = []
    var moveSystemSoundsWithOutput = true
    var pinWindow = false
    var showInputMeter = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        callBoost = c.value(.callBoost, d.callBoost)
        smoothUnmute = c.value(.smoothUnmute, d.smoothUnmute)
        recentSeconds = c.value(.recentSeconds, d.recentSeconds)
        showMeters = c.value(.showMeters, d.showMeters)
        compact = c.value(.compact, d.compact)
        accent = c.value(.accent, d.accent)
        menuBarIcon = c.value(.menuBarIcon, d.menuBarIcon)
        superVolumeKeys = c.value(.superVolumeKeys, d.superVolumeKeys)
        volumeKeyStep = c.value(.volumeKeyStep, d.volumeKeyStep)
        preferredOrderEnabled = c.value(.preferredOrderEnabled, d.preferredOrderEnabled)
        preferredOutputs = c.value(.preferredOutputs, d.preferredOutputs)
        preferredInputs = c.value(.preferredInputs, d.preferredInputs)
        moveSystemSoundsWithOutput = c.value(.moveSystemSoundsWithOutput, d.moveSystemSoundsWithOutput)
        pinWindow = c.value(.pinWindow, d.pinWindow)
        showInputMeter = c.value(.showInputMeter, d.showInputMeter)
    }
}

struct AppState: Codable, Equatable {
    var sources: [String: SourceSettings] = [:]
    var devices: [String: DeviceSettings] = [:]
    var groups: [OutputGroup] = []
    var quickConfigs: [QuickConfig] = []
    var presets: [EffectPreset] = []
    var favoriteEffects: [String] = []
    var hotkeys: [HotkeyBinding] = []
    var prefs = Prefs()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = c.value(.sources, [:])
        devices = c.value(.devices, [:])
        groups = c.value(.groups, [])
        quickConfigs = c.value(.quickConfigs, [])
        presets = c.value(.presets, [])
        favoriteEffects = c.value(.favoriteEffects, [])
        hotkeys = c.value(.hotkeys, [])
        prefs = c.value(.prefs, Prefs())
    }
}

extension KeyedDecodingContainer {
    /// Missing or unreadable keys fall back to a default, so adding settings never wipes old ones.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Store

/// Holds all settings, saves them to disk, and keeps an undo history.
final class Store: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [AppState] = []
    private var redoStack: [AppState] = []
    private var lastCoalesce: (key: String, time: Date)?
    private var saveWork: DispatchWorkItem?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("iSound", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let defaultFile = directory.appendingPathComponent("settings.json")
    let file: URL

    /// `file` is only changed by tests, so they never touch real settings.
    init(file: URL = Store.defaultFile, migrate: Bool = true) {
        self.file = file
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(AppState.self, from: data) {
            state = s
        } else {
            state = AppState()
            if migrate { Self.migrateOldSettings(into: &state) }
        }
    }

    /// Changes settings. Changes sharing a `coalesce` key within a second become one undo step
    /// (so dragging a slider is undone in one go).
    func change(_ coalesce: String? = nil, undoable: Bool = true, _ body: (inout AppState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        if undoable {
            let now = Date()
            if let c = coalesce, let last = lastCoalesce, last.key == c, now.timeIntervalSince(last.time) < 1 {
                // same gesture: keep the earlier undo point
            } else {
                undoStack.append(state)
                if undoStack.count > 100 { undoStack.removeFirst() }
            }
            lastCoalesce = coalesce.map { ($0, now) }
            redoStack.removeAll()
        }
        state = next
        updateUndoFlags()
        scheduleSave()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = keepingPrefs(prev)
        lastCoalesce = nil
        updateUndoFlags()
        scheduleSave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = keepingPrefs(next)
        updateUndoFlags()
        scheduleSave()
    }

    /// Undo covers audio settings, not appearance preferences.
    private func keepingPrefs(_ s: AppState) -> AppState {
        var s = s
        s.prefs = state.prefs
        return s
    }

    private func updateUndoFlags() {
        if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func migrateOldSettings(into state: inout AppState) {
        struct Old: Codable { var volume: Float; var muted: Bool }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "appSettings"),
           let old = try? JSONDecoder().decode([String: Old].self, from: data) {
            for (k, v) in old {
                var s = SourceSettings()
                s.volume = v.volume
                s.muted = v.muted
                state.sources[k] = s
            }
        }
        let boost = defaults.float(forKey: "callBoost")
        if boost > 0 { state.prefs.callBoost = boost }
    }
}
