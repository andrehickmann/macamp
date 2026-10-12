import AppKit
import AuthenticationServices
import MacAmpCore

enum SpotifyError: LocalizedError {
    case notConnected
    case loginFailed
    case noDevice
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "not connected"
        case .loginFailed: "login failed"
        case .noDevice: "open Spotify on this Mac"
        case .http(let status, let message): "\(status) \(message)"
        }
    }
}

/// Spotify as a remote-controlled source via the Web API: login (PKCE), library data and playback
/// commands. Audio plays in a Spotify app; MacAmp polls its state while it controls playback.
@MainActor
final class SpotifyClient: NSObject, Transport {
    static let clientID = "c940867d6a544e8c814d558b3c491e42"
    private static let redirectURI = "macamp://callback"
    private static let scopes = [
        "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
        "playlist-read-private", "playlist-read-collaborative", "user-library-read",
    ]
    private static let refreshTokenAccount = "spotify-refresh-token"
    /// `-spotifyDebug YES` logs every request and polled state.
    private static let debug = UserDefaults.standard.bool(forKey: "spotifyDebug")

    /// True while MacAmp is controlling Spotify playback (the windows then show Spotify's state).
    private(set) var isActive = false
    private(set) var playback: SpotifyPlayback?
    var onChange: (() -> Void)?
    /// Index within the started run whose track Spotify is now playing.
    var onRunIndex: ((Int) -> Void)?
    /// Spotify finished the run (or moved on to something outside it).
    var onRunFinished: (() -> Void)?
    /// Playback could not be started on the device even after a retry.
    var onStartFailed: (() -> Void)?

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var deviceID: String?
    private var polledAt = Date()
    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var run: [String] = []
    private var runProgressed = false
    private var stopped = false
    /// The last play request, kept until the device reports a loaded track.
    private var pendingStart: (body: [String: Any], since: Date, retried: Bool)?

    var isConnected: Bool { Keychain.read(Self.refreshTokenAccount) != nil }
    /// False when Spotify plays a whole playlist on its own instead of tracks from MacAmp's playlist.
    var isFollowingRun: Bool { !run.isEmpty }

    // MARK: Transport

    var state: Player.State {
        guard isActive, let playback, !stopped else { return .stopped }
        return playback.isPlaying ? .playing : .paused
    }

    /// Spotify reports progress per poll; between polls it is extrapolated.
    var currentTime: Double {
        guard let playback, !stopped else { return 0 }
        let base = Double(playback.progressMs ?? 0) / 1000
        return playback.isPlaying ? min(duration, base + Date().timeIntervalSince(polledAt)) : base
    }

    var duration: Double { Double(playback?.item?.durationMs ?? 0) / 1000 }

    var volume: Float {
        get { Float(playback?.device?.volumePercent ?? 100) / 100 }
        set {
            playback?.device?.volumePercent = Int((newValue * 100).rounded())
            // Debounced: slider drags would otherwise flood the API.
            volumeTask?.cancel()
            volumeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await command("PUT", "/me/player/volume", query: ["volume_percent": String(Int((newValue * 100).rounded()))])
            }
        }
    }

    var channelCount: Int { 2 }

    func pause() {
        guard let playback else { return }
        if playback.isPlaying && !stopped {
            self.playback?.isPlaying = false
            Task { await command("PUT", "/me/player/pause") }
        } else {
            resume()
        }
        onChange?()
    }

    func resume() {
        stopped = false
        playback?.isPlaying = true
        polledAt = Date()
        Task { await command("PUT", "/me/player/play") }
    }

    /// Spotify has no stop: pause and rewind.
    func stop() {
        guard isActive else { return }
        stopped = true
        playback?.isPlaying = false
        playback?.progressMs = 0
        Task {
            await command("PUT", "/me/player/pause")
            await command("PUT", "/me/player/seek", query: ["position_ms": "0"])
        }
        onChange?()
    }

    func seek(to seconds: Double) {
        let position = Int(max(0, min(seconds, duration)) * 1000)
        playback?.progressMs = position
        polledAt = Date()
        Task { await command("PUT", "/me/player/seek", query: ["position_ms": String(position)]) }
    }

    // MARK: Playback

    /// Plays `uris` in order on the user's Spotify device and starts following its state.
    func play(uris: [String]) async throws {
        run = uris
        runProgressed = false
        pendingStart = nil
        try await start(["uris": uris])
    }

    /// Plays a whole Spotify playlist (e.g. one the API won't list tracks for); Spotify drives the order.
    func play(context uri: String) async throws {
        run = []
        pendingStart = nil
        try await start(["context_uri": uri])
    }

    /// Sends the play request to an explicit, activated device: Spotify answers 204 even when an
    /// implicitly targeted device ignores the command, so the result is checked while polling.
    private func start(_ body: [String: Any], transfer: Bool = false) async throws {
        stopped = false
        let device = try await targetDevice(forceTransfer: transfer)
        _ = try await request("PUT", "/me/player/play", query: ["device_id": device],
                              body: try JSONSerialization.data(withJSONObject: body))
        deviceID = device
        pendingStart = (body, Date(), pendingStart?.retried ?? false)
        activate()
    }

    /// Retries a start once if the device still has no track after three seconds.
    private func checkPendingStart(_ state: SpotifyPlayback) {
        guard let pending = pendingStart else { return }
        if state.item != nil {
            pendingStart = nil
            return
        }
        guard Date().timeIntervalSince(pending.since) > 3 else { return }
        if pending.retried {
            pendingStart = nil
            onStartFailed?()
            return
        }
        pendingStart?.retried = true
        Task { try? await start(pending.body, transfer: true) }
    }

    func skip(forward: Bool) {
        Task { await command("POST", forward ? "/me/player/next" : "/me/player/previous") }
    }

    /// Hands control back to the local player, pausing Spotify if it is playing.
    func release() {
        guard isActive else { return }
        if playback?.isPlaying == true { Task { await command("PUT", "/me/player/pause") } }
        isActive = false
        pendingStart = nil
        pollTask?.cancel()
        pollTask = nil
        run = []
        onChange?()
    }

    private func activate() {
        isActive = true
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func poll() async {
        guard let (data, response) = try? await request("GET", "/me/player") else { return }
        guard response.statusCode == 200, let state = try? JSONDecoder.spotify.decode(SpotifyPlayback.self, from: data) else { return }
        guard isActive else { return }
        if Self.debug {
            NSLog("MacAmp Spotify state: playing=\(state.isPlaying) progress=\(state.progressMs ?? -1) " +
                  "device=\(state.device?.name ?? "-") (\(state.device?.id ?? "-")) item=\(state.item?.uri ?? "-")")
        }
        if !stopped || state.isPlaying {
            stopped = false
            playback = state
            polledAt = Date()
        }
        checkPendingStart(state)
        followRun(state)
        onChange?()
    }

    /// Tracks which entry of the run is playing and notices when Spotify leaves the run.
    private func followRun(_ state: SpotifyPlayback) {
        guard !run.isEmpty, let uri = state.item?.uri else { return }
        if let index = run.firstIndex(of: uri) {
            if (state.progressMs ?? 0) > 1500 { runProgressed = true }
            onRunIndex?(index)
            let finished = runProgressed && uri == run.last && !state.isPlaying && (state.progressMs ?? 0) == 0
            if !finished { return }
        } else if !runProgressed {
            return
        }
        run = []
        onRunFinished?()
    }

    /// The device to play on (active one, else this computer), launching Spotify if none is available.
    /// Inactive devices are activated with a transfer first, which they otherwise silently ignore.
    private func targetDevice(forceTransfer: Bool) async throws -> String {
        for attempt in 0..<10 {
            let (data, _) = try await request("GET", "/me/player/devices")
            let devices = try JSONDecoder.spotify.decode(SpotifyDevices.self, from: data).devices
            let device = devices.first(where: \.isActive) ?? devices.first { $0.type == "Computer" } ?? devices.first
            if let device, let id = device.id {
                if !device.isActive || forceTransfer {
                    let body = try JSONSerialization.data(withJSONObject: ["device_ids": [id], "play": false])
                    _ = try await request("PUT", "/me/player", body: body)
                    try await Task.sleep(for: .milliseconds(700))
                }
                return id
            }
            if attempt == 0, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw SpotifyError.noDevice
    }

    // MARK: Library data

    func likedSongs() async throws -> [LibraryTrack] {
        try await pages("/me/tracks", limit: 50, maxPages: 20, as: SpotifyItemEntry.self).compactMap(\.content?.libraryTrack)
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        try await pages("/me/playlists", limit: 50, maxPages: 10, as: SpotifyPlaylist.self)
    }

    func tracks(ofPlaylist id: String) async throws -> [LibraryTrack] {
        // Since February 2026 only playlists the user owns or collaborates on list their items (others: 403).
        try await pages("/playlists/\(id)/items", limit: 100, maxPages: 20, as: SpotifyItemEntry.self)
            .compactMap(\.content?.libraryTrack)
    }

    /// The first 20 matches; development-mode apps may request at most 10 per page.
    func search(_ query: String) async throws -> [LibraryTrack] {
        var tracks: [LibraryTrack] = []
        for offset in [0, 10] {
            let (data, _) = try await request("GET", "/search", query: ["q": query, "type": "track", "limit": "10",
                                                                     "offset": String(offset)])
            let page = try JSONDecoder.spotify.decode(SpotifySearchResult.self, from: data).tracks
            tracks += page.items.compactMap(\.libraryTrack)
            if page.next == nil { break }
        }
        return tracks
    }

    // ponytail: fixed page caps (1,000 liked songs / 2,000 playlist tracks); follow `next` fully if users hit them.
    private func pages<Item: Decodable & Sendable>(_ path: String, limit: Int, maxPages: Int, as: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        for page in 0..<maxPages {
            let (data, _) = try await request("GET", path, query: ["limit": String(limit), "offset": String(page * limit)])
            let result = try JSONDecoder.spotify.decode(SpotifyPage<Item>.self, from: data)
            items += result.items
            if result.next == nil { break }
        }
        return items
    }

    // MARK: Login

    /// Opens Spotify's login in a system browser sheet and stores the refresh token in the keychain.
    func connect() async throws {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        let url = SpotifyAuth.authorizeURL(clientID: Self.clientID, redirectURI: Self.redirectURI, scopes: Self.scopes,
                                           challenge: PKCE.challenge(for: verifier), state: state)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "macamp",
                                                     completionHandler: Self.resuming(continuation))
            session.presentationContextProvider = self
            authSession = session
            session.start()
        }
        authSession = nil
        guard let code = SpotifyAuth.code(fromCallback: callback, expectedState: state) else { throw SpotifyError.loginFailed }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                         "code_verifier": verifier])
    }

    func disconnect() {
        release()
        Keychain.delete(Self.refreshTokenAccount)
        accessToken = nil
        deviceID = nil
        onChange?()
    }

    private nonisolated static func resuming(_ continuation: CheckedContinuation<URL, Error>) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? SpotifyError.loginFailed) }
        }
    }

    private func token(_ parameters: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = (parameters.merging(["client_id": Self.clientID]) { a, _ in a }).map { URLQueryItem(name: $0, value: $1) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let token = try JSONDecoder.spotify.decode(SpotifyToken.self, from: data)
        accessToken = token.accessToken
        tokenExpiry = Date().addingTimeInterval(token.expiresIn - 60)
        if let refresh = token.refreshToken { Keychain.write(refresh, account: Self.refreshTokenAccount) }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < tokenExpiry { return accessToken }
        guard let refresh = Keychain.read(Self.refreshTokenAccount) else { throw SpotifyError.notConnected }
        try await token(["grant_type": "refresh_token", "refresh_token": refresh])
        return accessToken!
    }

    // MARK: Requests

    /// Fire-and-forget player command; failures are logged.
    private func command(_ method: String, _ path: String, query: [String: String] = [:]) async {
        do {
            _ = try await request(method, path, query: deviceID.map { query.merging(["device_id": $0]) { a, _ in a } } ?? query)
        } catch {
            NSLog("MacAmp: Spotify \(method) \(path) failed: \(error.localizedDescription)")
        }
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                         retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0, value: $1) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" {
            request.httpBody = Data()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.http(0, "no response") }
        if Self.debug, path != "/me/player" || method != "GET" {
            NSLog("MacAmp Spotify \(method) \(components.url!.path)?\(components.query ?? "") → \(http.statusCode) \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        if http.statusCode == 401, !retried {
            accessToken = nil
            return try await self.request(method, path, query: query, body: body, retried: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            // Error bodies look like {"error": {"status": 403, "message": "Forbidden"}}.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (body?["error"] as? [String: Any])?["message"] as? String
            throw SpotifyError.http(http.statusCode, message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (data, http)
    }
}

extension SpotifyClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
