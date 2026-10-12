import CoreGraphics
import Foundation
import ImageIO

public enum SkinError: Error {
    case unzipFailed(URL)
    case missingMain
}

/// A classic (Winamp 2.x compatible) skin: its bitmap sheets plus visualizer colors.
public struct Skin {
    /// Bitmap sheets keyed by lowercased base name, e.g. "main" for MAIN.BMP.
    public let sheets: [String: CGImage]
    /// The 24 colors from viscolor.txt.
    public let visColors: [CGColor]
    /// Window shapes from region.txt, keyed by lowercased section ("normal", "windowshade", "equalizer", "equalizerws").
    public let regions: [String: [[CGPoint]]]
    public let playlistStyle: PlaylistStyle

    /// Loads a skin from an unpacked directory or a `.wsz`/`.zip` archive.
    public init(contentsOf url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let root = isDirectory ? url : try Self.unzip(url)
        defer { if !isDirectory { try? FileManager.default.removeItem(at: root) } }

        // Skins differ in file name case and sometimes nest files in a subfolder.
        var files: [String: URL] = [:]
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() {
            files[file.lastPathComponent.lowercased()] = file
        }

        var sheets: [String: CGImage] = [:]
        for (name, file) in files where name.hasSuffix(".bmp") || name.hasSuffix(".png") {
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                sheets[String(name.dropLast(4))] = image
            }
        }
        guard sheets["main"] != nil else { throw SkinError.missingMain }
        self.sheets = sheets

        let parsed = files["viscolor.txt"]
            .flatMap { try? String(contentsOf: $0, encoding: .isoLatin1) }
            .map(Self.parseVisColors) ?? []
        visColors = parsed.count >= 24 ? Array(parsed.prefix(24)) : Self.defaultVisColors

        func text(_ name: String) -> String? { files[name].flatMap { try? String(contentsOf: $0, encoding: .isoLatin1) } }
        regions = text("region.txt").map(Self.parseRegions) ?? [:]
        playlistStyle = text("pledit.txt").map(PlaylistStyle.init(pledit:)) ?? PlaylistStyle(pledit: "")
    }

    /// Parses `[Section]` blocks with `NumPoints=4,4` and `PointList=x,y x,y ...` into polygons.
    /// Point lists may continue on following lines.
    static func parseRegions(_ text: String) -> [String: [[CGPoint]]] {
        var counts: [String: [Int]] = [:]
        var points: [String: [Int]] = [:]
        var section = ""
        var key = ""
        func numbers(_ value: Substring) -> [Int] {
            value.split { !$0.isNumber && $0 != "-" }.compactMap { Int($0) }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                section = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
                key = ""
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "numpoints" { counts[section] = numbers(pair[1]) }
                if key == "pointlist" { points[section] = numbers(pair[1]) }
            } else if key == "pointlist" {
                points[section, default: []] += numbers(line)
            }
        }
        return counts.reduce(into: [:]) { regions, item in
            var values = (points[item.key] ?? [])[...]
            regions[item.key] = item.value.compactMap { count in
                guard values.count >= count * 2 else { return nil }
                return (0..<count).map { _ in CGPoint(x: values.removeFirst(), y: values.removeFirst()) }
            }
        }
    }

    /// Cuts a sprite out of a sheet; `rect` uses top-left origin in sheet pixels.
    public func sprite(_ sheet: String, _ rect: CGRect) -> CGImage? {
        sheets[sheet]?.cropping(to: rect)
    }

    /// Parses lines like `24,33,41, // comment` into colors.
    static func parseVisColors(_ text: String) -> [CGColor] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let values = line.split(separator: "/").first?
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
            guard values.count >= 3 else { return nil }
            return CGColor(srgbRed: CGFloat(values[0]) / 255, green: CGFloat(values[1]) / 255,
                           blue: CGFloat(values[2]) / 255, alpha: 1)
        }
    }

    private static func unzip(_ archive: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("macamp-skin-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, target.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw SkinError.unzipFailed(archive) }
        return target
    }

    static let defaultVisColors: [CGColor] = [
        (0, 0, 0), (24, 33, 41), (239, 49, 16), (206, 41, 16), (214, 90, 0), (214, 102, 0),
        (214, 115, 0), (198, 123, 8), (222, 165, 24), (214, 181, 33), (189, 222, 41), (148, 222, 33),
        (41, 206, 16), (50, 190, 16), (57, 181, 16), (49, 156, 8), (41, 148, 0), (24, 132, 8),
        (255, 255, 255), (214, 214, 222), (181, 189, 189), (160, 170, 175), (148, 156, 165), (150, 150, 150),
    ].map { CGColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }
}

/// Playlist colors and font from pledit.txt.
public struct PlaylistStyle {
    public let normal: CGColor
    public let current: CGColor
    public let normalBackground: CGColor
    public let selectedBackground: CGColor
    public let fontName: String

    public init(pledit text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        func color(_ key: String, _ fallback: UInt32) -> CGColor {
            let hex = values[key].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.flatMap { UInt32($0.prefix(6), radix: 16) }
            let rgb = hex ?? fallback
            return CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        normal = color("normal", 0x00FF00)
        current = color("current", 0xFFFFFF)
        normalBackground = color("normalbg", 0x000000)
        selectedBackground = color("selectedbg", 0x0000FF)
        fontName = values["font"] ?? "Arial"
    }
}

/// Glyph lookup for the 5×6 pixel bitmap font in text.bmp.
public enum SkinText {
    public static let glyphSize = CGSize(width: 5, height: 6)

    private static let rows: [[Character]] = [
        Array("abcdefghijklmnopqrstuvwxyz\"@"),
        Array("0123456789….:()-'!_+\\/[]^&%,=$#"),
        Array("åöä?*"),
    ]
    private static let substitutions: [Character: Character] = [
        "ü": "u", "ß": "s", "<": "[", ">": "]", "{": "[", "}": "]", ";": ":", "`": "'", "~": "-",
    ]

    /// Top-left of the glyph for `character`; unknown characters map to a blank cell.
    public static func glyphOrigin(_ character: Character) -> CGPoint {
        let lower = Character(character.lowercased())
        let mapped = substitutions[lower] ?? lower
        for (row, glyphs) in rows.enumerated() {
            if let column = glyphs.firstIndex(of: mapped) {
                return CGPoint(x: CGFloat(column) * glyphSize.width, y: CGFloat(row) * glyphSize.height)
            }
        }
        return CGPoint(x: 150, y: 0)
    }
}

public enum TimeDisplay {
    /// The four digits (mm:ss) shown in the main window; minutes are capped at 99.
    public static func digits(seconds: Double) -> [Int] {
        let total = max(0, Int(seconds))
        let minutes = min(total / 60, 99)
        let rest = total % 60
        return [minutes / 10, minutes % 10, rest / 10, rest % 10]
    }

    /// "3:45" or "1:02:03" for playlist and shade displays.
    public static func string(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
