import Carbon
import CoreAudio
import XCTest
@testable import iSound

final class ParserTests: XCTestCase {
    func testAutoEqFile() throws {
        let text = """
        Preamp: -6.0 dB
        Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
        Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
        Filter 3: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.70
        """
        let eq = try XCTUnwrap(FilterFileParser.parse(text, name: "AirPods Pro"))
        XCTAssertEqual(eq.preampDB, -6)
        XCTAssertEqual(eq.filters.count, 3)
        XCTAssertEqual(eq.filters[0], FilterSpec(type: .lowShelf, freq: 105, gainDB: 2.6, q: 0.7))
        XCTAssertEqual(eq.filters[1].type, .peak)
        XCTAssertEqual(eq.filters[2].type, .highShelf)
    }

    func testRoomEQWizardSpacingAndOffFilters() throws {
        let text = """
        Filter Settings file
        Filter  1: ON  PK       Fc   63.0 Hz  Gain  -3.0 dB  Q  2.00
        Filter  2: OFF PK       Fc   100 Hz  Gain  9.0 dB  Q  1.00
        Filter  3: ON  HP       Fc   20.0 Hz
        """
        let eq = try XCTUnwrap(FilterFileParser.parse(text, name: "REW"))
        XCTAssertEqual(eq.filters.count, 2, "OFF filters are skipped")
        XCTAssertEqual(eq.filters[0].freq, 63)
        XCTAssertEqual(eq.filters[1].type, .highPass)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(FilterFileParser.parse("hello\nworld", name: "x"))
    }
}

final class HeadphoneLibraryTests: XCTestCase {
    func testIndexParsing() {
        let line = "- [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711\n- [Sony WH-1000XM4](./oratory1990/over-ear/Sony%20WH-1000XM4) by oratory1990"
        let entries = HeadphoneEQLibrary.parse(line)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Apple AirPods Pro")
        XCTAssertEqual(entries[0].id, "crinacle/711%20in-ear/Apple%20AirPods%20Pro")
        XCTAssertEqual(entries[1].source, "oratory1990")
    }

    /// Downloads a real profile from the AutoEq project (needs internet).
    func testFetchRealProfile() {
        let lib = HeadphoneEQLibrary()
        let entry = HeadphoneEQLibrary.Entry(id: "crinacle/711%20in-ear/Apple%20AirPods%20Pro", name: "Apple AirPods Pro", source: "crinacle")
        let done = expectation(description: "fetch")
        var result: ParametricEQ?
        lib.fetch(entry) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.filters.count ?? 0, 3)
    }

    func testSearchMatchesAllWords() {
        let lib = HeadphoneEQLibrary()
        let entries = HeadphoneEQLibrary.parse("- [Apple AirPods Pro](./a/Apple%20AirPods%20Pro) by a\n- [Apple AirPods Max](./a/Apple%20AirPods%20Max) by a")
        lib.setEntriesForTesting(entries)
        XCTAssertEqual(lib.search("airpods max").map(\.name), ["Apple AirPods Max"])
    }
}

final class StoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("isound-test-\(UUID().uuidString).json")
    }

    func testOldOrPartialSettingsStillLoad() throws {
        let url = tempFile()
        try #"{"prefs":{"compact":true},"sources":{"x":{"volume":2}}}"#.data(using: .utf8)!.write(to: url)
        let store = Store(file: url, migrate: false)
        XCTAssertTrue(store.state.prefs.compact)
        XCTAssertEqual(store.state.prefs.callBoost, 2, "missing keys fall back to defaults")
        XCTAssertEqual(store.state.sources["x"]?.volume, 2)
        XCTAssertEqual(store.state.sources["x"]?.output, .system)
    }

    func testSaveAndReload() {
        let url = tempFile()
        let a = Store(file: url, migrate: false)
        var eq = EQ10(); eq.gains[0] = 3
        a.change { s in
            var src = SourceSettings(); src.volume = 0.5; src.effects = [EffectConfig(kind: .eq10(eq))]; src.output = .group(UUID())
            s.sources["app"] = src
            s.groups = [OutputGroup(name: "Both", deviceUIDs: ["a", "b"])]
            s.hotkeys = [HotkeyBinding(action: .appVolumeUp("app"), keyCode: 126, modifiers: UInt32(cmdKey))]
        }
        a.saveNow()
        let b = Store(file: url, migrate: false)
        XCTAssertEqual(b.state, a.state)
    }

    func testUndoGroupsSliderDrags() {
        let store = Store(file: tempFile(), migrate: false)
        for v in stride(from: Float(1), to: 2, by: 0.1) {
            store.change("drag") { $0.sources["a", default: SourceSettings()].volume = v }
        }
        store.change { $0.sources["a", default: SourceSettings()].muted = true }
        store.undo()
        XCTAssertEqual(store.state.sources["a"]?.muted, false)
        XCTAssertEqual(store.state.sources["a"]?.volume ?? 0, 1.9, accuracy: 0.001)
        store.undo()
        XCTAssertNil(store.state.sources["a"], "the whole drag undoes in one step")
        store.redo()
        XCTAssertEqual(store.state.sources["a"]?.volume ?? 0, 1.9, accuracy: 0.001)
    }

    func testUndoDoesNotTouchAppearance() {
        let store = Store(file: tempFile(), migrate: false)
        store.change { $0.sources["a"] = SourceSettings() }
        store.change(undoable: false) { $0.prefs.compact = true }
        store.undo()
        XCTAssertTrue(store.state.prefs.compact)
    }
}

final class CompilerTests: XCTestCase {
    func testSkipsFlatBandsAndUnloadedPlugins() {
        var eq = EQ10(); eq.gains[3] = 2
        let au = EffectConfig(kind: .audioUnit(AUEffect(type: 1, subType: 2, manufacturer: 3, name: "x")))
        let c = ChainCompiler.compile([EffectConfig(kind: .eq10(eq)), au], sampleRate: 48000) { _ in nil }
        XCTAssertEqual(c.biquads.count, 1, "only the non-flat band becomes a filter")
        XCTAssertEqual(c.stages.count, 1, "plug-in not loaded yet, so it's skipped")
        let c2 = ChainCompiler.compile([au], sampleRate: 48000) { _ in 0 }
        XCTAssertEqual(c2.stages.first?.op, Stage.Op.audioUnit.rawValue)
    }

    func testMagicBoostOffWhenZero() {
        let c = ChainCompiler.compile([EffectConfig(kind: .magicBoost(MagicBoost(amount: 0)))], sampleRate: 48000) { _ in nil }
        XCTAssertTrue(c.stages.isEmpty)
    }
}

final class AppDetectionTests: XCTestCase {
    func testSpecialSources() {
        XCTAssertEqual(SpecialSource.match(bundleID: nil, processName: "systemsoundserverd")?.name, "Sound Effects")
        XCTAssertEqual(SpecialSource.match(bundleID: "com.apple.avconferenced", processName: nil)?.name, "FaceTime calls")
        XCTAssertEqual(SpecialSource.match(bundleID: "com.apple.siri", processName: nil)?.name, "Siri")
        XCTAssertNil(SpecialSource.match(bundleID: "com.brave.Browser", processName: "Brave"))
    }

    func testDictationAppsAreNotCalls() {
        XCTAssertTrue(MixerModel.callApps.contains("net.whatsapp.WhatsApp"))
        XCTAssertFalse(MixerModel.callApps.contains("com.electron.wispr-flow"))
    }

    func testHelperProcessResolvesToParentApp() {
        // This test process is a child of some shell/Xcode; it must resolve to *something* named.
        let p = AudioProcess(objectID: 0, pid: getpid(), bundleID: nil, isPlaying: false, isRecording: false)
        XCTAssertFalse(AppResolver().identity(for: p).name.isEmpty)
    }
}

final class HotkeyTests: XCTestCase {
    func testDescriptions() {
        XCTAssertEqual(HotkeyCenter.describe(HotkeyBinding(action: .toggleMicMute, keyCode: 46, modifiers: UInt32(cmdKey | shiftKey))), "⇧⌘M")
        XCTAssertEqual(HotkeyCenter.describe(HotkeyBinding(action: .toggleMicMute, keyCode: 122, modifiers: 0)), "F1")
        XCTAssertEqual(HotkeyCenter.describe(HotkeyBinding(action: .toggleMicMute, keyCode: 126, modifiers: UInt32(optionKey | controlKey))), "⌃⌥↑")
    }
}

/// Polls (while letting the run loop deliver Core Audio notifications) for up to `timeout` seconds.
func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

/// Reads real devices on this Mac (read-only, except the group test which cleans up after itself).
final class DeviceTests: XCTestCase {
    private func manager() -> DeviceManager {
        DeviceManager(store: Store(file: FileManager.default.temporaryDirectory.appendingPathComponent("isound-dev-\(UUID()).json"), migrate: false))
    }

    func testListsDevicesAndDefaults() throws {
        let m = manager()
        XCTAssertFalse(m.outputs.isEmpty)
        XCTAssertFalse(m.inputs.isEmpty)
        let out = try XCTUnwrap(m.device(id: m.defaultOutput))
        XCTAssertGreaterThan(out.outputChannels, 0)
        XCTAssertFalse(m.devices.contains { $0.uid.hasPrefix(DeviceManager.privatePrefix) }, "iSound's helper devices are hidden")
        let rate = try XCTUnwrap(m.sampleRate(out.id))
        XCTAssertTrue(m.availableSampleRates(out.id).contains(rate))
    }

    func testReadsVolumes() throws {
        let m = manager()
        let out = try XCTUnwrap(m.device(id: m.defaultOutput))
        if m.hasHardwareVolume(out.id) {
            let v = try XCTUnwrap(m.hardwareVolume(out.id))
            XCTAssertTrue((0...1).contains(v))
        } else {
            XCTAssertTrue(m.usesSoftwareVolume(out))
        }
    }

    /// Creates a real multi-output group from two devices, checks it appears, then deletes it.
    func testOutputGroupLifecycle() throws {
        let m = manager()
        let members = m.outputs.filter { !$0.isGroup && $0.transport != kAudioDeviceTransportTypeAggregate }.prefix(2).map(\.uid)
        try XCTSkipIf(members.count < 2, "needs two output devices")
        let group = OutputGroup(name: "iSound Test Group", deviceUIDs: Array(members))
        m.saveGroup(group)
        XCTAssertTrue(waitFor { m.reload(); return m.device(uid: group.uid).map { Set(DeviceManager.subDeviceUIDs($0.id)) == Set(members) } ?? false },
                      "group device should appear with both members")
        m.deleteGroup(group)
        XCTAssertTrue(waitFor { m.reload(); return m.device(uid: group.uid) == nil }, "group device should be removed")
    }
}
