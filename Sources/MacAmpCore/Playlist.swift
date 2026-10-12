import Foundation

public struct PlaylistEntry: Equatable, Codable, Sendable {
    public var url: URL
    /// "Artist - Title" from the file's tags, once loaded.
    public var title: String?
    public var duration: Double?

    public init(url: URL, title: String? = nil, duration: Double? = nil) {
        self.url = url
        self.title = title
        self.duration = duration
    }

    public var displayTitle: String { title ?? url.deletingPathExtension().lastPathComponent }
}

/// The play queue with its selection; all reordering keeps `current` and `selection` on the same entries.
public struct Playlist: Equatable, Sendable {
    public var entries: [PlaylistEntry] = []
    public var current: Int?
    public var selection = IndexSet()

    public init(entries: [PlaylistEntry] = []) {
        self.entries = entries
    }

    public var totalDuration: Double { entries.reduce(0) { $0 + ($1.duration ?? 0) } }
    public var selectedDuration: Double { selection.reduce(0) { $0 + (entries[$1].duration ?? 0) } }

    public mutating func append(_ urls: [URL]) {
        entries += urls.map { PlaylistEntry(url: $0) }
    }

    public mutating func remove(_ indices: IndexSet) {
        if let current, indices.contains(current) {
            self.current = nil
        } else if let current {
            self.current = current - indices.count(in: 0..<current)
        }
        entries = entries.indices.filter { !indices.contains($0) }.map { entries[$0] }
        selection = IndexSet()
    }

    public mutating func removeSelected() { remove(selection) }

    /// Keeps only the selected entries.
    public mutating func crop() { remove(IndexSet(entries.indices).subtracting(selection)) }

    public mutating func removeAll() { remove(IndexSet(entries.indices)) }

    public mutating func selectAll() { selection = IndexSet(entries.indices) }
    public mutating func selectNone() { selection = IndexSet() }
    public mutating func invertSelection() { selection = IndexSet(entries.indices).subtracting(selection) }

    public mutating func sort(by key: (PlaylistEntry) -> String) {
        reorder(entries.indices.sorted {
            key(entries[$0]).localizedStandardCompare(key(entries[$1])) == .orderedAscending
        })
    }

    public mutating func reverse() { reorder(entries.indices.reversed()) }

    public mutating func randomize() { reorder(entries.indices.shuffled()) }

    /// Moves the selected entries by `offset` rows, clamped at both ends; returns the offset actually applied.
    @discardableResult
    public mutating func moveSelection(by offset: Int) -> Int {
        guard let first = selection.first, let last = selection.last else { return 0 }
        let applied = min(max(offset, -first), entries.count - 1 - last)
        guard applied != 0 else { return 0 }
        var order = Array(repeating: -1, count: entries.count)
        for index in selection { order[index + applied] = index }
        var unselected = entries.indices.filter { !selection.contains($0) }.makeIterator()
        for slot in order.indices where order[slot] == -1 { order[slot] = unselected.next()! }
        reorder(order)
        return applied
    }

    /// Rebuilds the list so that position `k` holds the entry formerly at `order[k]`.
    public mutating func reorder(_ order: [Int]) {
        entries = order.map { entries[$0] }
        current = current.flatMap { order.firstIndex(of: $0) }
        selection = IndexSet(order.indices.filter { selection.contains(order[$0]) })
    }

    /// The track to play after `current`, or nil at the end of a non-repeating list.
    public func index(after current: Int?, shuffle: Bool, repeatAll: Bool) -> Int? {
        guard !entries.isEmpty else { return nil }
        if shuffle { return entries.indices.randomElement() }
        guard let current else { return 0 }
        if current + 1 < entries.count { return current + 1 }
        return repeatAll ? 0 : nil
    }

    public func index(before current: Int?, repeatAll: Bool) -> Int? {
        guard !entries.isEmpty else { return nil }
        guard let current, current > 0 else { return repeatAll ? entries.count - 1 : 0 }
        return current - 1
    }
}

/// Reading and writing .m3u and .pls playlists.
public enum PlaylistFile {
    public static func parse(_ text: String, extension fileExtension: String, relativeTo base: URL) -> [PlaylistEntry] {
        fileExtension.lowercased() == "pls" ? parsePLS(text, relativeTo: base) : parseM3U(text, relativeTo: base)
    }

    static func parseM3U(_ text: String, relativeTo base: URL) -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        var pending: (title: String?, duration: Double?) = (nil, nil)
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("#EXTINF:") {
                let info = line.dropFirst(8).split(separator: ",", maxSplits: 1)
                let seconds = info.first.flatMap { Double($0) }
                pending = (info.count > 1 ? String(info[1]) : nil, seconds.flatMap { $0 >= 0 ? $0 : nil })
            } else if !line.hasPrefix("#") {
                entries.append(PlaylistEntry(url: resolve(line, relativeTo: base), title: pending.title, duration: pending.duration))
                pending = (nil, nil)
            }
        }
        return entries
    }

    static func parsePLS(_ text: String, relativeTo base: URL) -> [PlaylistEntry] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return Array((1...).lazy.prefix { values["file\($0)"] != nil }.map { number in
            PlaylistEntry(url: resolve(values["file\(number)"]!, relativeTo: base),
                          title: values["title\(number)"],
                          duration: values["length\(number)"].flatMap(Double.init).flatMap { $0 >= 0 ? $0 : nil })
        })
    }

    public static func m3u(_ entries: [PlaylistEntry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            lines.append("#EXTINF:\(Int(entry.duration ?? -1)),\(entry.displayTitle)")
            lines.append(entry.url.isFileURL ? entry.url.path : entry.url.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func resolve(_ reference: String, relativeTo base: URL) -> URL {
        if let url = URL(string: reference), url.scheme != nil, url.scheme!.count > 1 { return url }
        let path = reference.replacingOccurrences(of: "\\", with: "/")
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
    }
}
