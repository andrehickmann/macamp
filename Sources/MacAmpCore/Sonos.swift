import Foundation

/// A Sonos room as shown in the Sonos app; stereo pairs and home-theater satellites count as one room.
public struct SonosRoom: Equatable, Hashable, Sendable {
    /// Player UUID, e.g. "RINCON_000E5812345601400".
    public var id: String
    public var name: String
    /// IP address or host name; the control API listens on port 1400.
    public var host: String

    public init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}

/// Rooms playing in sync; commands for the group go to the coordinator.
public struct SonosGroup: Equatable, Sendable {
    public var coordinator: SonosRoom
    /// Coordinator first, then the other rooms in topology order.
    public var members: [SonosRoom]

    public var id: String { coordinator.id }
    public var name: String { members.map(\.name).joined(separator: " + ") }
}

public struct SonosPlayback: Equatable, Sendable {
    public enum State: Sendable { case playing, paused, stopped }

    public var state: State
    public var title: String?
    public var artist: String?
    public var album: String?
    /// URI of the current queue item or stream as Sonos reports it.
    public var uri: String?
    /// 1-based position in the queue (0 for streams).
    public var trackNumber: Int
    public var position: Double
    public var duration: Double

    /// "Artist - Title" like playlist entries, or the stream's own title.
    public var displayTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        if let artist, !artist.isEmpty { return "\(artist) - \(title)" }
        return title
    }
}

/// The local Sonos control API (UPnP/SOAP on port 1400): request bodies, response parsing and item URIs.
public enum Sonos {
    // MARK: SOAP

    public static func envelope(service: String, action: String, arguments: [(String, String)]) -> String {
        let body = arguments.map { "<\($0)>\(escape($1))</\($0)>" }.joined()
        return #"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
            + #"<u:\#(action) xmlns:u="urn:schemas-upnp-org:service:\#(service):1">\#(body)</u:\#(action)></s:Body></s:Envelope>"#
    }

    /// Text of the first element named `name` (entities decoded).
    public static func value(_ name: String, in xml: String) -> String? {
        XMLElements.parse(xml).first { $0.name == name }?.text
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Responses

    /// Groups from a `GetZoneGroupState` response. Invisible members (the second speaker of a stereo pair,
    /// subwoofers, surrounds) are left out, as are groups without a visible member.
    public static func groups(fromZoneGroupState response: String) -> [SonosGroup] {
        guard let state = value("ZoneGroupState", in: response) else { return [] }
        var groups: [(coordinator: String, members: [SonosRoom])] = []
        for element in XMLElements.parse(state) {
            switch element.name {
            case "ZoneGroup":
                groups.append((element.attributes["Coordinator"] ?? "", []))
            case "ZoneGroupMember" where element.attributes["Invisible"] != "1" && !groups.isEmpty:
                guard let id = element.attributes["UUID"], let name = element.attributes["ZoneName"],
                      let host = element.attributes["Location"].flatMap(URL.init(string:))?.host else { continue }
                groups[groups.count - 1].members.append(SonosRoom(id: id, name: name, host: host))
            default:
                break
            }
        }
        return groups.compactMap { group in
            guard let coordinator = group.members.first(where: { $0.id == group.coordinator }) else { return nil }
            return SonosGroup(coordinator: coordinator, members: [coordinator] + group.members.filter { $0 != coordinator })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Combines `GetTransportInfo` and `GetPositionInfo` responses.
    public static func playback(transportInfo: String, positionInfo: String) -> SonosPlayback {
        let state: SonosPlayback.State = switch value("CurrentTransportState", in: transportInfo) {
        case "PLAYING", "TRANSITIONING": .playing
        case "PAUSED_PLAYBACK": .paused
        default: .stopped
        }
        let metadata = XMLElements.parse(value("TrackMetaData", in: positionInfo) ?? "")
        func field(_ name: String) -> String? { metadata.first { $0.name == name }?.text.nilIfEmpty }
        // Radio streams put the current song into r:streamContent and the station into dc:title.
        let stream = field("r:streamContent")
        return SonosPlayback(
            state: state,
            title: stream ?? field("dc:title"),
            artist: stream == nil ? field("dc:creator") : nil,
            album: field("upnp:album"),
            uri: value("TrackURI", in: positionInfo)?.nilIfEmpty,
            trackNumber: Int(value("Track", in: positionInfo) ?? "") ?? 0,
            position: seconds(value("RelTime", in: positionInfo) ?? ""),
            duration: seconds(value("TrackDuration", in: positionInfo) ?? ""))
    }

    /// "0:03:25" → 205; "NOT_IMPLEMENTED" and empty strings → 0.
    public static func seconds(_ time: String) -> Double {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    public static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// Spotify's music-service ID from a `ListAvailableServices` response; it differs by region (9, 12).
    public static func spotifyService(inAvailableServices response: String) -> Int? {
        let services = XMLElements.parse(value("AvailableServiceDescriptorList", in: response) ?? "")
        return services.first { $0.name == "Service" && $0.attributes["Name"] == "Spotify" }?.attributes["Id"].flatMap { Int($0) }
    }

    // MARK: Items

    /// Queue URI and DIDL metadata for a `spotify:track:…` URI; Sonos streams it with the linked account
    /// numbered `account` (`sn`) of music service `service`.
    public static func spotifyItem(_ spotifyURI: String, title: String?, service: Int, account: Int) -> (uri: String, metadata: String) {
        let encoded = spotifyURI.replacingOccurrences(of: ":", with: "%3a")
        let uri = "x-sonos-spotify:\(encoded)?sid=\(service)&flags=8224&sn=\(account)"
        let metadata = didl(id: "00032020\(encoded)", title: title ?? "",
                            upnpClass: "object.item.audioItem.musicTrack",
                            descriptor: "SA_RINCON\(service * 256 + 7)_X_#Svc\(service * 256 + 7)-0-Token")
        return (uri, metadata)
    }

    /// Plays an MP3/AAC internet radio stream; Sonos keeps the original scheme after the prefix.
    public static func radioItem(_ stream: URL, title: String?) -> (uri: String, metadata: String) {
        ("x-rincon-mp3radio://\(stream.absoluteString)",
         didl(id: "R:0/0/0", title: title ?? stream.host ?? "Radio", upnpClass: "object.item.audioItem.audioBroadcast",
              descriptor: "SA_RINCON65031_"))
    }

    /// A local file MacAmp serves over HTTP (`url`), queued like any track.
    public static func fileItem(_ url: URL, title: String?, fileExtension: String) -> (uri: String, metadata: String) {
        (url.absoluteString,
         didl(id: "-1", title: title ?? url.deletingPathExtension().lastPathComponent, upnpClass: "object.item.audioItem.musicTrack",
              resource: (url.absoluteString, "http-get:*:\(mimeType(forExtension: fileExtension)):*")))
    }

    /// MIME types for the formats Sonos plays from a URL.
    public static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "aac", "mp4", "alac": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "ogg", "oga": "audio/ogg"
        default: "application/octet-stream"
        }
    }

    /// The byte range a `Range: bytes=…` header asks for in a file of `size` bytes; nil for the whole file
    /// or a range it can't satisfy. Supports `a-b`, `a-` and the suffix form `-n`.
    public static func byteRange(_ header: String?, size: Int) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes="), size > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: ",")[0].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int(parts[0].trimmingCharacters(in: .whitespaces)), end = Int(parts[1].trimmingCharacters(in: .whitespaces))
        switch (start, end) {
        case let (start?, end?) where start <= end && start < size: return start...min(end, size - 1)
        case let (start?, nil) where start < size: return start...(size - 1)
        case let (nil, suffix?) where suffix > 0: return max(0, size - suffix)...(size - 1)
        default: return nil
        }
    }

    /// Joining a group means following its coordinator's transport.
    public static func groupURI(coordinator: String) -> String { "x-rincon:\(coordinator)" }

    public static func queueURI(of room: String) -> String { "x-rincon-queue:\(room)#0" }

    private static func didl(id: String, title: String, upnpClass: String, descriptor: String? = nil,
                             resource: (url: String, protocolInfo: String)? = nil) -> String {
        let res = resource.map { #"<res protocolInfo="\#($0.protocolInfo)">\#(escape($0.url))</res>"# } ?? ""
        let desc = descriptor.map { #"<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\#($0)</desc>"# } ?? ""
        return #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">"#
            + #"<item id="\#(id)" parentID="" restricted="true"><dc:title>\#(escape(title))</dc:title><upnp:class>\#(upnpClass)</upnp:class>"#
            + res + desc + "</item></DIDL-Lite>"
    }
}

/// All elements of an XML document in order, with attributes and their own text; namespace prefixes stay in the name.
struct XMLElements {
    struct Element {
        var name: String
        var attributes: [String: String]
        var text = ""
    }

    static func parse(_ xml: String) -> [Element] {
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.parse()
        return collector.elements
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        private var open: [Int] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            open.append(elements.count)
            elements.append(Element(name: name, attributes: attributes))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let index = open.last { elements[index].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = open.popLast()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
