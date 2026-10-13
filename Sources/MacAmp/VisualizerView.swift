import AppKit
import WebKit

/// MilkDrop presets (Butterchurn, WebGL) in a gen.bmp frame, fed with the waveform of whatever MacAmp plays.
/// Click the picture for the next preset; presets also change on their own every 25 s.
@MainActor
final class VisualizerView: GenWindowView, WKScriptMessageHandler {
    private let web: WKWebView
    private var isLoaded = false

    /// Bundled page and scripts: Contents/Resources/Visualizer in the app, Resources/Visualizer under `swift run`.
    private static let folder: URL? = [
        Bundle.main.resourceURL?.appendingPathComponent("Visualizer"),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Visualizer").standardized,
    ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }

    override init(app: AppController) {
        let configuration = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(app: app)
        configuration.userContentController.add(self, name: "log")
        web.frame = contentRect
        addSubview(web)
        if let folder = Self.folder {
            web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
            isLoaded = true
        } else {
            NSLog("MacAmp: visualizer files not found")
        }
    }

    override var title: String { "MILKDROP" }
    override var logicalSize: CGSize { app.visualizerSize }
    override func resize(to size: CGSize) { app.setVisualizerSize(size) }
    override func close() { app.toggleVisualizer() }

    override func layout() {
        super.layout()
        web.frame = contentRect
    }

    /// Script errors of the page, for the log.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        NSLog("MacAmp visualizer: \(message.body)")
    }

    /// Hands the latest 1024 waveform bytes to the page; called by the app's 30 fps timer while visible.
    func feed(_ waveform: [UInt8]) {
        guard isLoaded, window?.isVisible == true, !web.isLoading else { return }
        web.evaluateJavaScript("feed([\(waveform.map(String.init).joined(separator: ","))])", completionHandler: nil)
    }
}
