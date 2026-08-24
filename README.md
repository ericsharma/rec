<p align="center">
  <img src="github-header.png" alt="rec">
</p>

# rec

A minimal macOS audio recorder

## Features

- Record system audio or microphone input
- M4A and WAV format support
- Transcribe a recording to MIDI, then open it in GarageBand or Logic Pro
- Inline rename, reveal in Finder, delete

## Requirements

- macOS 14.0 (Sonoma) or later

## Install

1. Download `rec.zip` from [Releases](https://github.com/mikemckain/rec/releases/latest)
2. Unzip and move `rec.app` to your Applications folder
3. First launch: right-click the app, then click Open (macOS will warn about unsigned app — one-time step)
4. Grant Screen Recording permission when prompted (required for system audio capture)

## Transcription

Any recording can be turned into a MIDI file by a
[muscriptor](https://tr.ericsharma.xyz) server — the note-transcription service
this fork points at by default.

Press the ♪ button on a row. rec uploads the audio, waits for the model, and
writes the result beside the recording as `<name>.mid`. A second button then
appears on that row to hand the file to your DAW.

Renaming or deleting a recording carries its `.mid` along with it.

### Settings

| Setting | Notes |
|---|---|
| **Transcription server** | Any muscriptor instance. Defaults to `https://tr.ericsharma.xyz`; point it at `http://your-host:8222` to use one on your LAN. |
| **Instruments** | Restrict the model to specific instruments, or leave it on *Auto-detect*. The list is pulled from the server, so it always matches the model it's running. |
| **Open MIDI in** | GarageBand or Logic Pro. Both declare `.mid` as an openable type, so the file lands in a new project. |
| **Open automatically after transcribing** | Skips the second click. |

### Running your own server

muscriptor is a self-contained FastAPI service:

```
uvx muscriptor serve --model medium --device mps --host 0.0.0.0 --port 8222
```

`--device mps` transcribes several times faster than real time on Apple
Silicon. `fluidsynth` is only needed for the server's audio-preview endpoint,
not for the MIDI export rec uses.
