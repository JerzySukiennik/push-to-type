# PushToType

Hold ⌘T, speak, let go — the text lands in whatever field you were typing into.
Like push-to-talk, except it outputs words instead of audio.

Everything runs on your Mac. No account, no cloud, no subscription, no telemetry.
Speech never leaves the machine.

```
    ⌘T ↓            speak              ⌘T ↑           text appears
  ───────────────────────────────────────────────────────────────▶
    record       transcribe as you go    finish        insert
```

---

## What it is

- **Native.** Swift 6, SwiftUI, AppKit. No Electron, no Python, no Node.
- **Offline.** [whisper.cpp](https://github.com/ggml-org/whisper.cpp) is compiled into the
  app; only the model file is downloaded, once, from Hugging Face.
- **Invisible when idle.** A menu bar glyph, ~50 MB of RAM, and no CPU at all. No timers,
  no polling, no event tap.
- **Fast on release.** While you hold the key, finished phrases are transcribed in the
  background. Letting go only has to process the last few words.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Command Line Tools are enough — Xcode is not required)
- CMake, to build whisper.cpp: `brew install cmake`

## Build

```bash
git clone --recurse-submodules https://github.com/JerzySukiennik/push-to-type.git
cd push-to-type
./Scripts/build-app.sh
open build/PushToType.app
```

`build-app.sh` compiles whisper.cpp into static libraries on the first run (a few minutes),
builds the Swift package, assembles `build/PushToType.app`, and signs it ad-hoc.

`./Scripts/run.sh` does the same and relaunches the app, quitting any running copy first —
two instances would both grab the hotkey and only one would win.

## First run

1. The app appears in the menu bar. There is no Dock icon and no window.
2. macOS asks for **Microphone** access the first time you dictate.
3. **Accessibility** access must be granted manually, in
   System Settings › Privacy & Security › Accessibility. The app cannot type into other
   applications without it.
4. The **base.en** model (141 MB) downloads on first use; the HUD shows the progress and
   recording continues while it does.

Ad-hoc signatures change every time the binary is rebuilt, so macOS asks for Accessibility
again after each rebuild. That is how TCC identifies apps, not a bug — signing with a
Developer ID certificate makes the grant stick.

## Using it

| Action | Result |
|---|---|
| Hold the shortcut | Recording. The HUD shows 🎤 and a live level meter. |
| Release it | ⚙️ briefly, then the text is inserted at the caret. |
| Hold it and say nothing | Nothing is inserted; the HUD says so and disappears. |

The menu bar item holds Language, Model, Hotkey, Launch at Login, Settings and Quit.

### The shortcut

⌘T by default, changeable in Settings. A global hotkey is exclusive: while PushToType holds
⌘T, apps that use it for "new tab" stop receiving it. If that bothers you, pick something
the system does not already use — ⌃⌥Space and ⌘⌥D are good candidates.

### Models

| Model | Size | Notes |
|---|---|---|
| `tiny.en` / `tiny` | 75 MB | Fastest, noticeably less accurate |
| `base.en` / `base` | 141 MB | Default. The right trade-off on a CPU |
| `small.en` / `small` | 465 MB | Most accurate, roughly 3× slower |

English-only models (`.en`) are faster *and* more accurate for English. Picking any other
language automatically switches to the multilingual counterpart.

### How the text gets in

1. **Accessibility API** — written straight into the focused field. Nothing touches your
   clipboard, and there is no keystroke to intercept.
2. **Clipboard fallback** — for apps that expose no editable text element (Electron,
   terminals, some web views). The full pasteboard is captured first, ⌘V is synthesised,
   and the original contents are restored a fraction of a second later.

## Diagnostics

```bash
swift run ptt-doctor
```

Checks the model file, loads it, transcribes a known sample, and reports the permissions
and input device — everything that can only fail on a real machine.

```
[  ok  ] Model file
[  ok  ] Model loaded          0.41 s
[  ok  ] Transcription         11.0 s of audio in 1.42 s (7.7× real time)
[  ok  ] Microphone permission
[ warn ] Accessibility not granted
```

## Tests

```bash
swift test    # requires Xcode: the Command Line Tools ship no test framework
```

The suite covers the pure logic — transcript clean-up, voice-activity detection, settings
invariants, the model catalog — plus an end-to-end inference test that is skipped when the
model has not been downloaded. On a machine with only the Command Line Tools, use
`ptt-doctor` instead.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/PTTSupport` | Logging, the shared error type, paths, voice-activity maths |
| `Sources/PTTSettings` | Preferences, hotkey value type, model and language catalogs |
| `Sources/PTTAudio` | `AVAudioEngine` capture, resampling, microphone permission |
| `Sources/PTTWhisper` | Model download, the whisper.cpp engine, streaming transcription |
| `Sources/PTTHotkeys` | The global press-and-hold shortcut |
| `Sources/PTTInsertion` | Accessibility insertion and the clipboard fallback |
| `Sources/PTTUI` | Menu bar, HUD panel, settings, onboarding |
| `Sources/PushToType` | Composition root and the dictation state machine |
| `Sources/PTTDoctor` | The `ptt-doctor` command |

[`ARCHITECTURE.md`](ARCHITECTURE.md) explains why each module exists and what the
performance constraints forced.

## Licence

PushToType is MIT-licensed. whisper.cpp and ggml are MIT-licensed and pinned as a
submodule; the models are released by their authors under MIT.
