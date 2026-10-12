import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) for the Spotify login without a client secret.
public enum PKCE {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func makeVerifier(length: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// base64url(SHA-256(verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum SpotifyAuth {
    public static func authorizeURL(clientID: String, redirectURI: String, scopes: [String],
                                    challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code from the redirect, or nil if the state doesn't match or login was denied.
    public static func code(fromCallback url: URL, expectedState: String) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { return nil }
        return value("code")
    }
}

// MARK: Web API models (decoded with .convertFromSnakeCase)

public struct SpotifyToken: Decodable, Sendable {
    public var accessToken: String
    public var expiresIn: Double
    public var refreshToken: String?
}

public struct SpotifyArtist: Decodable, Sendable {
    public var name: String
}

public struct SpotifyAlbum: Decodable, Sendable {
    public var name: String
    public var uri: String?
    public var releaseDate: String?
}

public struct SpotifyTrack: Decodable, Sendable {
    public var uri: String
    public var name: String
    public var durationMs: Int
    public var trackNumber: Int?
    public var artists: [SpotifyArtist]?
    public var album: SpotifyAlbum?

    /// The track as a library row; its URL is the `spotify:track:…` URI.
    public var libraryTrack: LibraryTrack? {
        guard let url = URL(string: uri) else { return nil }
        var track = LibraryTrack(url: url)
        track.title = name
        track.artist = artists?.map(\.name).joined(separator: ", ")
        track.album = album?.name
        track.year = album?.releaseDate.flatMap { Int($0.prefix(4)) }
        track.trackNumber = trackNumber
        track.duration = Double(durationMs) / 1000
        return track
    }
}

public struct SpotifyDevice: Decodable, Sendable {
    public var id: String?
    public var name: String
    public var type: String
    public var isActive: Bool
    public var volumePercent: Int?
}

public struct SpotifyPlayback: Decodable, Sendable {
    public var isPlaying: Bool
    public var progressMs: Int?
    public var item: SpotifyTrack?
    public var device: SpotifyDevice?
    public var shuffleState: Bool?
    public var repeatState: String?
}

public struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Item]
    public var next: String?
    public var total: Int?
}

/// Entry of a saved-tracks or playlist-items page; newer responses name the field `item`.
public struct SpotifyItemEntry: Decodable, Sendable {
    public var track: SpotifyTrack?
    public var item: SpotifyTrack?

    public var content: SpotifyTrack? { track ?? item }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Episodes and unavailable tracks decode as nil instead of failing the whole page.
        track = try? container.decodeIfPresent(SpotifyTrack.self, forKey: .track)
        item = try? container.decodeIfPresent(SpotifyTrack.self, forKey: .item)
    }

    private enum CodingKeys: String, CodingKey { case track, item }
}

public struct SpotifyPlaylist: Decodable, Sendable {
    public var id: String
    public var name: String
    public var uri: String
}

public struct SpotifyDevices: Decodable, Sendable {
    public var devices: [SpotifyDevice]
}

public struct SpotifySearchResult: Decodable, Sendable {
    public var tracks: SpotifyPage<SpotifyTrack>
}

public extension JSONDecoder {
    static var spotify: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
