import Foundation

/// Thread-safe in-memory cache for Logic Pro project state.
/// Read by tools for instant response; written by the StatePoller.
actor StateCache {
    private(set) var transport = TransportState()
    private(set) var tracks: [TrackState] = []
    private(set) var channelStrips: [ChannelStripState] = []
    private(set) var regions: [RegionState] = []
    private(set) var markers: [MarkerState] = []
    private(set) var project = ProjectInfo()
    private(set) var automationMode = AutomationMode.off

    /// Timestamp of last tool call — drives adaptive poll intervals.
    private(set) var lastToolAccess: Date = .distantPast

    // MARK: - Read access (tools call these)

    func getTransport() -> TransportState { transport }
    func getTracks() -> [TrackState] { tracks }
    func getTrack(at index: Int) -> TrackState? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }
    func getSelectedTrack() -> TrackState? {
        tracks.first(where: { $0.isSelected })
    }
    func getChannelStrips() -> [ChannelStripState] { channelStrips }
    func getChannelStrip(at index: Int) -> ChannelStripState? {
        channelStrips.first(where: { $0.trackIndex == index })
    }
    func getRegions() -> [RegionState] { regions }
    func getMarkers() -> [MarkerState] { markers }
    func getProject() -> ProjectInfo { project }
    func getAutomationMode() -> AutomationMode { automationMode }

    // MARK: - Write access (poller calls these)

    func updateTransport(_ state: TransportState) {
        transport = state
    }

    func updateTracks(_ newTracks: [TrackState]) {
        tracks = newTracks
    }

    func updateTrack(at index: Int, mutator: (inout TrackState) -> Void) {
        guard tracks.indices.contains(index) else { return }
        mutator(&tracks[index])
    }

    func updateChannelStrips(_ strips: [ChannelStripState]) {
        channelStrips = strips
    }

    func updateRegions(_ newRegions: [RegionState]) {
        regions = newRegions
    }

    func updateMarkers(_ newMarkers: [MarkerState]) {
        markers = newMarkers
    }

    func updateProject(_ info: ProjectInfo) {
        project = info
    }

    func updateAutomationMode(_ mode: AutomationMode) {
        automationMode = mode
    }

    // MARK: - Tool access tracking

    func recordToolAccess() {
        lastToolAccess = Date()
    }

    func timeSinceLastToolAccess() -> TimeInterval {
        Date().timeIntervalSince(lastToolAccess)
    }

    // MARK: - Bulk state for diagnostics

    struct CacheSnapshot: Sendable {
        /// Seconds since the transport was last read successfully, or nil if it never was.
        /// nil rather than a number computed from `.distantPast` — that produced the
        /// nonsense "transport_age_sec: 63920839368" (≈2000 years) that looked like a
        /// broken timestamp conversion instead of "no transport read has ever succeeded".
        let transportAge: TimeInterval?
        let trackCount: Int
        let regionCount: Int
        let markerCount: Int
        let projectName: String
        let pollMode: String
    }

    func snapshot() -> CacheSnapshot {
        let idle = timeSinceLastToolAccess()
        let mode: String
        if idle < ServerConfig.lightIdleThreshold {
            mode = "active"
        } else if idle < ServerConfig.idleThreshold {
            mode = "light"
        } else {
            mode = "idle"
        }
        return CacheSnapshot(
            transportAge: transport.lastUpdated == .distantPast
                ? nil
                : Date().timeIntervalSince(transport.lastUpdated),
            trackCount: tracks.count,
            regionCount: regions.count,
            markerCount: markers.count,
            projectName: project.name,
            pollMode: mode
        )
    }
}
