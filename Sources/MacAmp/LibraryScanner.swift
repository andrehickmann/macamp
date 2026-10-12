import AVFoundation
import MacAmpCore
import UniformTypeIdentifiers

/// Tags read through AVFoundation across the ID3, iTunes/MP4, QuickTime and Vorbis comment key spaces.
struct Tags: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var duration: Double?

    /// "Artist - Title" for playlist entries.
    var displayTitle: String? { title.map { title in artist.map { "\($0) - \(title)" } ?? title } }

    private enum Field { case title, artist, album, genre, year, track }

    private static let fields: [String: Field] = [
        "tit2": .title, "tt2": .title, "©nam": .title, "title": .title,
        "tpe1": .artist, "tp1": .artist, "©art": .artist, "artist": .artist,
        "talb": .album, "tal": .album, "©alb": .album, "album": .album, "albumname": .album,
        "tcon": .genre, "tco": .genre, "©gen": .genre, "genre": .genre,
        "tyer": .year, "tdrc": .year, "tye": .year, "©day": .year, "date": .year, "year": .year, "creationdate": .year,
        "trck": .track, "trk": .track, "trkn": .track, "tracknumber": .track,
    ]

    static func read(from url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        guard let (metadata, duration) = try? await asset.load(.metadata, .duration) else { return Tags() }
        var tags = Tags()
        tags.duration = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : nil
        for item in metadata {
            guard let field = field(of: item) else { continue }
            let text = try? await item.load(.stringValue)
            switch field {
            case .title: tags.title = tags.title ?? text
            case .artist: tags.artist = tags.artist ?? text
            case .album: tags.album = tags.album ?? text
            case .genre: tags.genre = tags.genre ?? text
            case .year: tags.year = tags.year ?? text.flatMap(leadingNumber).flatMap { $0 > 999 ? $0 : nil }
            case .track:
                if tags.trackNumber == nil {
                    // MP4 "trkn" is binary: two padding bytes, then the track number as UInt16.
                    let data = text == nil ? try? await item.load(.dataValue) : nil
                    tags.trackNumber = text.flatMap(leadingNumber) ?? data.flatMap { $0.count >= 4 ? Int($0[2]) << 8 | Int($0[3]) : nil }
                }
            }
        }
        return tags
    }

    /// Normalizes identifiers like "id3/TIT2", "itsk/%A9nam" or "com.apple.quicktime.title" to a key of `fields`.
    private static func field(of item: AVMetadataItem) -> Field? {
        let raw = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? ""
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let decoded = (last.removingPercentEncoding ?? last).lowercased()
        return fields[decoded] ?? fields[decoded.split(separator: ".").last.map(String.init) ?? decoded]
            ?? item.commonKey.flatMap { fields[$0.rawValue.lowercased()] }
    }

    private static func leadingNumber(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }
}

/// Finds audio files below the library folders and reads tags of new or changed ones.
enum LibraryScanner {
    struct Result: Sendable {
        var tracks: [LibraryTrack]
        var present: Set<URL>
    }

    /// `known` maps already indexed files to their recorded modification date; unchanged files are skipped.
    static func scan(folders: [URL], known: [URL: Date],
                     progress: @escaping @Sendable (Int, Int) -> Void) async -> Result {
        let files = audioFiles(in: folders)
        let changed = files.filter { known[$0.url] == nil || known[$0.url] != $0.modified }
        var tracks: [LibraryTrack] = []
        // Read tags eight files at a time.
        for start in stride(from: 0, to: changed.count, by: 8) {
            let batch = changed[start..<min(start + 8, changed.count)]
            let read = await withTaskGroup(of: LibraryTrack.self) { group in
                for file in batch {
                    group.addTask {
                        let tags = await Tags.read(from: file.url)
                        var track = LibraryTrack(url: file.url)
                        track.title = tags.title
                        track.artist = tags.artist
                        track.album = tags.album
                        track.genre = tags.genre
                        track.year = tags.year
                        track.trackNumber = tags.trackNumber
                        track.duration = tags.duration
                        track.fileModified = file.modified
                        return track
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            tracks += read
            progress(min(start + 8, changed.count), changed.count)
        }
        return Result(tracks: tracks, present: Set(files.map(\.url)))
    }

    private static func audioFiles(in folders: [URL]) -> [(url: URL, modified: Date?)] {
        var files: [(URL, Date?)] = []
        for folder in folders {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { continue }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                files.append((url.standardizedFileURL, modified))
            }
        }
        return files
    }
}
