# PushToType

Hold ⌃⌥, speak, let go — the text lands in whatever field you were typing into.
Like push-to-talk, except it outputs words instead of audio.

Everything runs on your Mac. No account, no cloud, no subscription, no telemetry.
Speech never leaves the machine.

```
    ⌃⌥ ↓            speak              ⌃⌥ ↑           text appears
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

## Install

```bash
./Scripts/install.sh
```

Puts the app in `/Applications`, turns on Launch at Login, and starts it. Pass
`--no-login` to install without the login item.

Launch at Login goes through `SMAppService.mainApp`, which only the app itself can
register — hence the `--register-login-item` switch the installer calls. Undo it with
`/Applications/PushToType.app/Contents/MacOS/PushToType --unregister-login-item`, or from
the menu bar.

Once installed, `./Scripts/run.sh` updates the installed copy instead of launching a second
one out of `build/`. Two bundles with the same identifier both grab the hotkey and only one
wins — which is a confusing way to discover that a fix "did nothing".

Permissions survive the move to `/Applications`: TCC matches the code signature, not the
path — provided you created the signing identity below.

## First run

1. The app appears in the menu bar. There is no Dock icon and no window.
2. macOS asks for **Microphone** access the first time you dictate.
3. **Accessibility** access must be granted manually, in
   System Settings › Privacy & Security › Accessibility. The app cannot type into other
   applications without it — and with the default modifier-only shortcut, it cannot even
   see the shortcut. PushToType re-checks whenever it becomes active, so it starts working
   as soon as you come back from System Settings.
4. The **base.en** model (141 MB) downloads on first use; the HUD shows the progress and
   recording continues while it does.

### Permissions that survive a rebuild

macOS identifies an app for Microphone and Accessibility by its **code signature**. An
ad-hoc signature is a hash of the binary, so every rebuild is a different app as far as the
system is concerned, and every permission has to be granted again.

```bash
./Scripts/make-signing-identity.sh
```

Creates a local self-signed certificate in your login keychain. The designated requirement
becomes the bundle ID plus a fixed certificate hash, which does not change when the code
does — so permissions granted once keep working across every rebuild. `build-app.sh` picks
the identity up automatically and falls back to ad-hoc when it is absent.

Switching to it changes the signature one final time, so both permissions need granting
once more afterwards. Remove the stale PushToType row from the Accessibility list with the
**−** button before adding the new build, or macOS will keep matching the old entry.

The certificate is trusted by nothing and notarised by nobody: it makes local development
bearable and is not a substitute for a Developer ID certificate. Remove it with
`security delete-certificate -c "PushToType Local Signing"`.

## Using it

| Action | Result |
|---|---|
| Hold the shortcut | Recording. The HUD shows 🎤 and a live level meter. |
| Release it | ⚙️ briefly, then the text is inserted at the caret. |
| Hold it and say nothing | Nothing is inserted; the HUD says so and disappears. |

The menu bar item holds Language, Model, Hotkey, Launch at Login, Settings and Quit.

### The shortcut

**⌃⌥ held on its own** by default. Two shapes are supported, and they behave differently
towards the rest of the system:

| Shape | Example | Effect on other apps |
|---|---|---|
| Modifiers alone | ⌃⌥ | **None.** They are observed, not claimed — every app still sees them |
| Modifiers + key | ⌘T | Exclusive: no other app receives that combination while PushToType runs |

Modifiers alone is the default because a push-to-talk key is held for seconds at a time,
and taking ⌘T away from every browser for the privilege is a poor trade.

Holding ⌃⌥ is also how you *begin* pressing ⌃⌥⌘F, so a hold is discarded when the modifier
set grows, when any ordinary key is pressed during it, or when it lasts under 220 ms.
Ordinary shortcuts keep working; you will not accidentally dictate into them.

To record a new shortcut in Settings: click the field, then either press a combination, or
hold two modifiers and let go.

One consequence: a modifier-only shortcut is invisible to the app until Accessibility is
granted, because that is what `NSEvent`'s global monitors require. A key combination works
without it — but text insertion still does not.

### Models

| Model | Size | Notes |
|---|---|---|
| `tiny.en` / `tiny` | 75 MB | Fastest, noticeably less accurate |
| `base.en` / `base` | 141 MB | Default. The right trade-off on a CPU |
| `small.en` / `small` | 465 MB | Most accurate, roughly 3× slower |

English-only models (`.en`) are faster *and* more accurate for English. Picking any other
language automatically switches to the multilingual counterpart.

### Your words

Settings has a **Your words** field for names the model keeps mangling — project names,
tools, people. They are fed to whisper as the text it believes preceded the audio, which
makes those spellings more likely. It is a nudge, not a dictionary: a listed word can still
come out wrong, and a very long list crowds out the sentence being continued.

### Pick the right language

Setting the language explicitly is not only about accuracy. Measured on the same 11-second
sample with `small`:

| | |
|---|---|
| Correct language | 2.13 s — **5.2× real time** |
| Wrong language forced | 11.59 s — **0.9× real time** |

A mismatch makes whisper fail its own confidence thresholds and re-decode at rising
temperatures, so it costs roughly five times the wall-clock as well as the quality.
`Automatic` is a reasonable middle ground for longer speech, but on a one-second
push-to-talk burst there is barely enough audio to detect from — name the language.

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
