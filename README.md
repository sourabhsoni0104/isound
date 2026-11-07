# iSound

A per-app volume mixer that lives in the macOS menu bar.

It started with a simple annoyance: on a WhatsApp or FaceTime call, macOS turns every other sound way down, so the music is either too quiet or the caller is too loud. iSound gives every app its own volume slider, so you can turn the call down and the music up (or the other way round), and it lets you push any app past 100%.

## Features

**Per-app control**
- Volume slider for every app that plays sound, from 0% to 400%
- Mute, timed mute ("mute for 15 minutes") and smooth fade back in
- Send any app to a different output, e.g. music to the speakers and the call to your headphones
- System sources shown by name: Sound Effects, FaceTime calls, Siri, VoiceOver, Text to Speech, Background Sounds
- Favorites, nicknames and per-app menu bar icons

**Calls**
- Spots when a call is active (WhatsApp, FaceTime, Zoom, Teams, Slack, Discord, browsers, …)
- Keeps every app's level independent while macOS ducks other audio
- A "During calls" slider that makes up for the ducking

**Effects** (per app or per device)
- 10-band EQ with preamp and presets
- Headphone EQ: search and import profiles from the [AutoEq](https://github.com/jaakkopasanen/AutoEq) project, or load an AutoEq / Equalizer APO / REW filter file
- Magic Boost, balance and pan
- Any Audio Unit plug-in installed on your Mac (including Apple's Voice Isolation), in chains with bypass, presets, copy/move and latency warnings
- A built-in limiter so boosted audio stays clean instead of clipping

**Devices**
- System output volume, mic volume and mic mute, alert volume
- Devices window: volume, balance, sample rate, nicknames, icons, battery level, hide, lock volume, max volume
- Software volume for devices without a hardware volume control
- Output groups (play to several devices at once)
- Preferred device order, output-only Bluetooth devices (stops headphones from switching to the low-quality call mode), auto-reconnect
- Channel selection for multichannel interfaces

**Everyday use**
- Global keyboard shortcuts for volume, mute, mic mute, switching devices and quick configs
- Super volume keys: the media keys control iSound
- Quick configs: save and restore a whole setup in one click
- Level meters, a compact view, undo/redo, accent colors, light and dark mode
- Liquid Glass on macOS 26, with full keyboard navigation and VoiceOver labels

## Requirements

- macOS 15 or later (per-app audio uses Core Audio process taps)
- Xcode command-line tools / Swift 5.9+

## Build and run

```bash
./build.sh
open build/iSound.app
```

`build.sh` builds a release binary, wraps it in `build/iSound.app` and signs it with your Apple Development identity if you have one, otherwise it signs ad hoc. A stable signature matters: with ad-hoc signing macOS forgets the audio permission on every rebuild.

On first launch macOS asks for:
- **Audio capture**: required, so iSound can adjust each app's sound
- **Microphone**: only for the mic level meter and controls
- **Accessibility**: only if you turn on super volume keys

## How it works

For each app you adjust, iSound creates a Core Audio process tap that takes over that app's audio. It then runs the sound through its own processing (volume, effects, limiter) and plays it on the chosen output. Apps left at 100% with no effects aren't touched at all.

To go above 100% without distortion, iSound raises the device's hardware volume and lowers the other apps to match, so nothing has to be digitally amplified past full scale. The original volume comes back when you quit, and also after a crash.

Settings are stored in `~/Library/Application Support/iSound/settings.json`.

## Tests

```bash
swift test
```

The tests cover the DSP (gain, limiter, EQ, Audio Unit hosting), filter-file parsing, settings, app detection and real device handling. Quit iSound before running them: the output group test creates a real device, and a running iSound would remove it.

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/iSound/MixerModel.swift` | Core logic: apps, calls, taps, gain and headroom |
| `Sources/iSound/AppTap.swift` | Process tap + private aggregate device per app |
| `Sources/iSound/DSP.swift` | Real-time engine: filters, effects, limiter, meters |
| `Sources/iSound/Effects.swift` | Effect types, chain compiler, EQ file parser |
| `Sources/iSound/AudioDevices.swift` | Devices, groups, volume locks, preferred order |
| `Sources/iSound/AUHost.swift` | Audio Unit plug-in hosting |
| `Sources/iSound/*View.swift` | SwiftUI menu bar mixer, devices window, settings |
| `Tests/iSoundTests` | Unit and device tests |
