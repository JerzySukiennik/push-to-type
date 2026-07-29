# PushToType — Architecture

Push-to-talk dictation for macOS. Hold ⌘T, speak, release — the transcript is inserted
into whatever text field currently has focus. Fully offline, whisper.cpp on-device.

---

## 1. Design constraints that shaped the architecture

| Constraint | Consequence |
|---|---|
| **Idle CPU ≈ 0%** | No polling anywhere. The hotkey uses Carbon's `RegisterEventHotKey` (kernel-delivered events, not an event tap, not a run-loop timer). The audio engine is *stopped*, not paused, when idle. The whisper context is created lazily on first use. |
| **Idle RAM < 150 MB (excl. model)** | Nothing is retained between dictations except the whisper context (opt-in "keep model loaded", default on) and a pre-allocated 60 s float ring buffer (≈ 3.8 MB). No AppKit windows exist while idle — the HUD panel is created on demand and released after it fades. |
| **Instant startup** | The executable links only Apple frameworks + a static `libwhisper`. Model loading, permission probing and HUD construction all happen off the launch path. |
| **No Xcode on this machine** | Only Command Line Tools are installed (`xcodebuild` unavailable). The project is therefore a **SwiftPM package** plus a small `Scripts/build-app.sh` that assembles a real `.app` bundle (Info.plist, icon, code signature). This is not a workaround — it is a fully valid native build; Xcode can open the package later unchanged. |
| **Intel Mac (i9-9880H, Radeon 5500M)** | whisper.cpp is built with `GGML_METAL=OFF`, `GGML_BLAS=ON` (Accelerate) and AVX2. Metal in ggml is Apple-Silicon-oriented; on this GPU the CPU path with Accelerate is both faster and far more predictable. |
| **Swift 6, strict concurrency** | Every module compiles under `-strict-concurrency=complete`. Mutable state lives in actors (`WhisperEngine`, `AudioRecorder`) or is `@MainActor`-isolated (UI, settings). Nothing is `@unchecked Sendable` except one audited box around the C `whisper_context` pointer, which is confined to its actor. |

---

## 2. Module map

The package is split into eight library targets plus the executable. Each target has
exactly one reason to change, and none of them import AppKit unless they must.

```
                       ┌───────────────────────────┐
                       │      PushToType (exe)     │
                       │  AppDelegate + Dictation- │
                       │  Controller (state machine)│
                       └────┬───────────┬──────────┘
              ┌─────────────┘           └──────────────┐
        ┌─────▼─────┐  ┌──────────┐  ┌──────────┐ ┌────▼─────┐
        │PTTHotkeys │  │ PTTAudio │  │PTTWhisper│ │  PTTUI   │
        └─────┬─────┘  └────┬─────┘  └────┬─────┘ └────┬─────┘
              │             │             │            │
              │        ┌────▼─────────────▼────┐  ┌────▼──────────┐
              │        │      PTTSettings      │  │ PTTInsertion  │
              │        └───────────┬───────────┘  └────┬──────────┘
              └────────────────────┼───────────────────┘
                             ┌─────▼──────┐        ┌──────────┐
                             │ PTTSupport │        │ CWhisper │
                             └────────────┘        └──────────┘
```

### `CWhisper` — C interop shim
A SwiftPM **system library target**: a `module.modulemap` exposing `whisper.h`.
The actual `libwhisper.a` + `libggml*.a` are produced by `Scripts/build-whisper.sh`
from the pinned `Vendor/whisper.cpp` submodule and linked with `unsafeFlags`.
No Swift code lives here.

### `PTTSupport` — Utilities
Zero-dependency leaf module.
- `Log` — thin `os.Logger` wrapper with per-subsystem categories (no `print`, no file I/O).
- `PTTError` — the single error enum crossing module boundaries (`.modelMissing`,
  `.microphoneDenied`, `.accessibilityDenied`, `.emptyRecording`, `.transcriptionFailed`,
  `.audioEngineFailed`, `.downloadFailed`), each with a user-facing `title`/`recovery`.
- `AppPaths` — Application Support / model directory resolution, created lazily.
- `VoiceActivity` — `vDSP`-backed RMS, peak, "is this silent", and "has the speaker paused
  long enough to cut here". It sits in the leaf module because two unrelated callers need
  it: `PTTAudio` to reject a silent recording, `PTTWhisper` to find chunk boundaries.

### `PTTSettings` — Preferences & catalogs
- `SettingsStore` — `@MainActor @Observable` façade over `UserDefaults`. Every setting
  is a typed property; SwiftUI observes it directly, other modules receive immutable
  snapshots (`SettingsSnapshot: Sendable`) so no cross-actor `UserDefaults` reads happen.
- `HotkeyBinding` — `Sendable` value type (keyCode + modifier mask) with `Codable`
  persistence and a `displayString` (`⌘T`).
- `WhisperModel` — the catalog: `.tiny/.tinyEn/.base/.baseEn/.small/.smallEn`, each with
  filename, download URL (Hugging Face `ggml-org/whisper.cpp`), size and SHA-ish label.
- `Language` — `auto` + the languages the multilingual models support; English-only
  models pin to `en` and hide the picker.

### `PTTAudio` — Capture
- `AudioRecorder` (**actor**) — `AVAudioEngine` + input tap. On `start()` it installs the
  tap, converts from the device format to **16 kHz mono Float32** with `AVAudioConverter`,
  and appends into a pre-allocated ring buffer. On `stop()` it removes the tap, stops the
  engine and returns the captured `[Float]`. Engine objects are torn down so the audio HAL
  releases the mic (no orange dot while idle).
- `MicrophonePermission` — `AVCaptureDevice.authorizationStatus/requestAccess` wrapper
  with async/await, plus the deep link to System Settings and an "is there any input
  device at all" probe, so "denied" and "unplugged" stay different errors.
- `AudioFileLoader` — decodes a file to the same 16 kHz mono format. The app never reads
  files; this exists so the diagnostics tool and the tests share one conversion path with
  the recorder instead of each carrying a copy.
- `CallLocal<Value>` — the audited box that carries a buffer into `AVAudioConverter`'s
  nominally-`@Sendable` input block, which is in fact invoked synchronously.

### `PTTWhisper` — Inference
- `ModelManager` (**actor**) — resolves the model file, downloads it with
  `URLSession.bytes` (progress → `AsyncStream<Double>`), writes atomically to a temp file,
  verifies size, moves into place. Handles cancellation and resume-on-relaunch.
- `WhisperEngine` (**actor**) — owns the `OpaquePointer` context. `load(model:)`,
  `transcribe(samples:language:)`, `unload()`. Runs `whisper_full` on a dedicated
  high-QoS thread via `withUnsafeContinuation`, with `n_threads` = performance-core count,
  greedy sampling, `no_timestamps`, `single_segment=false`, `suppress_blank`.
  Aborts through the whisper abort callback when the task is cancelled.
- `StreamingTranscriber` — the latency trick. While the key is held, audio is cut at
  silence boundaries (or at 6 s hard limit) and each finalized chunk is transcribed
  *during* the hold on a background task. On key release only the **tail** since the last
  boundary is transcribed, so perceived latency ≈ tail length, not utterance length.
  Falls back to a single full-buffer pass when streaming is disabled or a chunk fails.
- `TranscriptPostProcessor` — trims `[BLANK_AUDIO]`, `(silence)`, leading/trailing space,
  collapses whisper's double spaces, applies the "capitalize first letter / add trailing
  space" preferences.

### `PTTHotkeys` — Global hotkey
A shortcut here is one of two shapes, and they cannot share a mechanism:

- **Modifiers alone** (⌃⌥, the default) — the push-to-talk convention. Carbon's hot key
  table is keyed by virtual key code and cannot express "no key", so these are observed
  through `flagsChanged` events. The observation is **passive**: every other app still
  receives ⌃⌥ exactly as before. That is the entire argument for the extra implementation.
- **Modifiers plus a key** (⌘T, ⌃⌥Space) — `RegisterEventHotKey`, which *consumes* the
  combination system-wide.

Types:
- `HotkeyMonitoring` protocol (`onPress` / `onRelease` / `onCancel`) — the seam for DI and
  tests, and the reason nothing above this module branches on the shape of a shortcut.
- `HotkeyMonitor` — routes a binding to the right implementation and unregisters the other,
  so switching shapes cannot leave a Carbon hot key silently eating a combination.
- `CarbonHotkeyMonitor` — `RegisterEventHotKey` + an `EventHandlerUPP` handling both
  `kEventHotKeyPressed` and `kEventHotKeyReleased`. Chosen over a `CGEventTap` deliberately:
  no Accessibility permission, nothing in the path of every keystroke on the machine, and
  no risk of the system disabling a slow tap. Re-registration is atomic (unregister →
  register → roll back on failure), so a conflicting binding never leaves the app without
  a shortcut.
- `ModifierHotkeyMonitor` — global + local `flagsChanged` monitors. Because holding ⌃⌥ is
  also how one *starts* pressing ⌃⌥⌘F, it cancels rather than delivers when the modifier
  set grows, when any ordinary key is pressed during the hold, or when the hold is shorter
  than 220 ms. The key guard is installed only for the duration of a hold. `NSEvent` global
  monitors are silent until the app is trusted for Accessibility, so a modifier-only
  binding makes that permission a requirement for the shortcut itself — the app
  re-registers on activation, which is exactly when the user returns from System Settings.
- `HotkeyRecorder` — a local `NSEvent` monitor, live *only* while the Settings field is
  focused. It records either shape from what the user actually does: press a key while
  holding modifiers, or hold modifiers and let go.

### `PTTInsertion` — Getting text into the focused field
- `TextInserting` protocol; `TextInsertionService` owns the strategy chain:
  1. **`AXTextInserter`** — `AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`
     → set `kAXSelectedTextAttribute`. This replaces the selection (or inserts at the
     caret when the selection is empty) with no clipboard involvement and no keystroke
     synthesis. Verified against the element's role/settability before use.
  2. **`ClipboardInserter`** — fallback: snapshot **all** pasteboard items (every type,
     not just the string), write the transcript, synthesize ⌘V via `CGEvent`, then restore
     the snapshot after a short settle delay. Restoration runs in a `defer`-style guard so
     a failure mid-way still puts the user's clipboard back.
- `AccessibilityPermission` — `AXIsProcessTrustedWithOptions` (prompt-free probe by
  default), plus the System Settings deep link and an event-driven re-check on app
  activation (no polling loop).

### `PTTUI` — Everything visible
- `MenuBarController` — the `NSStatusItem` and its `NSMenu`. The menu is rebuilt on demand
  in `menuNeedsUpdate`, so no observers fire while it is closed. Icon reflects state
  (idle / listening / transcribing / error).
- `HUDController` + `HUDView` — a borderless, non-activating `NSPanel` at
  `.statusBar - 1` level, `ignoresMouseEvents`, `collectionBehavior = [.canJoinAllSpaces,
  .stationary]`. It is **created on show and destroyed after the fade-out**, so an idle app
  owns no windows. Content is a small SwiftUI view: 🎤 Listening… / ⚙️ Transcribing… /
  error text, with a live input-level bar while listening.
- `SettingsScene` — a single compact SwiftUI window (Hotkey / Language / Model / Behavior),
  opened only when asked.
- `PermissionsOnboarding` — the first-run sheet that walks through mic + accessibility.

### `PushToType` — The app target
- `PushToTypeApp` / `AppDelegate` — `NSApplication` with `LSUIElement = true`
  (no Dock icon, no menu bar). Wires dependencies once and hands them to the controller.
- **`DictationController`** (`@MainActor`) — the state machine, and the only place that
  knows the full flow:

```
        idle ──hotkeyDown──▶ preflight ──ok──▶ listening ──hotkeyUp──▶ transcribing
          ▲                     │                  │                        │
          │                     │fail              │(streaming chunks)      │
          └──────error◀─────────┘                  └────────────────────────┤
          │                                                                 │
          └──────────────────────── inserting ◀─────────transcript──────────┘
```
  `preflight` (mic permission, model present, engine warm) is what makes the *second*
  dictation instantaneous; it is also where every error is converted into a HUD message
  instead of a crash. Every transition cancels the previous `Task`, so a rapid
  press-release-press sequence can never interleave two dictations.
- `LoginItemManager` — `SMAppService.mainApp` register/unregister for "Start at Login".

### `PTTDoctor` — `ptt-doctor`
A second executable, and a deliberate addition to the original plan. The Command Line
Tools ship neither XCTest nor Swift Testing, so `swift test` cannot run on the target
machine at all. Rather than call an unrunnable suite "tested", the project also carries a
diagnostics command that verifies what only a real machine can answer: the model file's
integrity, that whisper.cpp links and runs, how fast inference is *here*, whether an input
device exists, and which permissions are granted. It caught two real defects the moment it
first ran.

---

## 3. Dependencies

**Third-party (exactly one, vendored + statically linked):**
- [`ggml-org/whisper.cpp`](https://github.com/ggml-org/whisper.cpp) — MIT, pinned as a git
  submodule under `Vendor/whisper.cpp`, built to `libwhisper.a` + `libggml*.a`.

**Apple frameworks:** SwiftUI, AppKit, AVFoundation, Accelerate, Carbon (HIToolbox),
ApplicationServices (AX), ServiceManagement, UserNotifications, os.log, Observation.

**Build-time tools:** Swift 6.3 toolchain (Command Line Tools), CMake (to build
whisper.cpp), `codesign` (ad-hoc). No package manager, no runtime downloads other than
the whisper model itself.

**Runtime downloads:** the GGML model, once, from Hugging Face —
`https://huggingface.co/ggml-org/whisper.cpp/resolve/main/ggml-base.en.bin` (147 MB).

---

## 4. Repository layout

```
PushToType/
├── Package.swift
├── ARCHITECTURE.md
├── README.md
├── Vendor/whisper.cpp/                 # git submodule, pinned at v1.9.1
├── Scripts/
│   ├── build-whisper.sh                # cmake → .build/whisper/lib*.a
│   ├── build-app.sh                    # swift build + .app assembly + codesign
│   ├── run.sh                          # build & launch
│   └── make-icon.swift                 # renders Resources/AppIcon.icns in code
├── Resources/
│   ├── Info.plist                      # LSUIElement, NSMicrophoneUsageDescription
│   ├── PushToType.entitlements
│   └── AppIcon.icns
├── Tests/PushToTypeTests/              # swift-testing; needs Xcode to run
└── Sources/
    ├── CWhisper/                       # module.modulemap + shim.h
    ├── PTTSupport/                     # Log, PTTError, AppPaths, primitives
    ├── PTTSettings/                    # SettingsStore, HotkeyBinding, WhisperModel, Language
    ├── PTTAudio/                       # AudioRecorder, MicrophonePermission, VoiceActivity
    ├── PTTWhisper/                     # WhisperEngine, ModelManager, StreamingTranscriber
    ├── PTTHotkeys/                     # CarbonHotkeyMonitor, HotkeyRecorder
    ├── PTTInsertion/                   # AXTextInserter, ClipboardInserter, AccessibilityPermission
    ├── PTTUI/                          # MenuBarController, HUD, Settings, Onboarding
    ├── PushToType/                     # AppDelegate, DictationController, LoginItemManager
    └── PTTDoctor/                      # the ptt-doctor diagnostics command
```

---

## 5. Build order (each step compiles before the next)

1. `Package.swift` + `PTTSupport` + `PTTSettings` — the leaves.
2. `CWhisper` + `Scripts/build-whisper.sh` — prove the C library links.
3. `PTTAudio` — capture and resample.
4. `PTTWhisper` — engine, model download, streaming.
5. `PTTHotkeys` — press/release.
6. `PTTInsertion` — AX + clipboard fallback.
7. `PTTUI` — menu bar, HUD, settings.
8. `PushToType` — controller wiring, Info.plist, `.app` assembly, signing.
9. `PTTDoctor` — prove the whole stack works on real hardware, with real numbers.

---

## 6. Measured on the target machine

MacBook Pro 16" 2019, Core i9-9880H, `base.en`, English:

| | |
|---|---|
| Model load | 0.25 s |
| Inference | 11.0 s of audio in 0.89 s — **12.4× real time** |
| Idle CPU | 0.0% |
| Idle memory | ~25 MB resident |

A five-second dictation therefore needs about 0.4 s of inference without streaming, and
roughly the length of the final phrase with it.
