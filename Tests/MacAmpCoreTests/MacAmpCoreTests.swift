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
