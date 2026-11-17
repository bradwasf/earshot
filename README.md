<img src="assets/icon.svg" width="64" height="64" alt="">

# Earshot

[![CI](https://github.com/bradwasf/earshot/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/bradwasf/earshot/actions/workflows/ci.yml)

A fully local macOS app that live-transcribes the calls you join and summarizes them afterwards.

- **Both sides, separately.** Your microphone is labelled **Me**; the Mac's audio (Zoom, Meet, Teams, FaceTime, anything) is labelled **Them**, with remote speakers told apart as *Them 1*, *Them 2*… when there is more than one.
- **Live.** Words appear about half a second after they are spoken.
- **Summaries.** When you stop, a local LLM writes `summary.md`: TL;DR, key points, decisions, action items with owners, open questions.
- **Private.** Speech recognition runs on the Neural Engine through Core ML; the summary runs in Ollama on `127.0.0.1`. No cloud API is called and no audio or text leaves the Mac.

```
microphone ──────────────► echo canceller ─► Silero VAD ─► Parakeet Ultra ─► "Me"   ┐
                                ▲ reference                                         ├─► transcript.md ─► Ollama ─► summary.md
system audio (Core Audio tap) ──┴─────────► Silero VAD ─► Parakeet Ultra ─► "Them"  ┘
                                └─────────► Sortformer (who is speaking: Them 1/2/…)
```

## Requirements

- Apple Silicon Mac, macOS 14.4 or newer (built and tested on an M5 Pro, macOS 27.2)
- Xcode or the Xcode command line tools (Swift 5.10+)
- [Ollama](https://ollama.com) for summaries (`setup.sh` installs it with Homebrew if it is missing)

## Setup

```bash
./setup.sh
open build/Earshot.app
```

`setup.sh` checks the Mac, makes sure Ollama is running and has the summary model (`qwen3.5:4b-mlx`), builds and signs `build/Earshot.app`, and downloads the speech models (about 1 GB, once, into `~/Library/Application Support/FluidAudio/Models`).

| Option | What it adds |
|---|---|
| `./setup.sh --install` | copies the app to `/Applications` |
| `./setup.sh --with-blackhole` | installs the BlackHole 2ch loopback driver (only needed for the fallback capture path, see below) |
| `EARSHOT_SUMMARY_MODEL=<name> ./setup.sh` | pulls a different Ollama model |

## Permissions

macOS asks for two permissions the first time you press **Record**. Allow both.

| Prompt | Used for | Where to change it later |
|---|---|---|
| **Microphone** | your side of the call ("Me") | System Settings › Privacy & Security › Microphone |
| **System Audio Recording Only** ("…would like to record this computer's audio") | everyone else ("Them") | System Settings › Privacy & Security › Screen & System Audio Recording › *System Audio Recording Only* |

Earshot does **not** need Screen Recording, Accessibility or any other permission. If you decline the microphone, the other side is still transcribed; if you decline system audio, only your microphone is.

If the **Them** lane stays flat while the other side is talking, the system-audio permission is off: enable Earshot in the list above and start again. (macOS delivers silence rather than an error when this permission is missing.)

Permissions are tied to the app's code signature. `scripts/build-app.sh` signs with your *Apple Development* certificate when one is in the keychain, so the grants survive rebuilds; with an ad-hoc signature macOS asks again after each rebuild.

## Using it

1. Join your call as usual. Do not change any audio settings: your speakers or headphones and your microphone stay exactly as they are.
2. Open Earshot (window, or the waveform icon in the menu bar) and press **Record** (⌘R). Optionally name the call first.
3. The transcript scrolls live under a two-lane level display (Me above the line, Them below). The tinted card marked *live* is still being recognised; it becomes a regular card once the sentence is committed.
4. Press the red timer button to stop. Earshot finishes the transcript, writes the summary and shows it as cards: In short, Key points, Decisions, Action items (with an owner chip), Open questions.
5. The home screen lists your recent calls; click one to read its transcript and summary again.

Everything is saved as you go:

```
~/Earshot/Calls/2026-11-17-weekly-sync/
├── transcript.md     timestamped, "Me" / "Them" (auto-saved every few seconds while recording)
├── summary.md        TL;DR · Key points · Decisions · Action items · Open questions
└── audio.m4a         only if "Save raw audio" is on (off by default; left = Me, right = Them)
```

If you leave the title empty, the call is named after the meeting app that is running (e.g. `zoom-call`) and renamed after the title the summary proposes. **Regenerate Summary** re-runs the summary for the last call, for example with a different model.

**Settings (⌘,)**: system-audio source, microphone, echo handling, raw audio, speech model, speaker separation, summary model, calls folder.

### Headphones or speakers

Both work. With headphones the two channels are naturally separate. On speakers the microphone also hears the other participants; Earshot removes that in two stages: a neural echo canceller (LocalVQE) subtracts the system audio from the microphone, and a text check drops any remaining "Me" line that only repeats what "Them" said at the same moment. Both can be switched off in Settings.

## Audio routing

### Default: native system-audio tap (nothing to set up)

Earshot records system audio with a **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.4+). There is no virtual device and no Multi-Output Device; your output device and volume keep working normally. The tap is taken before the volume control, so the other side is transcribed even when the Mac is muted, and it is rebuilt automatically when the default output device changes mid-call.

### Fallback: BlackHole 2ch

Use this only if the native tap does not work on your Mac (for example a managed Mac where system-audio recording is blocked by policy).

1. Install the driver: `./setup.sh --with-blackhole` (or `brew install --cask blackhole-2ch`). macOS asks for your password. If "BlackHole 2ch" does not appear afterwards, run `sudo killall coreaudiod` or restart.
2. Open **Audio MIDI Setup** (Spotlight: "Audio MIDI Setup").
3. Click **+** (bottom left) › **Create Multi-Output Device**.
4. Tick your real output (e.g. *MacBook Pro Speakers* or your headphones) **and** *BlackHole 2ch*. Keep the real output as the **Primary Device** (top of the list) and tick **Drift Correction** for *BlackHole 2ch*.
5. Optionally double-click the new device's name and rename it "Earshot Output".
6. Make it the system output: System Settings › Sound › Output › *Multi-Output Device* (or Option-click the volume icon in the menu bar). Note that macOS disables the volume keys for a Multi-Output Device; set the volume on the real device first.
7. In Earshot › Settings › Audio › **Other participants**, choose **BlackHole 2ch**.
8. After the call, switch the system output back to your normal device.

Your microphone setup does not change in either mode. An Aggregate Device is not needed: Earshot reads the microphone and BlackHole as two separate devices and aligns them itself.

## Why this stack

Researched in November 2026; the numbers marked *measured* are from this Mac (see the next section).

**Capture: Core Audio process tap, BlackHole as fallback.**
Apple's own guidance for audio-only capture is the tap API rather than ScreenCaptureKit ([Apple Developer Forums, Apple Media Engineer](https://developer.apple.com/forums/thread/832345); [sample code](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)). Compared with the alternatives:

| | Core Audio tap | ScreenCaptureKit | BlackHole + Multi-Output |
|---|---|---|---|
| Setup for the user | none | none | install a driver, build a Multi-Output Device, switch output before every call |
| Permission | System Audio Recording Only | Screen Recording (broader than needed) | none for system audio |
| Side effects | none | video-first API; audio-only use still needs the screen permission | volume keys disabled, easy to forget to switch back, breaks when AirPods connect |
| macOS | 14.4+ | 13+ | any |

Recent open-source meeting recorders made the same choice ([meeting-notes](https://github.com/masconics/meeting-notes), [AudioCap](https://github.com/insidegui/AudioCap)). One known tap failure mode, digital silence after long uptime ([forum report](https://developer.apple.com/forums/thread/825780)), is handled by a watchdog that rebuilds the tap when audio is playing but only zeros arrive.

**Speech-to-text: NVIDIA Parakeet (Ultra build) on Core ML via [FluidAudio](https://github.com/FluidInference/FluidAudio), not Whisper.**

| | Parakeet TDT 0.6B (Core ML / Neural Engine) | Whisper large-v3-turbo (whisper.cpp / MLX / WhisperKit) |
|---|---|---|
| Speed, *measured* on this M5 Pro (4 min 14 s of LibriSpeech) | **0.83 s, 305× real time** (Parakeet Ultra, FluidAudio) | 7.25 s, 35× real time (mlx-whisper) |
| Speed, published | 110–155× on an M4 Pro ([FluidAudio benchmarks](https://docs.fluidinference.com/reference/benchmarks.md)) | about 5× slower than Parakeet on the same clip across whisper.cpp, MLX and WhisperKit ([mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest)) |
| Accuracy, *measured* on the same clip | 21 word differences in 549 | 22 word differences in 549, **plus a hallucinated "I am I am I am…" loop** appended in the trailing silence |
| Accuracy, published (LibriSpeech test-clean WER) | 2.1 % (Ultra), 2.3–2.5 % (v3) ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)) | in the same range |
| Languages | 25 European | 99 |

Accuracy is on par for English, so speed and behaviour in silence decide. At hundreds of times real time Earshot can simply **re-decode the whole in-progress utterance every 0.6 s**: live text with the accuracy of the full offline model, instead of a smaller low-latency streaming model (Parakeet EOU: 4.9–8.3 % WER in FluidAudio's benchmarks). Doing the same with Whisper would cost about nine times the compute, and Whisper needs extra guarding against invented text in pauses. If you need languages outside Parakeet's 25, Whisper is the better tool and this pipeline would need a different engine.

**Voice activity detection:** Silero VAD v6 (Core ML, >1000× real time) gates both channels, so silence is never sent to the recogniser.

**Speaker separation (nice-to-have, on by default):** NVIDIA streaming Sortformer on the "Them" channel. It runs live at >100× real time with about one second of latency and handles up to four remote speakers; with more than four, speakers get merged.

**Summaries:** Ollama on localhost. The default model is `qwen3.5:4b-mlx`, chosen for speed (a 43-minute call is summarized in about 40 s). `qwen3.8:27b-mlx` writes slightly richer notes and is a one-click switch in Settings, at two to four times the wait on long calls. Transcripts longer than about 12,000 characters (roughly ten minutes of talk) are summarized in chunks: every chunk yields its decisions, action items and open questions, the lists are merged in code so nothing can be dropped by a second model pass, and the model then writes only the title and TL;DR. The context window is sized to each prompt, because Ollama's default silently truncates long input.

**UI:** SwiftUI (window + menu-bar item), one process, no web server, with its own look in light and dark mode rather than stock controls (see `Sources/Earshot/Theme.swift`).

## Measured performance

Apple M5 Pro, 48 GB, macOS 27.2.1. The test call is a scripted 109-second, three-person meeting (two remote voices, one local) with known text; `scripts/make-test-call.py` regenerates it.

**How far behind real time is the live transcript?** Measured per word, from the moment a word ends to the moment it is on screen:

| | Median | 95th percentile | Worst |
|---|---|---|---|
| Them (system audio), real app with the real tap | **0.37 s** | 0.79 s | not logged |
| Them, file-fed at real-time pace | 0.36 s | 0.80 s | 1.0 s |
| Me (microphone, through the echo canceller), file-fed | **0.51 s** | 1.00 s | 1.2 s |

A sentence turns from grey to committed 1–4 s after it ends (it waits for the pause or the next sentence); it is already readable as live text long before that.

**Accuracy (word error rate)**

| Test | Me | Them | Remote speakers |
|---|---|---|---|
| Real app, real system-audio tap: the remote side played through the Mac's output | not exercised (see below) | **1.5 %** (3 of 206 words) | 2 of 2 separated, 100 % of words labelled correctly |
| Both channels fed from files at real-time pace (headphones case) | 4.3 % (4 of 92) | 1.9 % (4 of 206) | 100 % |
| Speakerphone case: microphone file contains the local voice plus room echo of the remote side | **3.3 %** | 1.9 % | 100 % |
| Same, with echo cancellation and the text guard both switched off | 223 % (the remote side is transcribed twice) | 1.9 % | 100 % |
| Real human speech (LibriSpeech, 4 min 14 s, 549 words) through the live pipeline | n/a | 3.6 % raw, identical to offline decoding (3.8 %) | 1 of 1 |

About half of the LibriSpeech differences are spelling conventions and character names ("mister" / "Mr.", "Michael Angelo" / "Michelangelo", "recognising"); the "Me" errors in the scripted call are the synthetic voice's "QA" being heard as "Ka".

**Speed**

| | |
|---|---|
| Parakeet Ultra, offline | 305× real time (4 min 14 s in 0.83 s) |
| Parakeet Ultra, inside the live pipeline (each re-decode) | 70–90× real time per channel |
| Summary, `qwen3.5:4b-mlx` (default) | 2-minute call: 7–15 s · 22-minute call: 25 s · 43-minute call (4 chunks): 41 s |
| Summary, `qwen3.8:27b-mlx` | 2-minute call: 25 s · 22-minute call: 45–145 s |
| App launch to ready | a few seconds once the models are compiled; about a minute the very first time |

**Not verified on this machine**

- *Live speech into the microphone.* The Mac's output was muted during testing, so no sound reached the room. Microphone capture itself was verified in the real app (ambient level about −60 dBFS on the USB microphone), and the microphone path from there on (alignment, echo cancellation, VAD, recognition, "Me" labelling) was verified with file-fed audio.
- *The BlackHole fallback.* The driver is not installed (it needs an administrator password). The code path is the same device reader the microphone uses.
- Switching output devices mid-call, calls with more than four remote speakers, and languages other than English.

## Command line

`earshot-cli` (built next to the app, at `.build/release/earshot-cli`) runs the same pipeline without the UI.

```bash
earshot-cli models                               # download + compile the speech models
earshot-cli devices                              # list audio devices (and whether BlackHole is installed)
earshot-cli live --seconds 60 --title "Test"     # record the real microphone + system audio
earshot-cli simulate --them a.wav --me b.wav     # feed two files through the live pipeline in real time
earshot-cli summarize ~/Earshot/Calls/<folder>   # (re)write summary.md for a saved call
```

Unit tests for the pure logic (timeline alignment, transcript and folder format, summary chunking and merging): `swift test`.

Re-running the end-to-end test:

```bash
scripts/make-test-call.py test-artifacts         # scripted 3-person call (macOS voices) + ground truth
.build/release/earshot-cli simulate --them test-artifacts/them.wav --me test-artifacts/me.wav --root /tmp/earshot-test
scripts/score.py /tmp/earshot-test/*/transcript.md test-artifacts/reference.json
```

## Project layout

```
Package.swift                 Swift package: EarshotCore (library), Earshot (app), earshot-cli
Sources/EarshotCore/Audio     capture: process tap, device input (mic / BlackHole), resampling, timeline alignment
Sources/EarshotCore/Speech    models, VAD + Parakeet streaming transcriber, Sortformer speakers, echo canceller
Sources/EarshotCore/Session   call session, transcript + folder format, Ollama summarizer
Sources/Earshot               SwiftUI app (window, menu bar, settings; Theme.swift holds colours and type)
Sources/earshot-cli           headless CLI and test harness
Tests/EarshotCoreTests        unit tests
scripts/build-app.sh          builds and signs build/Earshot.app
scripts/make-icon.swift       draws Resources/AppIcon.png
scripts/make-test-call.py     generates the scripted test call
scripts/score.py              word error rate + speaker-label scoring
setup.sh                      one-shot setup
.github/workflows/ci.yml      builds and runs the unit tests on every push and pull request
```

## Branches

- **`dev`** is the default branch. Day-to-day work lands here, directly or through pull requests.
- **`prod`** is what is considered released. It only changes through a pull request from `dev`, and CI has to pass first.

To release: open a pull request from `dev` into `prod` and merge it with a merge commit (not squash), so the two branches keep a shared history.

## Troubleshooting

- **"Them" is empty.** Allow *System Audio Recording Only* (see Permissions). Check that the call's audio is actually playing through this Mac.
- **"Me" is empty.** Allow the microphone, and check Settings › Audio › My microphone (the default follows System Settings › Sound › Input).
- **My words show up under "Them" or theirs under "Me".** "Them" is whatever the Mac plays; "Me" is whatever the microphone hears. On speakers, keep echo cancellation on. Other audio playing on the Mac during a call (music, videos) is transcribed as "Them".
- **Summary failed.** Ollama was not reachable or the model is missing. Run `ollama serve`, then press **Regenerate Summary**. The transcript is always saved regardless.
- **First start is slow.** The first launch after setup or a macOS update compiles the models for the Neural Engine (up to a minute). Later launches take a few seconds.
- **Logs:** `~/Library/Logs/Earshot/earshot.log` (timings and errors only, never transcript text).

## Limits

- Speech recognition covers 25 European languages (Parakeet); there is no translation.
- Speaker separation distinguishes at most four remote voices and can mislabel short interjections. "Me" vs "Them" does not depend on it.
- Two people talking at once on the same side are transcribed as one stream.
- The first words after pressing Record can be clipped if someone is mid-sentence.
