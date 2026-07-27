import Foundation

/// Transport state from Logic Pro.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isPaused: Bool = false
    var isCycleEnabled: Bool = false
    var isMetronomeEnabled: Bool = false
    /// nil when the tempo display could not be read — not a silently invented 120.
    var tempo: Double?
    /// Bar.Beat.Division.Tick, nil when not readable.
    var position: String?
    /// HH:MM:SS:FF. Logic only exposes the fields of the ruler's *current* display mode,
    /// so this stays nil while the control bar shows bars & beats.
    var timePosition: String?
    var sampleRate: Int = 44100
    var lastUpdated: Date = .distantPast

    /// Hand-written so unreadable values appear as explicit `null`; the synthesized
    /// encoder would drop the keys entirely.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(isCycleEnabled, forKey: .isCycleEnabled)
        try container.encode(isMetronomeEnabled, forKey: .isMetronomeEnabled)
        try container.encode(tempo, forKey: .tempo)
        try container.encode(position, forKey: .position)
        try container.encode(timePosition, forKey: .timePosition)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
}

/// Track types in Logic Pro.
enum TrackType: String, Sendable, Codable {
    case audio
    case softwareInstrument = "software_instrument"
    case drummer
    case externalMIDI = "external_midi"
    case aux
    case bus
    case master
    /// Folder or Summing Stack master row (has a disclosure triangle).
    case trackStack = "track_stack"
    case unknown
}

/// A single track's state.
struct TrackState: Sendable, Codable, Identifiable {
    let id: Int          // 0-based index
    var name: String
    var type: TrackType
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isArmed: Bool = false
    var isSelected: Bool = false
    /// nil when the fader could not be read — NOT the same as 0. Logic stops exposing the
    /// header sliders at small track heights; reporting 0 there looked like the project
    /// had lost all its levels and invited "restoring" values that were never lost.
    var volume: Double?
    /// nil when the pan control could not be read. See `volume`.
    var pan: Double?
    var color: String?

    /// Written by hand so unreadable values appear as an explicit `null` in the JSON.
    /// The synthesized encoder omits nil keys entirely, which leaves a reader guessing
    /// whether a value is missing or was never asked for.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isSoloed, forKey: .isSoloed)
        try container.encode(isArmed, forKey: .isArmed)
        try container.encode(isSelected, forKey: .isSelected)
        try container.encode(volume, forKey: .volume)
        try container.encode(pan, forKey: .pan)
        try container.encode(color, forKey: .color)
    }
}

/// Mixer channel strip state (extends track with routing info).
struct ChannelStripState: Sendable, Codable {
    var trackIndex: Int
    /// nil when the fader could not be read (see `TrackState.volume`).
    var volume: Double?
    /// nil when the pan control could not be read.
    var pan: Double?
    var sends: [SendState] = []
    var input: String?
    var output: String?
    var eqEnabled: Bool = false
    var plugins: [PluginSlotState] = []

    /// Explicit `null` for unreadable controls — see `TrackState.encode(to:)`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackIndex, forKey: .trackIndex)
        try container.encode(volume, forKey: .volume)
        try container.encode(pan, forKey: .pan)
        try container.encode(sends, forKey: .sends)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(eqEnabled, forKey: .eqEnabled)
        try container.encode(plugins, forKey: .plugins)
    }
}

/// A send on a channel strip.
struct SendState: Sendable, Codable {
    var index: Int
    var destination: String
    var level: Double
    var isPreFader: Bool
}

/// A plugin slot.
struct PluginSlotState: Sendable, Codable {
    var index: Int
    var name: String
    var isBypassed: Bool
}

/// Region info.
struct RegionState: Sendable, Codable, Identifiable {
    let id: String
    var name: String
    var trackIndex: Int
    var startPosition: String   // Bar.Beat
    var endPosition: String
    var length: String
    var isSelected: Bool = false
    var isLooped: Bool = false
}

/// Marker info.
struct MarkerState: Sendable, Codable, Identifiable {
    let id: Int
    var name: String
    var position: String
}

/// Automation mode.
enum AutomationMode: String, Sendable, Codable {
    case off
    case read
    case touch
    case latch
    case write
}

/// Project-level info.
struct ProjectInfo: Sendable, Codable {
    var name: String = ""
    var sampleRate: Int = 44100
    var bitDepth: Int = 24
    var tempo: Double = 120.0
    var timeSignature: String = "4/4"
    var trackCount: Int = 0
    var filePath: String?
    var lastUpdated: Date = .distantPast
}
