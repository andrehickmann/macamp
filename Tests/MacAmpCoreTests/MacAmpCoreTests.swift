import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacAmpCore

@Test func glyphsAreCaseInsensitiveAndUnknownCharactersAreBlank() {
    #expect(SkinText.glyphOrigin("a") == CGPoint(x: 0, y: 0))
    #expect(SkinText.glyphOrigin("Z") == CGPoint(x: 125, y: 0))
    #expect(SkinText.glyphOrigin("7") == CGPoint(x: 35, y: 6))
    #expect(SkinText.glyphOrigin("Ä") == CGPoint(x: 10, y: 12))
    #expect(SkinText.glyphOrigin("€") == CGPoint(x: 150, y: 0))
}

@Test func timeDigitsCapMinutesAt99() {
    #expect(TimeDisplay.digits(seconds: 225.9) == [0, 3, 4, 5])
    #expect(TimeDisplay.digits(seconds: 7000) == [9, 9, 4, 0])
}

@Test func visColorsIgnoreComments() {
    let colors = Skin.parseVisColors("0,0,0, // color 0 = black\n255, 128, 0 // color 1\nnot a color")
    #expect(colors.count == 2)
    #expect(colors[1].components?.prefix(3).map { ($0 * 255).rounded() } == [255, 128, 0])
}

@Test func spectrumIsEmptyForSilenceAndPeaksAtToneFrequency() {
    let analyzer = SpectrumAnalyzer()
    let silence = [Float](repeating: 0, count: 1024)
    silence.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, count: $0.count) }
    #expect(analyzer.bars.allSatisfy { $0 == 0 })

    // 1 kHz at 44.1 kHz lands near FFT bin 23, i.e. in the middle of the bar range.
    let tone = (0..<1024).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 44100)) }
    tone.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, count: $0.count) }
    let bars = analyzer.bars
    let loudest = bars.indices.max { bars[$0] < bars[$1] }!
    #expect(bars[loudest] > 0.8)
    #expect((8...14).contains(loudest))
    #expect(bars[0] < 0.3 && bars[18] < 0.3)
}

@Test func regionsSplitPointListByCounts() {
    let regions = Skin.parseRegions("[Normal]\nNumPoints=4,3\nPointList=0,0, 275,0, 275,116, 0,116\n 10,10 20,10 15,20\n[WindowShade]\nNumPoints=4\nPointList=0,0,275,0,275,14,0,14")
    #expect(regions["normal"]?.map(\.count) == [4, 3])
    #expect(regions["normal"]?[1][2] == CGPoint(x: 15, y: 20))
    #expect(regions["windowshade"]?.first?.last == CGPoint(x: 0, y: 14))
}

@Test func playlistStyleReadsHexColorsAndFont() {
    let style = PlaylistStyle(pledit: "[Text]\nNormal=#FF8000\nFont=Tahoma")
    #expect(style.normal.components?.prefix(3).map { ($0 * 255).rounded() } == [255, 128, 0])
    #expect(style.fontName == "Tahoma")
    #expect(style.selectedBackground.components?.prefix(3).map { ($0 * 255).rounded() } == [0, 0, 255])
}

@Test func reorderingKeepsCurrentAndSelectionOnTheSameEntries() {
    let urls = ["c", "a", "d", "b"].map { URL(fileURLWithPath: "/music/\($0).mp3") }
    var playlist = Playlist(entries: urls.map { PlaylistEntry(url: $0) })
    playlist.current = 0
    playlist.selection = [3]
    playlist.sort { $0.displayTitle }
    #expect(playlist.entries.map(\.displayTitle) == ["a", "b", "c", "d"])
    #expect(playlist.current == 2)
    #expect(playlist.selection == [1])

    #expect(playlist.moveSelection(by: 5) == 2)
    #expect(playlist.entries.map(\.displayTitle) == ["a", "c", "d", "b"])
    #expect(playlist.current == 1)

    playlist.selection = [0]
    playlist.removeSelected()
    #expect(playlist.entries.map(\.displayTitle) == ["c", "d", "b"])
    #expect(playlist.current == 0)
    #expect(playlist.index(after: 2, shuffle: false, repeatAll: false) == nil)
    #expect(playlist.index(after: 2, shuffle: false, repeatAll: true) == 0)
}

@Test func m3uRoundTripsAndPlsResolvesRelativePaths() {
    let base = URL(fileURLWithPath: "/music")
    let entries = [PlaylistEntry(url: URL(fileURLWithPath: "/music/a b.mp3"), title: "Artist - Song", duration: 225)]
    #expect(PlaylistFile.parse(PlaylistFile.m3u(entries), extension: "m3u", relativeTo: base) == entries)

    let pls = PlaylistFile.parse("[playlist]\nFile1=sub/x.ogg\nTitle1=X\nLength1=-1\nNumberOfEntries=1", extension: "pls", relativeTo: base)
    #expect(pls == [PlaylistEntry(url: URL(fileURLWithPath: "/music/sub/x.ogg"), title: "X", duration: nil)])
}

@Test func equalizerCurvePassesThroughBands() {
    var eq = EqualizerSettings()
    eq.bands = [12, 0, 0, 0, 0, 0, 0, 0, 0, -12]
    let curve = eq.curve(width: 10)
    #expect(curve.first == 12 && curve.last == -12)
    #expect(curve[4] == 0)
}

@Test func windowsSnapToNeighboursAndDockAsGroup() {
    let main = CGRect(x: 100, y: 500, width: 275, height: 116)
    let snapped = WindowSnapping.snap(CGRect(x: 104, y: 390, width: 275, height: 116), to: [main], screen: nil)
    #expect(snapped.origin == CGPoint(x: 100, y: 384))

    let equalizer = CGRect(x: 100, y: 384, width: 275, height: 116)
    let playlist = CGRect(x: 100, y: 152, width: 275, height: 232)
    let loose = CGRect(x: 600, y: 152, width: 275, height: 116)
    #expect(WindowSnapping.docked(to: 0, in: [main, equalizer, playlist, loose]) == [0, 1, 2])
}

@Test func icyDemuxerStripsMetadataAcrossChunkBoundaries() {
    let title = Array("StreamTitle='Artist - Song';".utf8)
    let padded = title + Array(repeating: 0, count: 32 - title.count)
    let stream: [UInt8] = [1, 2, 3, 4] + [2] + padded + [5, 6, 7, 8] + [0] + [9, 10]
    var demuxer = IcyDemuxer(metaInterval: 4)
    var audio: [UInt8] = []
    var titles: [String] = []
    for chunk in stride(from: 0, to: stream.count, by: 7).map({ stream[$0..<min($0 + 7, stream.count)] }) {
        let result = demuxer.consume(chunk)
        audio += result.audio
        titles += result.titles
    }
    #expect(audio == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    #expect(titles == ["Artist - Song"])
}

@Test func genFontFindsLetterRunsBetweenSeparatorColumns() throws {
    let context = try #require(CGContext(data: nil, width: 40, height: 100, bitsPerComponent: 8, bytesPerRow: 160,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0, green: 0.78, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 100))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.3, alpha: 1))
    // CoreGraphics' y axis points up: the font row at image y 88...94 is context y 5...11.
    context.fill(CGRect(x: 1, y: 5, width: 4, height: 7))
    context.fill(CGRect(x: 6, y: 5, width: 3, height: 7))
    // The title bar may use any color; only the font row's own separator counts.
    context.fill(CGRect(x: 20, y: 90, width: 10, height: 10))
    let font = Skin.parseGenFont(try #require(context.makeImage()))
    #expect(font["A"] == CGRect(x: 1, y: 88, width: 4, height: 7))
    #expect(font["B"] == CGRect(x: 6, y: 88, width: 3, height: 7))
    #expect(font["C"] == nil)
}

@Test func libraryViewsFilterAndMergeKeepsStatistics() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    var a = LibraryTrack(url: URL(fileURLWithPath: "/music/a.mp3"), dateAdded: now.addingTimeInterval(-90 * 86400))
    a.title = "Señorita"
    a.artist = "Café Band"
    var b = LibraryTrack(url: URL(fileURLWithPath: "/music/b.mp3"), dateAdded: now)
    b.title = "Other"
    var library = Library()
    library.tracks = [a, b]
    library.recordPlay(of: a.url, at: now)
    library.tracks[0].rating = 5

    #expect(library.tracks(in: .audio, matching: "senorita cafe").map(\.url) == [a.url])
    #expect(library.tracks(in: .mostPlayed).map(\.url) == [a.url])
    #expect(library.tracks(in: .neverPlayed).map(\.url) == [b.url])
    #expect(library.tracks(in: .recentlyAdded, now: now).map(\.url) == [b.url])
    #expect(library.tracks(in: .topRated).map(\.url) == [a.url])

    var rescanned = LibraryTrack(url: a.url, dateAdded: now)
    rescanned.title = "Señorita (Remastered)"
    library.merge([rescanned], present: [a.url], scannedFolders: [URL(fileURLWithPath: "/music")])
    #expect(library.tracks.map(\.url) == [a.url])
    #expect(library.tracks[0].title == "Señorita (Remastered)")
    #expect(library.tracks[0].playCount == 1 && library.tracks[0].rating == 5)
    #expect(library.tracks[0].dateAdded == a.dateAdded)
}

@Test func pkceMatchesRFC7636AndCallbackChecksState() throws {
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(PKCE.makeVerifier().count == 64)

    let url = SpotifyAuth.authorizeURL(clientID: "id", redirectURI: "macamp://callback", scopes: ["a", "b"],
                                       challenge: "c", state: "s")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.first { $0.name == "scope" }?.value == "a b")
    #expect(items.first { $0.name == "redirect_uri" }?.value == "macamp://callback")

    let callback = try #require(URL(string: "macamp://callback?code=xyz&state=s"))
    #expect(SpotifyAuth.code(fromCallback: callback, expectedState: "s") == "xyz")
    #expect(SpotifyAuth.code(fromCallback: callback, expectedState: "other") == nil)
}

@Test func spotifyPlaybackDecodesIntoLibraryTrack() throws {
    let json = """
    {"is_playing": true, "progress_ms": 61000, "shuffle_state": false, "repeat_state": "off",
     "device": {"id": "d1", "name": "MacBook", "type": "Computer", "is_active": true, "volume_percent": 80},
     "item": {"uri": "spotify:track:abc", "name": "Song", "duration_ms": 225000, "track_number": 3,
              "artists": [{"name": "A"}, {"name": "B"}], "album": {"name": "Album", "release_date": "1999-05-01"}}}
    """
    let playback = try JSONDecoder.spotify.decode(SpotifyPlayback.self, from: Data(json.utf8))
    let track = try #require(playback.item?.libraryTrack)
    #expect(track.url.absoluteString == "spotify:track:abc")
    #expect(track.displayTitle == "A, B - Song")
    #expect(track.year == 1999 && track.trackNumber == 3 && track.duration == 225)
    #expect(playback.device?.volumePercent == 80)

    let page = try JSONDecoder.spotify.decode(SpotifyPage<SpotifyItemEntry>.self, from: Data("""
    {"items": [{"track": {"uri": "spotify:track:x", "name": "X", "duration_ms": 1000}}, {"track": {"type": "episode"}}], "next": null}
    """.utf8))
    #expect(page.items.compactMap(\.content).map(\.name) == ["X"])
}

@Test func availableSkinsAreSortedAndLaterDirectoriesOverride() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = root.appendingPathComponent("bundled"), user = root.appendingPathComponent("user")
    for path in ["bundled/Base.wsz", "bundled/zed.zip", "user/Base.wsz", "user/readme.txt"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent(path).path, contents: Data())
    }
    try FileManager.default.createDirectory(at: user.appendingPathComponent("Folder Skin"), withIntermediateDirectories: true)

    let skins = Skin.available(in: [bundled, user, root.appendingPathComponent("missing")])
    #expect(skins.map(\.name) == ["Base", "Folder Skin", "zed"])
    #expect(skins[0].url.deletingLastPathComponent().lastPathComponent == "user")
}

@Test func wszSheetsStayDrawableAfterTheUnpackedFilesAreGone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("skin"), archive = root.appendingPathComponent("skin.wsz")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pixel.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("main.png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, pixel.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    zip.arguments = ["-c", "-k", folder.path, archive.path]
    try zip.run()
    zip.waitUntilExit()

    let skin = try Skin(contentsOf: archive)
    let target = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    target.draw(try #require(skin.sheets["main"]), in: CGRect(x: 0, y: 0, width: 1, height: 1))
    #expect(target.data!.load(as: UInt8.self) == 255)
}

@Test func sonosTopologyHidesStereoPartnersAndPutsCoordinatorFirst() {
    // Shape of a real GetZoneGroupState response: the topology is escaped XML inside the SOAP body.
    let topology = """
    <ZoneGroupState><ZoneGroups>
    <ZoneGroup Coordinator="RINCON_B01400" ID="RINCON_B01400:12">
      <ZoneGroupMember UUID="RINCON_A01400" Location="http://10.0.0.11:1400/xml/device_description.xml" ZoneName="Kitchen"/>
      <ZoneGroupMember UUID="RINCON_B01400" Location="http://10.0.0.12:1400/xml/device_description.xml" ZoneName="Living Room"/>
      <ZoneGroupMember UUID="RINCON_C01400" Location="http://10.0.0.13:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_D01400" ID="RINCON_D01400:3">
      <ZoneGroupMember UUID="RINCON_D01400" Location="http://10.0.0.14:1400/xml/device_description.xml" ZoneName="Garden">
        <Satellite UUID="RINCON_E01400" Location="http://10.0.0.15:1400/xml/device_description.xml" ZoneName="Garden" Invisible="1"/>
      </ZoneGroupMember>
    </ZoneGroup>
    </ZoneGroups></ZoneGroupState>
    """
    let response = "<s:Envelope><s:Body><u:GetZoneGroupStateResponse><ZoneGroupState>\(Sonos.escape(topology))</ZoneGroupState>"
        + "</u:GetZoneGroupStateResponse></s:Body></s:Envelope>"
    let groups = Sonos.groups(fromZoneGroupState: response)
    #expect(groups.map(\.name) == ["Garden", "Living Room + Kitchen"])
    #expect(groups[1].coordinator == SonosRoom(id: "RINCON_B01400", name: "Living Room", host: "10.0.0.12"))
    #expect(groups[1].id == "RINCON_B01400")
}

@Test func sonosPlaybackReadsTrackAndRadioMetadata() {
    func positionInfo(_ uri: String, _ metadata: String) -> String {
        "<r><Track>2</Track><TrackDuration>0:04:05</TrackDuration><TrackMetaData>\(Sonos.escape(metadata))</TrackMetaData>"
            + "<TrackURI>\(Sonos.escape(uri))</TrackURI><RelTime>0:01:02</RelTime></r>"
    }
    let didl = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1"><dc:title>Song &amp; Dance</dc:title><dc:creator>The Band</dc:creator><upnp:album>Album</upnp:album></item></DIDL-Lite>"#
    let track = Sonos.playback(transportInfo: "<r><CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState></r>",
                               positionInfo: positionInfo("x-sonos-spotify:spotify%3atrack%3aabc?sid=12&flags=8224&sn=3", didl))
    #expect(track.state == .paused)
    #expect(track.displayTitle == "The Band - Song & Dance")
    #expect(track.trackNumber == 2 && track.position == 62 && track.duration == 245)

    let radio = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/"><item><dc:title>stream.mp3</dc:title><r:streamContent>Artist - Live</r:streamContent></item></DIDL-Lite>"#
    let stream = Sonos.playback(transportInfo: "<r><CurrentTransportState>PLAYING</CurrentTransportState></r>",
                                positionInfo: positionInfo("x-rincon-mp3radio://https://example.com/stream.mp3", radio))
    #expect(stream.state == .playing && stream.displayTitle == "Artist - Live")
}

@Test func sonosItemsEncodeSpotifyAndRadioURIs() {
    let services = #"<Service Id="254" Name="TuneIn"/><Service Id="9" Name="Spotify" Uri="https://example.com/smapi"/>"#
    let response = "<r><AvailableServiceDescriptorList>\(Sonos.escape("<Services>\(services)</Services>"))</AvailableServiceDescriptorList></r>"
    #expect(Sonos.spotifyService(inAvailableServices: response) == 9)

    let spotify = Sonos.spotifyItem("spotify:track:4uLU6hMCjMI75M1A2tKUQC", title: "A & B", service: 9, account: 2)
    #expect(spotify.uri == "x-sonos-spotify:spotify%3atrack%3a4uLU6hMCjMI75M1A2tKUQC?sid=9&flags=8224&sn=2")
    #expect(spotify.metadata.contains(#"id="00032020spotify%3atrack%3a4uLU6hMCjMI75M1A2tKUQC""#))
    #expect(spotify.metadata.contains("SA_RINCON2311_X_#Svc2311-0-Token") && spotify.metadata.contains("A &amp; B"))
    #expect(Sonos.radioItem(URL(string: "https://example.com/live.mp3")!, title: nil).uri == "x-rincon-mp3radio://https://example.com/live.mp3")
    #expect(Sonos.time(3725) == "1:02:05" && Sonos.seconds("NOT_IMPLEMENTED") == 0)

    let body = Sonos.envelope(service: "AVTransport", action: "SetAVTransportURI",
                              arguments: [("InstanceID", "0"), ("CurrentURI", spotify.uri)])
    #expect(Sonos.value("CurrentURI", in: body) == spotify.uri)
}

@Test func artistWikiRejectsUnsafeIDsAndPrefersTheFirstLanguage() throws {
    #expect(ArtistWiki.articlesQuery(spotifyArtistID: "x\". ?a ?b ?c", languages: ["en"]) == nil)
    #expect(ArtistWiki.articlesQuery(spotifyArtistID: "0OdUWJ0sBjDrqHygGUXeCF", languages: ["de", "en"]) != nil)
    let result = Data("""
        {"results": {"bindings": [
          {"article": {"value": "https://en.wikipedia.org/wiki/Die_%C3%84rzte"}, "lang": {"value": "en"}},
          {"article": {"value": "https://de.wikipedia.org/wiki/Die_%C3%84rzte"}, "lang": {"value": "de"}}
        ]}}
        """.utf8)
    #expect(ArtistWiki.summaryURL(fromQueryResult: result, languages: ["de", "en"])?.absoluteString
        == "https://de.wikipedia.org/api/rest_v1/page/summary/Die_%C3%84rzte")
    #expect(ArtistWiki.summaryURL(fromQueryResult: result, languages: ["fr", "en"])?.host == "en.wikipedia.org")
    #expect(ArtistWiki.summaryURL(fromQueryResult: result, languages: ["fr"]) == nil)
}

@Test func albumTracksBecomeLibraryRowsWithAlbumAndYear() throws {
    let json = Data("""
        {"name": "OK Computer", "id": "a1", "uri": "spotify:album:a1", "release_date": "1997-05-21", "album_type": "album",
         "tracks": {"items": [{"uri": "spotify:track:t1", "name": "Airbag", "duration_ms": 284000, "track_number": 1,
                               "artists": [{"name": "Radiohead", "id": "r1"}]}], "next": null, "total": 1}}
        """.utf8)
    let tracks = try JSONDecoder.spotify.decode(SpotifyAlbum.self, from: json).libraryTracks
    #expect(tracks.count == 1)
    #expect(tracks.first?.album == "OK Computer")
    #expect(tracks.first?.year == 1997)
    #expect(tracks.first?.url.absoluteString == "spotify:track:t1")
}

@Test func artistRadioStartsWithTheArtistAndLimitsSongsPerArtist() {
    func songs(_ artist: String) -> [ArtistRadio.Recording] {
        (1...15).map { ArtistRadio.Recording(recordingMbid: "\(artist)\($0)", recordingName: "Song \($0)", artistName: artist) }
    }
    var generator = SystemRandomNumberGenerator()
    let mix = ArtistRadio.mix(seed: songs("A"), similar: [songs("B"), songs("C"), []], using: &generator)
    #expect(mix.count == 10)
    #expect(mix.first?.artistName == "A")
    #expect(mix.filter { $0.artistName == "B" }.count == 3)
    // Only each artist's ten most popular songs are picked.
    #expect(mix.allSatisfy { Int($0.recordingName.dropFirst(5))! <= 10 })
}

@Test func sonosFileItemsAndByteRanges() {
    let item = Sonos.fileItem(URL(string: "http://10.0.0.5:8080/abc/Song.flac")!, title: "Song", fileExtension: "flac")
    #expect(item.uri == "http://10.0.0.5:8080/abc/Song.flac")
    #expect(item.metadata.contains(#"protocolInfo="http-get:*:audio/flac:*""#) && !item.metadata.contains("<desc"))

    #expect(Sonos.byteRange("bytes=0-99", size: 1000) == 0...99)
    #expect(Sonos.byteRange("bytes=900-", size: 1000) == 900...999)
    #expect(Sonos.byteRange("bytes=-100", size: 1000) == 900...999)
    #expect(Sonos.byteRange("bytes=500-5000", size: 1000) == 500...999)
    #expect(Sonos.byteRange("bytes=1000-", size: 1000) == nil)
    #expect(Sonos.byteRange(nil, size: 1000) == nil)
}

@Test func waveformKeepsTheLatestSamplesAsCenteredBytes() {
    let analyzer = SpectrumAnalyzer()
    let samples: [Float] = [-1, 0, 1, 0.5]
    samples.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, count: $0.count) }
    let waveform = analyzer.waveform
    #expect(waveform.count == 1024)
    #expect(Array(waveform.suffix(4)) == [1, 128, 255, 191])
    #expect(waveform.first == 128)
}
