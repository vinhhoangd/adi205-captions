# ADI205/501 — Live Bilingual Classroom Captions

Live English transcription plus Vietnamese (or Chinese) translation, entirely
on-device, with every caption pushed to any laptop or phone on the same network.

## What runs where

| Target | What it is |
|---|---|
| `captiond` | The product. Microphone → captions → serves the caption page over the LAN. |
| `bench` | Replays a WAV through the *identical* pipeline at real-time pace and reports latency. |
| `gate` | Platform check: which Apple on-device models and language packs this Mac has. |

## Build and run

```bash
swift build -c release
./make_app.sh captiond ADI205Captions      # .app bundle — needed for mic permission
open -a build/ADI205Captions.app
```

On first launch macOS asks for microphone access. **Click Allow** — the app waits
for it and captures nothing until you do. If you miss the prompt, grant it under
System Settings › Privacy & Security › Microphone and relaunch.

The window prints URLs. Open the LAN one on the other laptops:

```
http://localhost:8420        # this Mac
http://10.11.20.156:8420     # anyone on the same Wi-Fi
```

Live log: `tail -f /tmp/captiond.log`

### Recording control

**The app starts with the microphone off.** A viewer presses **Start** on the
caption page to begin and **Pause** to stop; the button turns red and the status
dot pulses while recording.

Pause stops the audio engine rather than capturing and discarding — the macOS
microphone indicator goes out, and the tap stops firing. That is the only honest
meaning of "paused" for a microphone pointed at a room full of people who did not
choose to be recorded. The latency clock is re-anchored on resume, because the
analyzer's audio clock does not advance while paused but wall clock does.

Set `CAPTION_AUTOSTART=1` to begin recording immediately on launch.

### Languages

Captions are produced in Vietnamese, Simplified Chinese and Traditional Chinese
at once. The page has a tab per language plus **All**, which stacks every
translation under the English line with a label. The choice is remembered per
viewer, so two people watching the same session can read different languages.

Each language costs one translation call per update. They are issued
concurrently rather than in sequence — three sequential calls would triple the
translated line's latency, which is already the largest item in the budget.
Restrict the set with `CAPTION_LANGS=vi` if a machine struggles.

### The caption page

Plain HTML with no framework and no build step, so it opens unchanged on macOS,
Ubuntu, Windows and phones — that half of the system is cross-platform today.

It shows a live input-level meter and the name of the microphone in use, because
"no captions" has two very different causes: nobody is speaking, or the app is
listening to a dead microphone. An idle waveform and a warning strip tell them
apart at a glance. Text size is adjustable and remembered per viewer, and
auto-scroll can be paused to read back.

### Choosing the microphone

`CAPTION_DEVICE` is accepted but has no effect, and the app says so at startup.
`AVAudioEngine` reads through a `CADefaultDeviceAggregate` that follows the
**system** default input; setting `deviceID` on the input node is silently
ignored. Input selection therefore has to happen at the system level:

```bash
swift run -c release setinput              # list inputs, • marks the current one
swift run -c release setinput "MacBook Pro"
```

This matters more than it sounds. A Bluetooth headset connecting mid-session
takes over as the default input, and its microphone will happily deliver
silence while everything else looks healthy — the tap fires, buffers convert,
the page says "live", and no captions appear. The app now logs a peak level
every five seconds so this is visible rather than mysterious, and it rebuilds
capture automatically when the audio hardware changes underneath it.

**Before demonstrating, run `setinput` and confirm the built-in microphone is
selected.**

### Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `CAPTION_LANGS` | `vi,zh-Hans,zh-Hant` | Target languages, comma-separated |
| `CAPTION_AUTOSTART` | `0` | `1` starts recording without pressing Start |
| `CAPTION_PORT` | `8420` | HTTP port |
| `CAPTION_MASK_K` | `3` | Words held back from the translated line |
| `CAPTION_CHUNK_MS` | `50` | Capture granularity |
| `CAPTION_GLOSSARY` | — | Comma-separated course terms |
| `CAPTION_CORRECTION` | `0` | `1` enables the on-device LLM pass — see the finding below |
| `CAPTION_VAD` | `1` | Apple `SpeechDetector` ahead of transcription |
| `CAPTION_VOICEPROC` | `0` | `1` enables AEC + noise suppression |
| `CAPTION_DEVICE` | — | Requested input device. **Does not work — see below.** |

## Measured results

M1 Pro, 16 GB, macOS 26.6.2. Synthetic lecture audio, replayed at real-time pace
through the same code path the microphone uses. Latency is measured from the
audio-clock time of the last displayed word to the moment it is emitted.

| Clip | mask-k | English median / p90 | Translated median / p90 |
|---|---|---|---|
| lecture1 | 3 | 23 ms / 49 ms | 972 ms / 1285 ms |
| lecture1 | 0 | 34 ms / 49 ms | 1026 ms / 1735 ms |
| lecture2 | 3 | 38 ms / 45 ms | 857 ms / 1190 ms |
| lecture2 | 0 | 32 ms / 47 ms | 795 ms / 1606 ms |

Against a 3-second requirement, with the worst p90 at 1.29 s.

**mask-k=3 beats mask-k=0 on the p90** (1285 ms vs 1735 ms) while barely moving
the median. Holding back the three newest words means less text to re-translate
and fewer revisions, so the tail shortens. The tail is what decides whether a
student can follow a lecture, so k=3 is the default.

## Findings worth putting in the report

**On-device LLM correction is unusable in a live path.** One
`FoundationModels` correction costs **~6.5 s** on this machine — measured at
6582 / 6567 / 6644 ms on repeated calls with a warm session, and *identical* at
30, 60 and 120 maximum response tokens. That flat profile means it is fixed
per-call overhead, not generation speed. Inside the pipeline, competing with
translation, it measured ~14 s. It is off by default. It also failed to restore
"Bayes" in our test sentence, so it was not earning its cost even ignoring latency.

**Vocabulary biasing did nothing measurable; the repair pass did everything.**
Decision 4 in the plan claimed biasing was the layer that *prevents* jargon errors
and the fuzzy repair merely the cure. Measured separately on the same clip:

| Configuration | Output |
|---|---|
| Recognizer biasing only | "The **eigon vector** of the covariance matrix" |
| Glossary repair only | "The **eigenvector** of the covariance matrix" |

Handing the same twelve terms to `AnalysisContext.contextualStrings` changed the
transcript not at all. Caveat before generalising: one recognizer, one synthetic
voice, twelve terms, two sentences — this is not proof that biasing never helps,
only that it earned nothing here. It stays wired (`CAPTION_GLOSSARY` feeds both)
because it costs nothing, but the report should not credit it.

**"Bayes" is lost by the recognizer in every configuration.** The clip says
"Bayes theorem lets us update a prior into a posterior"; every run transcribes
"Theorem lets us…". Neither biasing nor repair can recover a word that was never
emitted — the fix would have to be acoustic or a different model. Worth showing in
the demo as an honest failure rather than hiding it.

**Glossary repair does the job the LLM was supposed to do, for free.** The
recognizer split "eigenvector" into "eigon vector"; matching adjacent word pairs
against the course term list restored it in under a millisecond, on any backend's
output. Single-word matching alone was not enough — the split-word case needs the
pair test.

**Confidence is bimodal, so the gate threshold matters.** Median word confidence
is 1.00; genuine errors land at 0.60–0.65. A gate at 0.55 let every real error
through. The default is now 0.75.

**English and translation must not share a queue.** The first working version put
translation on the result-handling path: English inherited the translator's
latency and the audio feed was starved behind it, giving 1482 ms median / 6622 ms
p90 for a line that needs no processing at all. Moving translation to a coalescing
single-flight queue took English to 23–38 ms median.

**`bestAvailableAudioFormat` returns Int16 here, not Float32.** Code reaching for
`floatChannelData` gets nil and silently feeds the analyzer nothing.

**Never log from the microphone tap.** The tap runs on a real-time audio thread.
An early version wrote a level line to a file from inside it; Core Audio
delivered exactly one buffer and then stopped dead. Statistics are now written to
a lock-guarded field and read by a poller. The symptom — a tap that installs
successfully, reports `engine.isRunning == true`, and then produces nothing —
looks nothing like its cause.

**Capture granularity has a floor of ~96 ms on this Mac.** Requesting a 50 ms tap
buffer, sized correctly in hardware frames, still yields ~52 buffers per 5 s.
Core Audio treats `bufferSize` as a hint. That floor is a real part of the
latency budget and cannot be tuned away from application code.

**Voice processing is off by default.** Enabling `setVoiceProcessingEnabled`
renegotiates the input node's format and, combined with the tap, contributed to
the stall above. It is available behind `CAPTION_VOICEPROC=1` and should be
measured before being trusted — which is what Decision 2 in the plan always
said the group should do.

## Built against the plan

Decisions 1, 2, 4, 5, 7 are implemented as chosen. Two differ deliberately and
one was scoped out:

- **Decision 8 — transport.** Server-sent events, not WebSocket. Captions travel
  one way only, so SSE needs no handshake, no frame masking and no client library.
- **Decision 4 — correction.** The on-device LLM layer is present but off, on the
  6.5 s measurement below rather than on principle.
- **Decision 3 — second ASR backend.** Moonshine was **not built**. The product is
  macOS-only: every target imports `Speech`, `Translation`, `FoundationModels` and
  `AVFoundation`. Non-Mac machines can view captions in a browser and nothing more.
  Scoped out deliberately, not forgotten — building a second pipeline with
  different models would have invalidated the latency figures here and could not
  have been finished or verified before the deadline.

## Known limitations

- Microphone access needs one manual approval; the app blocks until granted.
- **The live path has not been tested with real speech.** The pipeline is proven
  end-to-end on recorded audio through identical code, and the microphone is
  confirmed capturing continuously at a sane level — but nobody has yet spoken
  into it and watched captions appear. That is the first thing to do.
- Reading audio from `~/Documents` triggers a macOS file-access prompt that an
  accessory process cannot surface — keep test corpora outside protected folders.
- Translation quality on statistics vocabulary is weak: "prior"/"posterior" come
  back as "trước đó"/"sau đó", which is literal and wrong in context.
- No diarization; overlapping speakers degrade badly.
- Latency figures are from synthetic speech. Real lecturers, real rooms and real
  distance will be worse, and that measurement is still owed.
