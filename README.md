<p align="center"><img src="Resources/Branding/transcriber-logo.png" width="128" alt="Transcriber"></p>

# Transcriber for Mac

A native macOS app (Swift + SwiftUI) that transcribes whatever your Mac is playing (calls, videos, podcasts), a microphone, recorded audio files such as voice memos, and YouTube videos. Speech recognition runs on your Mac, so audio never leaves it. It also turns a voiceover into word-timed subtitles for video editors.

There's also [Transcriber for Windows](https://github.com/duck28/transcriber-for-windows), which looks and works the same way.

- **Audio:** a Core Audio process tap captures all system output except this app. Unlike ScreenCaptureKit, it doesn't need Screen Recording permission.
- **Speech:** `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, or OpenAI's Whisper through [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML).
- **Liquid Glass:** the controls use Apple's Liquid Glass when the app is built with the macOS 26 SDK or newer and runs on macOS 26 or later. Built with an older SDK, it uses a frosted-material look instead.

## Download and install

Requires macOS 14.4 or later on a Mac with Apple silicon (M1 or later). The release build is Apple silicon only; on an Intel Mac, [build it from source](#build-from-source).

1. Download `Transcriber-<version>-mac-arm64.dmg` from the [latest release](https://github.com/duck28/transcriber-for-mac/releases/latest).
2. Open the disk image and drag **Transcriber** to **Applications**.
3. Open Transcriber. The first time, macOS blocks it (see below).

### The app is not signed or notarized

Release builds are ad-hoc signed, not signed with an Apple Developer ID or notarized by Apple. When you open Transcriber for the first time, Gatekeeper says that Apple could not verify it is free of malware and offers only **Done** or **Move to Trash**. To open it anyway:

1. Click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down to the message about Transcriber, and click **Open Anyway**. Confirm with your password.

Alternatively, remove the quarantine flag in Terminal: `xattr -dr com.apple.quarantine /Applications/Transcriber.app`.

On macOS 14 you can also right-click the app and choose **Open**.

macOS ties privacy permissions (microphone, system audio, speech recognition) to the app's signature. Because the signature is ad-hoc, macOS may ask for them again after you update to a new version.

### Verify a download

Every release file is attested by the GitHub Actions run that built it ([build provenance](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)). With the [GitHub CLI](https://cli.github.com):

```bash
gh attestation verify Transcriber-1.3.0-mac-arm64.dmg --repo duck28/transcriber-for-mac
```

## First run

1. Click **Start** (⌘R).
2. Allow **Speech Recognition** when macOS asks.
3. Allow **System Audio Recording** when macOS asks. If you deny it, macOS doesn't report an error; the app just receives silence. After about 10 seconds of silence the app shows a hint. To fix it, go to System Settings › Privacy & Security › Screen & System Audio Recording.

## Features

- **Source:** the toolbar picker switches between *System Audio* and any microphone or audio interface. Microphones need the Microphone permission, which macOS asks for the first time you use one.
- **Transcripts folder:** the sidebar button (⌃⌘S) opens the save folder on the left of the window, which grows by the pane's width so the transcript keeps its size. Make folders, rename (Return), move by dragging onto a folder or with **Move To**, and move items to the Trash (⌘⌫). Double-click opens a file. Moving or renaming the open transcript's file keeps auto-save writing to it.
- **Naming a transcript:** click the window title, or choose **File › Rename Transcript…**. The saved file is renamed along with the subtitles and audio next to it. With nothing transcribed yet, this names the next transcript.
- **Reading back:** scroll up while text is coming in and the view stays where you are; **Latest** jumps back to the newest text.
- **Auto-save:** transcripts are saved after every segment to `~/Documents/Transcriber` (you can change the folder or turn auto-save off in Settings, ⌘,). The footer shows the file; click it to reveal it in Finder. **Save As…** (⇧⌘S) saves to a file you choose, and auto-save then keeps writing to that file.
- **Save Audio:** with the toolbar toggle on, the audio is saved as an `.m4a` file next to the transcript.
- **Close warning:** if transcription or an import is still running, or a transcript isn't saved, Transcriber asks before the window closes or the app quits.
- **Recordings and voice memos:** choose **Import › Audio File…** (⌘O), or drop a file onto the window. Audio and video files both work. To use a voice memo, drag it out of the Voice Memos app into Finder first, or use Share › Save to Files.
- **YouTube:** **Import › YouTube Video…** (⇧⌘Y) uses the video's captions in the selected language. If the video has none, or you choose to, it downloads the audio and transcribes it on your Mac. This needs a current [yt-dlp](https://github.com/yt-dlp/yt-dlp) (`pip3 install -U "yt-dlp[default]"` or `brew install yt-dlp`). If there are several copies, Transcriber uses the newest one; it shows a warning and the update command if that copy is out of date. yt-dlp also needs a JavaScript runtime for YouTube: Deno is used automatically, and Node or Bun are passed to it if installed. With **Save Audio** on, the audio is kept even when captions were used.
- **Narrator mode (subtitles):** turn on **Narrator Mode** in the toolbar (⇧⌘N), then drop or import a voiceover. It's turned into subtitles timed to each word: new subtitles start at sentence ends and pauses, with up to 2 lines of 42 characters (or 1 line of 32 for short-form video; see Settings). An `.srt` is saved next to the transcript automatically. **Export Subtitles** offers:
  - **SubRip (.srt):** DaVinci Resolve (File › Import › Subtitle, then drag it onto the timeline) and Premiere Pro (File › Import, then drag it onto the timeline).
  - **WebVTT (.vtt):** for web players and YouTube.
  - **Final Cut Pro (.fcpxml):** a project with the voiceover on the timeline and the subtitles as captions already in sync (FCPXML 1.10, Final Cut Pro 10.6 or later). Set the project frame rate in Settings. If Final Cut Pro is installed, **Open in Final Cut Pro** imports it directly.
- **Appearance:** choose System, Light, or Dark under View › Appearance or in Settings.

## Languages

The language menu lists every language macOS speech recognition supports, in three sections: **Recently Used** (the last five languages you transcribed with, newest first), **On This Mac** (offline model installed), and **Needs Download**. A language under *Needs Download* has to be installed once before you can use it:

1. Go to System Settings › Keyboard › Dictation and turn Dictation on.
2. Under Languages › Edit…, add the language (for example German).
3. Wait for the download to finish. Transcriber notices the new model the next time you switch to it.

With Apple Speech, Swiss German *dialect* isn't supported: "German (Switzerland)" transcribes Standard German using Swiss spelling (no "ß").

## Whisper (Swiss German and other dialects)

Under Settings › Speech Recognition, switch the engine to **Whisper**. Whisper understands Swiss German and writes it as Standard German (with Swiss spelling when German (Switzerland) is selected). It works for live transcription, files, YouTube and narrator mode.

- **Expert options:** Settings › Expert Options lets you change WhisperKit's decoding parameters (temperature and retries, compression ratio, log probability and no-speech thresholds, blank suppression) and the live phrase timing. With the switch off, WhisperKit's defaults apply.
- **Models:** *Large v3 Turbo – fast* (≈ 650 MB, the default: a compressed version that is about twice as fast with nearly the same accuracy), *Large v3 Turbo – full precision* (≈ 1.6 GB, too slow for live transcription on base M-series chips), or *Small* (≈ 500 MB). The model is downloaded once from Hugging Face (`argmaxinc/whisperkit-coreml`) into `~/Library/Application Support/Transcriber/Whisper`; after that, transcription works offline. The first load also prepares the model for your Mac's Neural Engine, which can take a few minutes.
- **Custom models:** choose *Custom…* and enter a Hugging Face repository and model folder, for example a Swiss German fine-tune converted with [whisperkittools](https://github.com/argmaxinc/whisperkittools).
- **Live mode:** Whisper transcribes whole phrases. A preview updates about every second while someone talks, and the final text appears roughly 1–2 seconds after each pause (measured on an M3 with the default model).

## Build from source

Needs macOS 14.4 or later and the Xcode Command Line Tools (`xcode-select --install`); Xcode itself isn't required.

```bash
./build.sh
open build/Transcriber.app
```

This builds `build/Transcriber.app` for your Mac's architecture and a disk image at `build/Transcriber.dmg`. To install it, copy the app to `/Applications`. `./build.sh debug` builds a debug app without the disk image. The [build workflow](.github/workflows/build.yml) builds every push to `main` and every pull request.

### Keeping permissions across rebuilds

macOS ties privacy permissions to the code signature. An ad-hoc signature changes on every build, so macOS may ask again after each rebuild. To avoid that, set up a stable signing identity:

1. In Keychain Access, choose Certificate Assistant › Create a Certificate…
2. Enter a name such as `Transcriber Local`, set Identity Type to *Self Signed Root* and Certificate Type to *Code Signing*.
3. Build with `SIGN_IDENTITY="Transcriber Local" ./build.sh`.

## Releasing

1. Set the new version in `Resources/Info.plist` (`CFBundleShortVersionString`, for example `1.3.1`, and increase `CFBundleVersion`).
2. Commit, then push a tag that matches the version with a `v` in front:
   ```bash
   git tag v1.3.1 && git push origin v1.3.1
   ```
3. The [release workflow](.github/workflows/release.yml) checks that the tag matches the version, builds `Transcriber-<version>-mac-arm64.dmg` on a macOS runner, attests it, and creates a **draft** release. Review it on GitHub and publish it.

## Code layout

| File | Purpose |
| --- | --- |
| `SystemAudioCapture.swift` | Process tap + private aggregate device that delivers PCM buffers |
| `AudioInput.swift` | `AudioCapture` protocol, input device list, microphone capture via `AVAudioEngine` |
| `AudioRecorder.swift` | Writes captured audio to an AAC `.m4a` file on a background queue |
| `BufferConverter.swift` | Resamples/downmixes PCM buffers (shared by recognition and recording) |
| `LiveTranscriber.swift` | Streams 16 kHz mono audio into recognition tasks. Each segment ends at a speech pause or after 50 seconds |
| `WhisperEngine.swift` / `WhisperLiveTranscriber.swift` | Whisper models, decoding options and live transcription through WhisperKit |
| `FileTranscriber.swift` | Transcribes files in 20–45 s chunks, each cut at the quietest moment |
| `Subtitles.swift` | Groups timed words into subtitles; writes SRT, WebVTT and FCPXML |
| `YouTubeImporter.swift` | Runs yt-dlp to fetch captions (json3) or audio |
| `TranscriptionModel.swift` | App state, start/stop, imports, auto-save, close confirmation, settings, transcript folder changes |
| `ContentView.swift` / `SettingsView.swift` | SwiftUI window, YouTube sheet, Settings |
| `TranscriptSidebar.swift` | The transcript folder pane, and growing the window for it like opening a book |
| `TranscriptFolder.swift` | Lists, creates, renames and moves files and folders in the transcript folder |
| `WindowCloseGuard.swift` | Wraps the window delegate so closing can be confirmed |
| `Glass.swift` | Liquid Glass helpers with a material fallback for older SDKs/systems |

## License

[MIT](LICENSE)
