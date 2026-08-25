import Foundation

// MARK: - General MIDI patches

/// A General MIDI voice, named the way a Standard MIDI File names one.
///
/// rec can't tell a DAW what *kind* of track to create. Neither Logic Pro nor
/// GarageBand exposes track creation to AppleScript — Logic ships only the
/// Standard Suite, and GarageBand's entire custom suite is a single
/// `renderPreview` command — and Logic has no preference governing MIDI file
/// import. The one lever that travels with the music is the file itself: a GM
/// System On SysEx marks it as General MIDI, and a program change per track
/// picks the patch. muscriptor returns neither, which is why an untouched
/// transcription opens on tracks that need an instrument and routing by hand
/// before anything reaches the speakers.
struct GMPatch: Identifiable, Hashable {
    /// 0-based, as it appears in a program change. GM documents its sounds
    /// 1-based, so "Acoustic Grand Piano" is program 1 there and 0 here.
    let program: UInt8
    let name: String
    /// GM addresses percussion by channel rather than by program: every note on
    /// channel 10 is a drum, whatever program that channel was last sent.
    let isPercussion: Bool

    var id: String { isPercussion ? "drums" : "gm:\(program)" }

    init(_ program: UInt8, _ name: String, isPercussion: Bool = false) {
        self.program = program
        self.name = name
        self.isPercussion = isPercussion
    }

    /// 0-based, i.e. MIDI channel 10.
    static let percussionChannel: UInt8 = 9
}

extension GMPatch {
    static let grandPiano = GMPatch(0, "Acoustic Grand Piano")
    static let drumKit = GMPatch(0, "Drum Kit", isPercussion: true)

    /// Offered in the settings picker — a curated slice of GM rather than all
    /// 128 voices. These cover what muscriptor transcribes, and nobody wants to
    /// scroll a 128-item menu to find a piano.
    static let selectable: [GMPatch] = [
        grandPiano,
        GMPatch(4,  "Electric Piano"),
        GMPatch(6,  "Harpsichord"),
        GMPatch(11, "Vibraphone"),
        GMPatch(16, "Drawbar Organ"),
        GMPatch(24, "Nylon Guitar"),
        GMPatch(25, "Steel Guitar"),
        GMPatch(27, "Clean Electric Guitar"),
        GMPatch(32, "Acoustic Bass"),
        GMPatch(33, "Fingered Electric Bass"),
        GMPatch(40, "Violin"),
        GMPatch(42, "Cello"),
        GMPatch(48, "String Ensemble"),
        GMPatch(52, "Choir Aahs"),
        GMPatch(56, "Trumpet"),
        GMPatch(65, "Alto Sax"),
        GMPatch(73, "Flute"),
        GMPatch(80, "Square Lead"),
        GMPatch(88, "New Age Pad"),
        drumKit,
    ]

    /// muscriptor's instrument group names mapped onto the closest GM voice.
    /// Unknown names fall through to nil so the caller can use its own default
    /// rather than silently claiming the model produced a piano.
    static func matching(_ instrument: String) -> GMPatch? {
        switch instrument {
        case "acoustic_piano":        return grandPiano
        case "electric_piano":        return GMPatch(4,  "Electric Piano")
        case "acoustic_guitar":       return GMPatch(24, "Nylon Guitar")
        case "clean_electric_guitar": return GMPatch(27, "Clean Electric Guitar")
        case "acoustic_bass":         return GMPatch(32, "Acoustic Bass")
        case "electric_bass":         return GMPatch(33, "Fingered Electric Bass")
        case "violin":                return GMPatch(40, "Violin")
        case "cello":                 return GMPatch(42, "Cello")
        case "string_ensemble":       return GMPatch(48, "String Ensemble")
        case "voice":                 return GMPatch(52, "Choir Aahs")
        case "trumpet":               return GMPatch(56, "Trumpet")
        case "saxophone":             return GMPatch(65, "Alto Sax")
        case "flutes":                return GMPatch(73, "Flute")
        case "synth_lead":            return GMPatch(80, "Square Lead")
        case "synth_pad":             return GMPatch(88, "New Age Pad")
        case "drums":                 return drumKit
        default:                      return nil
        }
    }

    static func withID(_ id: String) -> GMPatch? {
        selectable.first { $0.id == id }
    }
}

// MARK: - Chosen sound

/// What the transcribed tracks should ask to be played with.
enum TrackSound: Hashable {
    /// Follow the instruments the transcription was restricted to, in order,
    /// falling back to piano when the model was left to auto-detect.
    case automatic
    case fixed(GMPatch)

    var storageValue: String {
        switch self {
        case .automatic: return "auto"
        case .fixed(let patch): return patch.id
        }
    }

    init(storageValue: String?) {
        guard let storageValue, storageValue != "auto",
              let patch = GMPatch.withID(storageValue)
        else { self = .automatic; return }
        self = .fixed(patch)
    }
}

// MARK: - Standard MIDI File

/// Just enough SMF reading and writing to retag what the transcription server
/// produced. muscriptor returns format 1 at 480 ppqn carrying a tempo map and
/// nothing else — no track names, no program changes, no GM declaration.
enum StandardMIDIFile {

    /// Rewrites `data` so a DAW opening it instantiates sounds rather than empty
    /// tracks. `patches` are consumed in track order for note-bearing tracks;
    /// `fallback` covers every track past the end of that list, which is also how
    /// a single fixed choice gets applied to all of them.
    ///
    /// Returns nil when the bytes aren't an SMF this understands. Callers keep
    /// the server's file in that case: a MIDI file that opens silently still
    /// beats one that has been corrupted into not opening at all.
    static func addingGeneralMIDI(to data: Data, patches: [GMPatch], fallback: GMPatch) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, Array(bytes[0..<4]) == Array("MThd".utf8) else { return nil }
        guard var chunks = split(bytes), chunks.first?.type == "MThd" else { return nil }

        var queue = patches
        var declaredGM = false

        for index in chunks.indices where chunks[index].type == "MTrk" {
            guard let scan = scan(chunks[index].body) else { return nil }
            var prefix: [UInt8] = []

            // GM System On, once, at the head of the first track. This is what
            // tells a host to treat the file as General MIDI at all; without it
            // the program changes below are just channel data it may ignore.
            if !declaredGM {
                prefix += varLen(0) + [0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7]
                declaredGM = true
            }

            if scan.hasNotes {
                let patch = queue.isEmpty ? fallback : queue.removeFirst()
                let channel = patch.isPercussion ? GMPatch.percussionChannel : (scan.firstChannel ?? 0)

                if patch.isPercussion {
                    // Percussion is the one sound a program change can't select,
                    // so move the notes to channel 10 instead of trusting
                    // whichever channel the server happened to write.
                    for offset in scan.statusOffsets {
                        chunks[index].body[offset] =
                            (chunks[index].body[offset] & 0xF0) | GMPatch.percussionChannel
                    }
                }

                if !scan.hasName {
                    let name = Array(patch.name.utf8.prefix(127))
                    prefix += varLen(0) + [0xFF, 0x03] + varLen(name.count) + name
                }
                prefix += varLen(0) + [0xC0 | channel, patch.program]
            }

            chunks[index].body = prefix + chunks[index].body
        }

        return Data(join(chunks))
    }

    // MARK: - Chunks

    private struct Chunk {
        let type: String
        var body: [UInt8]
    }

    private static func split(_ bytes: [UInt8]) -> [Chunk]? {
        var chunks: [Chunk] = []
        var i = 0
        while i + 8 <= bytes.count {
            let type = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let length = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16
                       | Int(bytes[i + 6]) << 8  | Int(bytes[i + 7])
            let start = i + 8
            guard length >= 0, start + length <= bytes.count else { return nil }
            chunks.append(Chunk(type: type, body: Array(bytes[start..<start + length])))
            i = start + length
        }
        return chunks.isEmpty ? nil : chunks
    }

    private static func join(_ chunks: [Chunk]) -> [UInt8] {
        var out: [UInt8] = []
        for chunk in chunks {
            let length = chunk.body.count
            out += Array(chunk.type.utf8)
            out += [UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                    UInt8((length >> 8) & 0xFF),  UInt8(length & 0xFF)]
            out += chunk.body
        }
        return out
    }

    // MARK: - Track scanning

    private struct TrackScan {
        var hasNotes = false
        var hasName = false
        var firstChannel: UInt8?
        /// Byte offsets of channel-voice status bytes, for retargeting the
        /// channel. Events running-status into the previous one have no status
        /// byte of their own and inherit whatever we rewrite here.
        var statusOffsets: [Int] = []
    }

    private static func scan(_ body: [UInt8]) -> TrackScan? {
        var scan = TrackScan()
        var running: UInt8?
        var i = 0

        while i < body.count {
            guard let (_, afterDelta) = readVarLen(body, i) else { return nil }
            i = afterDelta
            guard i < body.count else { return nil }

            var status = body[i]
            var statusOffset = i
            if status < 0x80 {
                // Running status: reuse the previous status byte, and record no
                // offset because this event doesn't carry one.
                guard let previous = running else { return nil }
                status = previous
                statusOffset = -1
            } else {
                i += 1
                running = status < 0xF0 ? status : nil
            }

            switch status {
            case 0xFF:
                guard i < body.count else { return nil }
                let type = body[i]
                i += 1
                guard let (length, afterLength) = readVarLen(body, i) else { return nil }
                i = afterLength + length
                if type == 0x03 { scan.hasName = true }
                if type == 0x2F { return i <= body.count ? scan : nil }
            case 0xF0, 0xF7:
                guard let (length, afterLength) = readVarLen(body, i) else { return nil }
                i = afterLength + length
            default:
                let kind = status & 0xF0
                if scan.firstChannel == nil { scan.firstChannel = status & 0x0F }
                if statusOffset >= 0 { scan.statusOffsets.append(statusOffset) }
                if kind == 0x90 { scan.hasNotes = true }
                i += (kind == 0xC0 || kind == 0xD0) ? 1 : 2
            }
            guard i <= body.count else { return nil }
        }
        return scan
    }

    // MARK: - Variable-length quantities

    private static func readVarLen(_ bytes: [UInt8], _ start: Int) -> (value: Int, next: Int)? {
        var value = 0
        var i = start
        // An SMF variable-length quantity is four bytes at most.
        for _ in 0..<4 {
            guard i < bytes.count else { return nil }
            let byte = bytes[i]
            i += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return (value, i) }
        }
        return nil
    }

    private static func varLen(_ value: Int) -> [UInt8] {
        var remaining = value >> 7
        var out: [UInt8] = [UInt8(value & 0x7F)]
        while remaining > 0 {
            out.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
            remaining >>= 7
        }
        return out
    }
}
