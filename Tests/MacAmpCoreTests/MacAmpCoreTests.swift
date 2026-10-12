import CoreGraphics
import Foundation
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
