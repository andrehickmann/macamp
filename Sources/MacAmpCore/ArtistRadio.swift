import Foundation

/// An artist's popular songs and an artist radio from MusicBrainz and ListenBrainz (no account needed), mapped to
/// Spotify tracks. Replaces Spotify's top tracks, related artists and recommendations, which development-mode apps
/// can no longer use.
public enum ArtistRadio {
    public struct Recording: Decodable, Sendable, Equatable {
        public var recordingMbid: String
        public var recordingName: String
        public var artistName: String
        public var length: Int?

        public init(recordingMbid: String, recordingName: String, artistName: String, length: Int? = nil) {
            self.recordingMbid = recordingMbid
            self.recordingName = recordingName
            self.artistName = artistName
            self.length = length
        }
    }

    /// The artist's most listened songs on ListenBrainz that Spotify has.
    public static func topTracks(spotifyArtistID: String, limit: Int = 20) async throws -> [LibraryTrack] {
        guard let mbid = try await artistMBID(spotifyArtistID: spotifyArtistID) else { return [] }
        return try await spotifyTracks(for: Array(try await topRecordings(artistMBID: mbid).prefix(limit)))
    }

    /// About 30 songs: some by the artist, the rest by similar artists, shuffled with the artist first.
    public static func radio(spotifyArtistID: String) async throws -> [LibraryTrack] {
        guard let mbid = try await artistMBID(spotifyArtistID: spotifyArtistID) else { return [] }
        let similar = try await similarArtists(artistMBID: mbid).prefix(10)
        let lists = await withTaskGroup(of: (Int, [Recording]).self) { group in
            for (index, artist) in ([mbid] + similar).enumerated() {
                group.addTask { (index, (try? await topRecordings(artistMBID: artist)) ?? []) }
            }
            var lists = [[Recording]](repeating: [], count: similar.count + 1)
            for await (index, recordings) in group { lists[index] = recordings }
            return lists
        }
        var generator = SystemRandomNumberGenerator()
        return try await spotifyTracks(for: mix(seed: lists[0], similar: Array(lists.dropFirst()), using: &generator))
    }

    /// Picks four of the seed artist's ten most popular songs and three of each similar artist's, shuffles them and
    /// moves a seed song to the front.
    public static func mix<G: RandomNumberGenerator>(seed: [Recording], similar: [[Recording]], using generator: inout G)
        -> [Recording] {
        func pick(_ recordings: [Recording], _ count: Int) -> [Recording] {
            Array(recordings.prefix(10).shuffled(using: &generator).prefix(count))
        }
        let seedPicks = pick(seed, 4)
        var songs = (seedPicks + similar.flatMap { pick($0, 3) }).shuffled(using: &generator)
        if let first = seedPicks.first, let index = songs.firstIndex(of: first) { songs.swapAt(0, index) }
        return songs
    }

    // MARK: Requests

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// MusicBrainz links artists to their Spotify page; nil if it doesn't know this one.
    static func artistMBID(spotifyArtistID id: String) async throws -> String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        struct Artist: Decodable { var id: String }
        struct Relation: Decodable { var artist: Artist? }
        struct Result: Decodable { var relations: [Relation]? }
        let url = URL(string: "https://musicbrainz.org/ws/2/url?resource=https://open.spotify.com/artist/\(id)&inc=artist-rels&fmt=json")!
        guard let data = try await get(url, notFoundIsNil: true) else { return nil }
        return try decoder.decode(Result.self, from: data).relations?.compactMap(\.artist?.id).first
    }

    static func topRecordings(artistMBID mbid: String) async throws -> [Recording] {
        guard UUID(uuidString: mbid) != nil else { return [] }
        let url = URL(string: "https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/\(mbid)")!
        return try await get(url).map { try decoder.decode([Recording].self, from: $0) } ?? []
    }

    /// MBIDs of similar artists, most similar first.
    static func similarArtists(artistMBID mbid: String) async throws -> [String] {
        guard UUID(uuidString: mbid) != nil else { return [] }
        struct Artist: Decodable { var artistMbid: String; var score: Int }
        // ponytail: ListenBrainz's own default algorithm name; update it if the labs API drops it.
        let algorithm = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"
        let url = URL(string: "https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=\(mbid)&algorithm=\(algorithm)")!
        let artists = try await get(url).map { try decoder.decode([Artist].self, from: $0) } ?? []
        return artists.sorted { $0.score > $1.score }.map(\.artistMbid).filter { $0 != mbid }
    }

    /// Recordings as Spotify library rows in the same order; ones Spotify doesn't have are dropped.
    static func spotifyTracks(for recordings: [Recording]) async throws -> [LibraryTrack] {
        guard !recordings.isEmpty else { return [] }
        struct Match: Decodable { var recordingMbid: String; var spotifyTrackIds: [String] }
        var request = URLRequest(url: URL(string: "https://labs.api.listenbrainz.org/spotify-id-from-mbid/json")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: recordings.map { ["recording_mbid": $0.recordingMbid] })
        guard let data = try await get(request) else { return [] }
        let ids = Dictionary(try decoder.decode([Match].self, from: data).compactMap { match in
            match.spotifyTrackIds.first.map { (match.recordingMbid, $0) }
        }) { first, _ in first }
        return recordings.compactMap { recording in
            guard let id = ids[recording.recordingMbid], let url = URL(string: "spotify:track:\(id)") else { return nil }
            var track = LibraryTrack(url: url)
            track.title = recording.recordingName
            track.artist = recording.artistName
            track.duration = recording.length.map { Double($0) / 1000 }
            return track
        }
    }

    private static func get(_ url: URL, notFoundIsNil: Bool = false) async throws -> Data? {
        try await get(URLRequest(url: url), notFoundIsNil: notFoundIsNil)
    }

    /// MusicBrainz and ListenBrainz ask clients to identify themselves.
    private static func get(_ request: URLRequest, notFoundIsNil: Bool = false) async throws -> Data? {
        var request = request
        request.setValue("MacAmp (https://github.com/andrehickmann/macamp)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, notFoundIsNil { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }
}
