import Foundation

/// On-demand cache refresh, used right after a mutation.
///
/// The background poller re-reads tracks only every ~2 s. A `logic://tracks` read taken
/// immediately after a successful change therefore returned the state from *before* it —
/// which is exactly what made a genuinely failed `duplicate` and a merely stale cache
/// indistinguishable during diagnosis. Mutating commands now push the fresh state into
/// the cache themselves, so the resources agree with what the tool just reported.
enum StateRefresh {
    static func tracks(router: ChannelRouter, cache: StateCache) async {
        let result = await router.route(operation: "track.get_tracks")
        guard case .success(let json) = result, let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let tracks = try? decoder.decode([TrackState].self, from: data) else { return }
        await cache.updateTracks(tracks)
    }
}
