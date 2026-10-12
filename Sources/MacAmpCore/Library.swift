import Foundation

public struct LibraryTrack: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var duration: Double?
    public var dateAdded: Date
    public var fileModified: Date?
    public var playCount = 0
    public var lastPlayed: Date?
    /// 0 (unrated) ... 5 stars.
    public var rating = 0

    public init(url: URL, dateAdded: Date = Date()) {
        self.url = url
        self.dateAdded = dateAdded
    }

    /// "Artist - Title" like playlist entries, falling back to the file name.
    public var displayTitle: String {
        guard let title else { return url.deletingPathExtension().lastPathComponent }
        return artist.map { "\($0) - \(title)" } ?? title
    }
}

public struct SavedPlaylist: Codable, Equatable, Sendable {
    public var name: String
    public var entries: [PlaylistEntry]

    public init(name: String, entries: [PlaylistEntry]) {
        self.name = name
        self.entries = entries
    }
}

/// The media library: watched folders, their tracks with play statistics, and saved playlists.
public struct Library: Codable, Equatable, Sendable {
    public enum View: Hashable, Sendable, CaseIterable {
        case audio, mostPlayed, recentlyAdded, recentlyPlayed, neverPlayed, topRated

        public var title: String {
            switch self {
            case .audio: "Audio"
            case .mostPlayed: "Most Played"
            case .recentlyAdded: "Recently Added"
            case .recentlyPlayed: "Recently Played"
            case .neverPlayed: "Never Played"
            case .topRated: "Top Rated"
            }
        }
    }

    public var folders: [URL] = []
    public var tracks: [LibraryTrack] = []
    public var playlists: [SavedPlaylist] = []

    public init() {}

    /// Tracks of a smart view filtered by `query`; every whitespace-separated term must match
    /// title, artist, album or genre (case- and diacritic-insensitive).
    public func tracks(in view: View, matching query: String = "", now: Date = Date()) -> [LibraryTrack] {
        let selected: [LibraryTrack] = switch view {
        case .audio:
            tracks
        case .mostPlayed:
            tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
        case .recentlyAdded:
            tracks.filter { now.timeIntervalSince($0.dateAdded) < 30 * 24 * 3600 }.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed:
            tracks.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }
        case .neverPlayed:
            tracks.filter { $0.playCount == 0 }
        case .topRated:
            tracks.filter { $0.rating >= 4 }.sorted { $0.rating > $1.rating }
        }
        return Self.filter(selected, query: query)
    }

    public static func filter(_ tracks: [LibraryTrack], query: String) -> [LibraryTrack] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return tracks }
        return tracks.filter { track in
            let haystack = [track.title, track.artist, track.album, track.genre, track.url.lastPathComponent]
                .compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Matches by standardized path, since panels, drops and scans can produce differently formed URLs.
    public func index(of url: URL) -> Int? {
        let path = url.standardizedFileURL.path
        return tracks.firstIndex { $0.url.standardizedFileURL.path == path }
    }

    /// Counts a play and updates "last played" if the file belongs to the library.
    public mutating func recordPlay(of url: URL, at date: Date = Date()) {
        guard let index = index(of: url) else { return }
        tracks[index].playCount += 1
        tracks[index].lastPlayed = date
    }

    /// Applies a scan result: adds new files, refreshes tags of changed ones (keeping play
    /// statistics and ratings) and drops tracks below `scannedFolders` whose files are gone.
    public mutating func merge(_ scanned: [LibraryTrack], present: Set<URL>, scannedFolders: [URL]) {
        var byURL = Dictionary(uniqueKeysWithValues: tracks.map { ($0.url, $0) })
        for var track in scanned {
            if let existing = byURL[track.url] {
                track.dateAdded = existing.dateAdded
                track.playCount = existing.playCount
                track.lastPlayed = existing.lastPlayed
                track.rating = existing.rating
            }
            byURL[track.url] = track
        }
        let prefixes = scannedFolders.map { $0.standardizedFileURL.path + "/" }
        tracks = byURL.values
            .filter { track in present.contains(track.url) || !prefixes.contains { track.url.path.hasPrefix($0) } }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}
