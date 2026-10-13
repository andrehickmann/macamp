import Foundation
import MacAmpCore
import Network

enum SonosError: LocalizedError {
    case noSpeakers
    case noOutput
    case noSpotifyAccount
    case spotifyNotLinked
    case spotifyNotPlaying
    case spotifyAccountNotFound
    case upnp(String, String)

    var errorDescription: String? {
        switch self {
        case .noSpeakers: "no Sonos speakers found"
        case .noOutput: "no Sonos room chosen"
        case .noSpotifyAccount: "click Connect Sonos in the Rooms window"
        case .spotifyNotLinked: "Spotify is not set up in the Sonos app"
        case .spotifyNotPlaying: "first play a song in Spotify on your phone or Mac, then click Connect Sonos again"
        case .spotifyAccountNotFound: "your Spotify account is not set up in the Sonos app"
        case .upnp(let action, let code): "\(action) failed (\(code))"
        }
    }
}

/// Sonos rooms via their local control API (UPnP/SOAP on port 1400): topology, playback, volume and grouping.
/// The group containing `outputRoom` is a `Transport`: audio plays on the speakers, MacAmp only controls it.
/// State is polled while the Rooms window is open or a room is the output.
@MainActor
final class SonosClient: Transport {
    typealias Item = (uri: String, metadata: String)

    private(set) var groups: [SonosGroup] = []
    private(set) var playbacks: [String: SonosPlayback] = [:]
    /// Volume 0–100 per room ID; group volumes under the group (coordinator) ID with a "group:" prefix.
    private(set) var volumes: [String: Int] = [:]
    /// Last failed request or discovery, shown in the Rooms window until the next poll succeeds.
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    /// Index within the started run whose track the output group is now playing.
    var onRunIndex: ((Int) -> Void)?
    /// The group played the run's last entry to its end.
    var onRunFinished: (() -> Void)?

    /// Room MacAmp plays on (its whole group); nil plays on this Mac.
    var outputRoom: String? = UserDefaults.standard.string(forKey: "sonosOutputRoom") {
        didSet {
            UserDefaults.standard.set(outputRoom, forKey: "sonosOutputRoom")
            run = []
            updatePolling()
        }
    }
    /// True while the Rooms window is visible.
    var isWatched = false {
        didSet { updatePolling() }
    }

    private var pollTask: Task<Void, Never>?
    private let mediaServer = MediaServer()
    private var isConnectingSpotify = false
    /// Appends the rest of a run to the queue; cancelled when something else starts.
    private var enqueueTask: Task<Void, Never>?
    private var polledAt = Date()
    private var volumeTasks: [String: Task<Void, Never>] = [:]
    /// Spotify URIs handed to the output group's queue, in order.
    /// Playlist URLs handed to the output group's queue, in order, with the text that identifies each in the
    /// URI Sonos reports (the Spotify URI, or the token of a served file).
    private var run: [(url: URL, key: String)] = [] {
        didSet {
            runStarted = false
            endingLastEntry = false
        }
    }
    /// The previous poll saw the run's last entry within its final seconds.
    private var endingLastEntry = false
    /// The group reported a run entry once; until then the previous item may still show.
    private var runStarted = false
    /// Account number (`sn`) Sonos plays Spotify with; found by `connectSpotify`.
    private var spotifyAccount: Int? {
        get { UserDefaults.standard.object(forKey: "sonosSpotifyAccount") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "sonosSpotifyAccount") }
    }
    /// Spotify's music-service ID in this household.
    private var spotifyService: Int? {
        get { UserDefaults.standard.object(forKey: "sonosSpotifyService") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "sonosSpotifyService") }
    }
    /// Speakers Connect Sonos muted, with their previous mute state; kept across launches so a test cut short
    /// (e.g. by quitting) is undone on the next poll instead of leaving rooms silent.
    private var mutedForTest: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "sonosMutedForTest") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : newValue, forKey: "sonosMutedForTest") }
    }
    /// Widely available track used to test Spotify playback.
    private static let probeTrack = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"

    var isSpotifyConnected: Bool { spotifyAccount != nil && spotifyService != nil }

    var isActive: Bool { outputRoom != nil }
    var outputGroup: SonosGroup? { outputRoom.flatMap(group(containing:)) }
    var playback: SonosPlayback? { outputGroup.flatMap { playbacks[$0.id] } }
    var isFollowingRun: Bool { !run.isEmpty }
    var isPlayingRunItem: Bool { runIndex(of: playback) != nil }

    func group(containing room: String) -> SonosGroup? {
        groups.first { $0.members.contains { $0.id == room } }
    }

    // MARK: Transport

    var state: Player.State { Self.state(of: playback) }

    static func state(of playback: SonosPlayback?) -> Player.State {
        switch playback?.state {
        case .playing: .playing
        case .paused: .paused
        default: .stopped
        }
    }

    /// Sonos reports the position per poll; between polls it is extrapolated.
    var currentTime: Double {
        guard let playback else { return 0 }
        let elapsed = playback.state == .playing ? Date().timeIntervalSince(polledAt) : 0
        return playback.duration > 0 ? min(playback.duration, playback.position + elapsed) : playback.position + elapsed
    }

    var duration: Double { playback?.duration ?? 0 }

    var volume: Float {
        get { Float(outputGroup.flatMap { volumes["group:" + $0.id] } ?? 0) / 100 }
        set { if let outputGroup { setVolume(of: outputGroup, to: Int((newValue * 100).rounded())) } }
    }

    var channelCount: Int { 2 }

    func pause() {
        if let outputGroup { togglePlay(outputGroup) }
    }

    func resume() {
        guard let outputGroup else { return }
        setState(.playing, of: outputGroup)
        send(outputGroup.coordinator.host, .avTransport, "Play", [("Speed", "1")])
    }

    func stop() {
        guard let outputGroup else { return }
        setState(.stopped, of: outputGroup)
        send(outputGroup.coordinator.host, .avTransport, "Stop")
    }

    func seek(to seconds: Double) {
        guard let outputGroup else { return }
        playbacks[outputGroup.id]?.position = max(0, min(seconds, duration))
        polledAt = Date()
        send(outputGroup.coordinator.host, .avTransport, "Seek", [("Unit", "REL_TIME"), ("Target", Sonos.time(seconds))])
    }

    func skip(forward: Bool) {
        guard let outputGroup else { return }
        send(outputGroup.coordinator.host, .avTransport, forward ? "Next" : "Previous")
    }

    // MARK: Playback on the output group

    /// Replaces the output group's queue with these entries (Spotify tracks and local files, which MacAmp serves
    /// over HTTP) and plays the first; the rest is enqueued in the background while it already plays.
    func play(_ entries: [(url: URL, title: String?)]) async throws {
        let group = try await resolvedOutput()
        let host = group.coordinator.host
        var items: [Item] = []
        var keys: [String] = []
        for entry in entries {
            if entry.url.isFileURL {
                let served = try await mediaServer.url(for: entry.url, reachableFrom: host)
                items.append(Sonos.fileItem(served, title: entry.title, fileExtension: entry.url.pathExtension))
                keys.append(served.pathComponents.dropFirst().first ?? served.absoluteString)
            } else {
                guard let account = spotifyAccount, let service = spotifyService else { throw SonosError.noSpotifyAccount }
                items.append(Sonos.spotifyItem(entry.url.absoluteString, title: entry.title, service: service, account: account))
                keys.append(entry.url.absoluteString)
            }
        }
        guard !items.isEmpty else { return }
        enqueueTask?.cancel()
        run = zip(entries.map(\.url), keys).map { ($0, $1) }
        try await call(host, .avTransport, "RemoveAllTracksFromQueue")
        try await enqueue(items[0], on: host)
        try await call(host, .avTransport, "SetAVTransportURI",
                       [("CurrentURI", Sonos.queueURI(of: group.coordinator.id)), ("CurrentURIMetaData", "")])
        try await call(host, .avTransport, "Play", [("Speed", "1")])
        setState(.playing, of: group)
        enqueueTask = Task {
            do {
                for item in items.dropFirst() where !Task.isCancelled { try await enqueue(item, on: host) }
            } catch {
                report(error)
            }
        }
    }

    /// Jumps to an entry of the current run without rebuilding the queue.
    func playRunItem(at offset: Int) {
        guard let outputGroup else { return }
        let host = outputGroup.coordinator.host
        Task {
            do {
                try await call(host, .avTransport, "Seek", [("Unit", "TRACK_NR"), ("Target", String(offset + 1))])
                try await call(host, .avTransport, "Play", [("Speed", "1")])
            } catch {
                report(error)
            }
            await poll(topology: false)
        }
    }

    func runOffset(of url: URL) -> Int? { run.firstIndex { $0.url == url } }

    func play(radio stream: URL, title: String?) async throws {
        let group = try await resolvedOutput()
        let item = Sonos.radioItem(stream, title: title)
        enqueueTask?.cancel()
        run = []
        try await call(group.coordinator.host, .avTransport, "SetAVTransportURI",
                       [("CurrentURI", item.uri), ("CurrentURIMetaData", item.metadata)])
        try await call(group.coordinator.host, .avTransport, "Play", [("Speed", "1")])
        setState(.playing, of: group)
    }

    /// Finds Spotify's service ID and the account number (`sn`) of the user's own Spotify account among those
    /// linked in Sonos (a family plan links several). The Web API doesn't report playback Sonos starts this way,
    /// but Spotify allows one stream per account: while the user's account plays elsewhere, a muted test track
    /// is played on the group with each account number until `isOwnAccountPlaying` turns false. Playback on
    /// the group stops; its mute state is restored.
    func connectSpotify(on group: SonosGroup, isOwnAccountPlaying: @escaping () async -> Bool, progress: (Int) -> Void) async throws {
        guard await isOwnAccountPlaying() else { throw SonosError.spotifyNotPlaying }
        isConnectingSpotify = true
        defer { isConnectingSpotify = false }
        let host = group.coordinator.host
        guard let service = Sonos.spotifyService(inAvailableServices: try await call(host, .musicServices, "ListAvailableServices"))
        else { throw SonosError.spotifyNotLinked }
        for room in group.members {
            let muted = Sonos.value("CurrentMute", in: try await call(room.host, .renderingControl, "GetMute", [("Channel", "Master")])) == "1"
            mutedForTest[room.host] = mutedForTest[room.host] ?? muted
            try await call(room.host, .renderingControl, "SetMute", [("Channel", "Master"), ("DesiredMute", "1")])
        }
        enqueueTask?.cancel()
        run = []
        var found: Int?
        var failure: Error?
        do {
            for account in 1...20 {
                progress(account)
                let item = Sonos.spotifyItem(Self.probeTrack, title: nil, service: service, account: account)
                try await call(host, .avTransport, "SetAVTransportURI", [("CurrentURI", item.uri), ("CurrentURIMetaData", item.metadata)])
                try await call(host, .avTransport, "Play", [("Speed", "1")])
                // The first number Sonos can't play is past the last linked account.
                guard try await waitUntilPlaying(host) else { break }
                let tookOver = await stopsWithin(seconds: 8, isOwnAccountPlaying)
                NSLog("MacAmp Sonos: account \(account) plays the test track; own Spotify playback \(tookOver ? "stopped" : "continues")")
                if tookOver {
                    found = account
                    break
                }
            }
        } catch {
            failure = error
        }
        _ = try? await call(host, .avTransport, "Stop")
        await restoreMutedForTest()
        if let failure { throw failure }
        guard let found else { throw SonosError.spotifyAccountNotFound }
        spotifyService = service
        spotifyAccount = found
        onChange?()
    }

    /// Spotify's player state lags a few seconds behind.
    private func stopsWithin(seconds: Int, _ isPlaying: () async -> Bool) async -> Bool {
        for _ in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            if await !isPlaying() { return true }
        }
        return false
    }

    private func restoreMutedForTest() async {
        for (host, muted) in mutedForTest {
            if (try? await call(host, .renderingControl, "SetMute", [("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")])) != nil {
                mutedForTest[host] = nil
            }
        }
    }

    private func waitUntilPlaying(_ host: String) async throws -> Bool {
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(500))
            if Sonos.value("CurrentTransportState", in: try await call(host, .avTransport, "GetTransportInfo")) == "PLAYING" { return true }
        }
        return false
    }

    /// The output group, loading the rooms first when playback starts before the first poll.
    private func resolvedOutput() async throws -> SonosGroup {
        if outputGroup == nil, isActive { try await refreshTopology() }
        guard let group = outputGroup else { throw SonosError.noOutput }
        return group
    }

    private func enqueue(_ item: Item, on host: String) async throws {
        try await call(host, .avTransport, "AddURIToQueue", [("EnqueuedURI", item.uri), ("EnqueuedURIMetaData", item.metadata),
                                                            ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0")])
    }

    private func runIndex(of playback: SonosPlayback?) -> Int? {
        guard let uri = playback?.uri?.removingPercentEncoding else { return nil }
        return run.firstIndex { uri.contains($0.key) }
    }

    // MARK: Room controls

    func togglePlay(_ group: SonosGroup) {
        let playing = playbacks[group.id]?.state == .playing
        setState(playing ? .paused : .playing, of: group)
        send(group.coordinator.host, .avTransport, playing ? "Pause" : "Play", playing ? [] : [("Speed", "1")])
    }

    /// Group volume keeps the rooms' ratios; debounced because slider drags fire continuously.
    func setVolume(of group: SonosGroup, to percent: Int) {
        let key = "group:" + group.id
        volumes[key] = percent
        debounce(key) { [self] in
            try await call(group.coordinator.host, .groupRenderingControl, "SnapshotGroupVolume")
            try await call(group.coordinator.host, .groupRenderingControl, "SetGroupVolume", [("DesiredVolume", String(percent))])
        }
    }

    func setVolume(of room: SonosRoom, to percent: Int) {
        volumes[room.id] = percent
        debounce(room.id) { [self] in
            try await call(room.host, .renderingControl, "SetVolume", [("Channel", "Master"), ("DesiredVolume", String(percent))])
        }
    }

    /// Adds a room to the group or takes it out (taking out the coordinator hands the group to another room).
    func set(_ room: SonosRoom, in group: SonosGroup, included: Bool) {
        if included {
            send(room.host, .avTransport, "SetAVTransportURI",
                 [("CurrentURI", Sonos.groupURI(coordinator: group.coordinator.id)), ("CurrentURIMetaData", "")], topology: true)
        } else {
            send(room.host, .avTransport, "BecomeCoordinatorOfStandaloneGroup", topology: true)
        }
    }

    func ungroupAll() {
        for group in groups {
            for room in group.members.dropFirst() { send(room.host, .avTransport, "BecomeCoordinatorOfStandaloneGroup", topology: true) }
        }
    }

    // MARK: Polling

    private func updatePolling() {
        guard isWatched || outputRoom != nil else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await poll(topology: tick % 5 == 0)
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll(topology: Bool) async {
        if !mutedForTest.isEmpty, !isConnectingSpotify { await restoreMutedForTest() }
        do {
            if topology || groups.isEmpty { try await refreshTopology() }
            var playbacks: [String: SonosPlayback] = [:]
            var volumes: [String: Int] = [:]
            for group in groups {
                let host = group.coordinator.host
                let transport = try await call(host, .avTransport, "GetTransportInfo")
                let position = try await call(host, .avTransport, "GetPositionInfo")
                playbacks[group.id] = Sonos.playback(transportInfo: transport, positionInfo: position)
                volumes["group:" + group.id] = Int(Sonos.value("CurrentVolume",
                    in: try await call(host, .groupRenderingControl, "GetGroupVolume")) ?? "")
                for room in group.members where group.members.count > 1 {
                    volumes[room.id] = Int(Sonos.value("CurrentVolume",
                        in: try await call(room.host, .renderingControl, "GetVolume", [("Channel", "Master")])) ?? "")
                }
            }
            self.playbacks = playbacks
            // Values the user is still dragging stay as set until the request went out.
            self.volumes = volumes.merging(self.volumes.filter { volumeTasks[$0.key] != nil }) { _, local in local }
            polledAt = Date()
            lastError = nil
            followRun()
        } catch {
            report(error)
        }
        onChange?()
    }

    private func refreshTopology() async throws {
        // Any room answers for the whole household; ask the known ones first (also from the last launch),
        // then search the network.
        let known = groups.flatMap { $0.members.map(\.host) } + (UserDefaults.standard.stringArray(forKey: "sonosHosts") ?? [])
        for hosts in [known, await Self.discover()] {
            for host in hosts {
                guard let response = try? await call(host, .zoneGroupTopology, "GetZoneGroupState") else { continue }
                groups = Sonos.groups(fromZoneGroupState: response)
                UserDefaults.standard.set(groups.flatMap { $0.members.map(\.host) }, forKey: "sonosHosts")
                return
            }
        }
        groups = []
        throw SonosError.noSpeakers
    }

    /// Reports which run entry plays and when the last one ended; forgets the run once the group plays
    /// something else. Sonos stops after its queue, so the end shows as a stop right after the last entry's
    /// final seconds (polls are 2 s apart).
    private func followRun() {
        guard !run.isEmpty, let playback else { return }
        if playback.state == .stopped, endingLastEntry {
            run = []
            onRunFinished?()
            return
        }
        guard playback.uri != nil else { return }
        if let index = runIndex(of: playback) {
            runStarted = true
            endingLastEntry = index == run.count - 1 && playback.state == .playing
                && playback.duration > 0 && playback.position >= playback.duration - 5
            onRunIndex?(index)
        } else if runStarted {
            run = []
        }
    }

    // MARK: Requests

    enum Service {
        case avTransport, renderingControl, groupRenderingControl, zoneGroupTopology, musicServices

        var name: String {
            switch self {
            case .avTransport: "AVTransport"
            case .renderingControl: "RenderingControl"
            case .groupRenderingControl: "GroupRenderingControl"
            case .zoneGroupTopology: "ZoneGroupTopology"
            case .musicServices: "MusicServices"
            }
        }

        /// Household-wide services sit at the root and take no InstanceID.
        var isHousehold: Bool { self == .zoneGroupTopology || self == .musicServices }
        var path: String { isHousehold ? "/\(name)/Control" : "/MediaRenderer/\(name)/Control" }
    }

    @discardableResult
    private func call(_ host: String, _ service: Service, _ action: String, _ arguments: [(String, String)] = []) async throws -> String {
        var request = URLRequest(url: URL(string: "http://\(host):1400\(service.path)")!, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service.name):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let instance = service.isHousehold ? [] : [("InstanceID", "0")]
        request.httpBody = Data(Sonos.envelope(service: service.name, action: action, arguments: instance + arguments).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SonosError.upnp(action, Sonos.value("errorCode", in: text) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return text
    }

    /// Fires a command and polls right after, so the windows show its effect.
    private func send(_ host: String, _ service: Service, _ action: String, _ arguments: [(String, String)] = [], topology: Bool = false) {
        Task {
            do {
                try await call(host, service, action, arguments)
            } catch {
                report(error)
            }
            await poll(topology: topology)
        }
        onChange?()
    }

    private func debounce(_ key: String, _ request: @escaping @MainActor () async throws -> Void) {
        volumeTasks[key]?.cancel()
        volumeTasks[key] = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try await request() } catch { report(error) }
            volumeTasks[key] = nil
        }
        onChange?()
    }

    private func setState(_ state: SonosPlayback.State, of group: SonosGroup) {
        playbacks[group.id]?.state = state
        polledAt = Date()
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("MacAmp Sonos: \(error.localizedDescription)")
        onChange?()
    }

    /// Hosts of the Sonos players announcing themselves via Bonjour; their TXT record carries the device URL.
    private static func discover() async -> [String] {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
            let finish = Once { hosts in
                browser.cancel()
                continuation.resume(returning: hosts)
            }
            browser.browseResultsChangedHandler = { results, _ in
                let hosts = results.compactMap { result -> String? in
                    guard case .bonjour(let record) = result.metadata else { return nil }
                    return record["location"].flatMap(URL.init(string:))?.host
                }
                if !hosts.isEmpty { MainActor.assumeIsolated { finish.run(hosts) } }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { finish.run([]) } }
        }
    }

    @MainActor
    private final class Once {
        private var action: (([String]) -> Void)?
        init(_ action: @escaping ([String]) -> Void) { self.action = action }

        func run(_ hosts: [String]) {
            action?(hosts)
            action = nil
        }
    }
}
