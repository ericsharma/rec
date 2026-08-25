import Foundation
import AppKit

// MARK: - Target DAW

/// The two Apple DAWs that declare `public.midi-audio` in their
/// CFBundleDocumentTypes, so `NSWorkspace.open` hands them the file directly
/// rather than bouncing it to the default handler.
enum DAW: String, CaseIterable {
    case garageBand = "GarageBand"
    case logicPro = "Logic Pro"

    var bundleIdentifier: String {
        switch self {
        case .garageBand: return "com.apple.garageband10"
        case .logicPro: return "com.apple.logic10"
        }
    }

    var icon: String {
        switch self {
        case .garageBand: return "guitars"
        case .logicPro: return "slider.horizontal.3"
        }
    }

    /// nil when the app isn't installed — the UI greys the option out.
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var isInstalled: Bool { applicationURL != nil }
}

// MARK: - Per-recording state

enum TranscriptionState: Equatable {
    case idle
    case running
    case failed(String)
}

// MARK: - Manager

/// Talks to a muscriptor server (https://github.com/…/muscriptor — the same
/// service the /instruments and /transcribe/midi endpoints below belong to).
///
/// `/transcribe/midi` is used rather than `/transcribe` because it blocks until
/// the model is done and returns raw MIDI bytes, so there's no SSE stream or
/// base64 payload to unpack — the response body goes straight to disk.
@MainActor
final class TranscriptionManager: ObservableObject {
    static let defaultServerURL = "https://tr.ericsharma.xyz"

    /// Used when the server can't be reached for its own list. Kept in sync
    /// with muscriptor's GM instrument groups.
    static let fallbackInstruments = [
        "acoustic_piano", "electric_piano", "acoustic_guitar", "clean_electric_guitar",
        "acoustic_bass", "electric_bass", "violin", "cello", "string_ensemble",
        "voice", "trumpet", "saxophone", "flutes", "synth_lead", "synth_pad", "drums",
    ]

    @Published private(set) var states: [URL: TranscriptionState] = [:]
    @Published private(set) var availableInstruments: [String] = TranscriptionManager.fallbackInstruments

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "transcriptionServerURL") }
    }

    /// Empty means "let the model decide" — muscriptor treats an absent
    /// `instruments` field as auto-detect.
    @Published var instruments: [String] {
        didSet { UserDefaults.standard.set(instruments, forKey: "transcriptionInstruments") }
    }

    @Published var daw: DAW {
        didSet { UserDefaults.standard.set(daw.rawValue, forKey: "transcriptionDAW") }
    }

    @Published var openAfterTranscribe: Bool {
        didSet { UserDefaults.standard.set(openAfterTranscribe, forKey: "transcriptionOpenAfter") }
    }

    /// The General MIDI sound stamped into the transcription, so the DAW opens
    /// it on tracks that make noise without being routed by hand first.
    @Published var trackSound: TrackSound {
        didSet { UserDefaults.standard.set(trackSound.storageValue, forKey: "transcriptionTrackSound") }
    }

    /// Overrides the tempo muscriptor detected. Empty means "trust the server",
    /// which is right whenever detection worked — Logic honours the file's tempo
    /// map, so a correct detection already opens the project at the right BPM.
    @Published var tempoOverride: String {
        didSet { UserDefaults.standard.set(tempoOverride, forKey: "transcriptionTempo") }
    }

    /// nil when the server's own tempo map should stand.
    private var tempoBPM: Double? {
        let trimmed = tempoOverride.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let bpm = Double(trimmed), bpm > 0 else { return nil }
        return bpm
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Transcription is synchronous on the server and model-bound: a few
        // minutes of audio on a busy box can outrun the 60s default easily.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    init() {
        serverURL = UserDefaults.standard.string(forKey: "transcriptionServerURL")
            ?? Self.defaultServerURL
        instruments = UserDefaults.standard.stringArray(forKey: "transcriptionInstruments") ?? []
        daw = UserDefaults.standard.string(forKey: "transcriptionDAW")
            .flatMap(DAW.init(rawValue:))
            ?? (DAW.logicPro.isInstalled ? .logicPro : .garageBand)
        openAfterTranscribe = UserDefaults.standard.bool(forKey: "transcriptionOpenAfter")
        trackSound = TrackSound(
            storageValue: UserDefaults.standard.string(forKey: "transcriptionTrackSound")
        )
        tempoOverride = UserDefaults.standard.string(forKey: "transcriptionTempo") ?? ""

        Task { await refreshInstruments() }
    }

    func state(for recording: AudioCaptureManager.Recording) -> TranscriptionState {
        states[recording.url] ?? .idle
    }

    func clearError(for recording: AudioCaptureManager.Recording) {
        if case .failed = state(for: recording) { states[recording.url] = .idle }
    }

    /// Pulls the server's own instrument list so the picker matches whatever
    /// model that server is running. Silently keeps the fallback on failure —
    /// this is cosmetic, and `transcribe` reports real connection errors.
    func refreshInstruments() async {
        guard let url = endpoint("instruments") else { return }
        struct Response: Decodable { let instruments: [String] }
        guard let (data, _) = try? await session.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !decoded.instruments.isEmpty
        else { return }
        availableInstruments = decoded.instruments
        // Drop anything this server doesn't know about, or it 422s every run.
        instruments = instruments.filter(decoded.instruments.contains)
    }

    /// Transcribes `recording` and writes the MIDI beside it as `<name>.mid`.
    /// Returns the MIDI URL on success.
    @discardableResult
    func transcribe(_ recording: AudioCaptureManager.Recording) async -> URL? {
        guard state(for: recording) != .running else { return nil }

        guard let url = endpoint("transcribe/midi") else {
            states[recording.url] = .failed("Invalid server URL")
            return nil
        }

        states[recording.url] = .running
        defer { if states[recording.url] == .running { states[recording.url] = .idle } }

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL: URL
        do {
            bodyURL = try makeMultipartBody(audio: recording.url, boundary: boundary)
        } catch {
            states[recording.url] = .failed("Couldn't read recording")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("rec", forHTTPHeaderField: "X-Client-Id")

        do {
            let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
            guard let http = response as? HTTPURLResponse else {
                states[recording.url] = .failed("Bad response from server")
                return nil
            }
            guard http.statusCode == 200 else {
                states[recording.url] = .failed(Self.serverError(status: http.statusCode, body: data))
                return nil
            }
            guard !data.isEmpty else {
                states[recording.url] = .failed("Server returned an empty file")
                return nil
            }

            let midiURL = recording.midiURL
            let plan = patchPlan
            // Falls back to the server's bytes untouched if they don't parse —
            // a silent MIDI file beats one this mangled into not opening.
            let prepared = StandardMIDIFile.prepare(
                data, patches: plan.patches, fallback: plan.fallback, tempoBPM: tempoBPM
            ) ?? data
            try prepared.write(to: midiURL, options: .atomic)
            states[recording.url] = .idle
            return midiURL
        } catch {
            states[recording.url] = .failed(Self.connectionError(error, host: serverURL))
            return nil
        }
    }

    /// The patches to stamp onto the transcribed tracks, in track order.
    ///
    /// The server returns one track per instrument in the order they were
    /// requested, so an explicit instrument list maps straight onto the tracks.
    /// Auto-detect tells us nothing, so everything gets the fallback.
    private var patchPlan: (patches: [GMPatch], fallback: GMPatch) {
        switch trackSound {
        case .fixed(let patch):
            return ([], patch)
        case .automatic:
            let mapped = instruments.compactMap(GMPatch.matching)
            return (mapped, mapped.first ?? .grandPiano)
        }
    }

    /// Opens the MIDI in the configured DAW, falling back to the system handler
    /// when that DAW isn't installed. Returns an error string on failure.
    func open(midiAt midiURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: midiURL.path) else {
            return "MIDI file is missing — transcribe again"
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let app = daw.applicationURL {
            NSWorkspace.shared.open([midiURL], withApplicationAt: app, configuration: configuration)
            return nil
        }
        guard NSWorkspace.shared.open(midiURL) else {
            return "\(daw.rawValue) isn't installed"
        }
        return nil
    }

    // MARK: - Helpers

    private func endpoint(_ path: String) -> URL? {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base), components.host != nil else { return nil }
        if components.scheme == nil { components.scheme = "https" }
        let trimmed = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = trimmed + "/" + path
        return components.url
    }

    /// Builds the multipart payload on disk rather than in memory — a long WAV
    /// is easily hundreds of megabytes, and `upload(for:fromFile:)` streams it.
    private func makeMultipartBody(audio: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        func write(_ string: String) throws {
            try handle.write(contentsOf: Data(string.utf8))
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")

        let source = try FileHandle(forReadingFrom: audio)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try write("\r\n")

        // Repeated fields — FastAPI collects same-named parts into the list.
        for instrument in instruments {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"instruments\"\r\n\r\n")
            try write("\(instrument)\r\n")
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"detect_tempo\"\r\n\r\n")
        try write("best-effort\r\n")
        try write("--\(boundary)--\r\n")

        return bodyURL
    }

    private static func serverError(status: Int, body: Data) -> String {
        // FastAPI puts the reason in `detail`, which is either a string or a
        // list of validation objects.
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? String {
                return detail
            }
            if let items = json["detail"] as? [[String: Any]],
               let message = items.first?["msg"] as? String {
                return message
            }
        }
        return "Transcription failed (HTTP \(status))"
    }

    private static func connectionError(_ error: Error, host: String) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .some(.cannotFindHost), .some(.cannotConnectToHost), .some(.notConnectedToInternet):
            return "Can't reach \(host)"
        case .some(.timedOut):
            return "Transcription timed out"
        default:
            return error.localizedDescription
        }
    }
}
