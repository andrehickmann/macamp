import AppKit
import WebKit

/// Spotify's Web Playback SDK in a hidden web view: a Spotify Connect device named "MacAmp" that plays in this
/// app, so playback on this Mac needs no Spotify app. Audio is DRM-protected (FairPlay) and bypasses MacAmp's
/// audio engine. Requires Premium and the `streaming` scope.
@MainActor
final class WebPlayer: NSObject, WKScriptMessageHandler {
    static let deviceName = "MacAmp"

    private var web: WKWebView?
    private var window: NSWindow?
    private var token: (() async throws -> String)?
    private var deviceID: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []
    /// Why the player can't be used (missing scope, no Premium, unsupported browser); then Spotify's app plays.
    private(set) var problem: String?

    /// The device ID once the SDK has registered with Spotify; starts the player on first use.
    /// Nil when it doesn't come up within `timeout` or reported a problem.
    func device(token: @escaping () async throws -> String, timeout: Duration = .seconds(10)) async -> String? {
        if problem != nil { return nil }
        if let deviceID { return deviceID }
        self.token = token
        if web == nil { load() }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task {
                try? await Task.sleep(for: timeout)
                finishWaiting(with: deviceID)
            }
        }
    }

    /// Drops the player, e.g. after a new login, so the next use starts it with the new token.
    func reset() {
        window?.orderOut(nil)
        web = nil
        window = nil
        deviceID = nil
        problem = nil
        finishWaiting(with: nil)
    }

    private func finishWaiting(with id: String?) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: id) }
    }

    private func load() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "player")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
        // The SDK only starts in browsers it recognizes; the bare WKWebView user agent lacks "Safari".
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        // WebKit stalls media-key requests in a view outside any window, so it gets an off-screen one.
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        self.web = web
        self.window = window
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String], let event = body["event"] else { return }
        switch event {
        case "token":
            Task {
                guard let token = try? await token?() else { return }
                let literal = (try? JSONEncoder().encode(token)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                _ = try? await web?.evaluateJavaScript("window.provideToken(\(literal))")
            }
        case "ready":
            deviceID = body["device"]
            finishWaiting(with: deviceID)
        case "not_ready":
            deviceID = nil
        case "initialization_error", "authentication_error", "account_error":
            problem = body["message"]
            deviceID = nil
            finishWaiting(with: nil)
            NSLog("MacAmp web player: \(event) \(body["message"] ?? "") – falling back to the Spotify app")
        default:
            NSLog("MacAmp web player: \(event) \(body["message"] ?? "")")
        }
    }

    private static let page = """
    <html><body><script>
    const post = (event, extra = {}) => window.webkit.messageHandlers.player.postMessage({event, ...extra});
    let tokenCallback = null;
    window.provideToken = token => { if (tokenCallback) tokenCallback(token); tokenCallback = null; };
    // Diagnostics: which DRM the SDK asks for, media element errors and its console output.
    const requestAccess = navigator.requestMediaKeySystemAccess.bind(navigator);
    navigator.requestMediaKeySystemAccess = (system, config) => requestAccess(system, config).then(
      access => { post('log', {message: 'DRM ' + system + ' granted'}); return access; },
      error => { post('log', {message: 'DRM ' + system + ' refused: ' + error.name + ' ' + error.message}); throw error; });
    document.addEventListener('error', e => {
      const error = e.target && e.target.error;
      if (error) post('log', {message: 'media error ' + error.code + ' ' + (error.message || '')});
    }, true);
    for (const name of ['play', 'playing', 'pause', 'suspend', 'stalled', 'waiting', 'ended', 'emptied'])
      document.addEventListener(name, e => post('log', {message: 'media ' + name + ' (page ' + document.visibilityState + ')'}), true);
    document.addEventListener('visibilitychange', () => post('log', {message: 'page ' + document.visibilityState}));
    for (const level of ['error', 'warn'])
      console[level] = (...args) => post('log', {message: 'console.' + level + ' ' + args.map(String).join(' ').slice(0, 300)});
    window.onSpotifyWebPlaybackSDKReady = () => {
      const player = new Spotify.Player({
        name: '\(deviceName)',
        getOAuthToken: callback => { tokenCallback = callback; post('token'); },
        volume: 1,
      });
      player.addListener('ready', ({device_id}) => post('ready', {device: device_id}));
      player.addListener('not_ready', ({device_id}) => post('not_ready', {device: device_id}));
      player.addListener('player_state_changed', state => post('log', {message: state
        ? 'state paused=' + state.paused + ' loading=' + state.loading + ' position=' + state.position + ' page ' + document.visibilityState
        : 'state none'}));
      for (const name of ['initialization_error', 'authentication_error', 'account_error', 'playback_error', 'autoplay_failed'])
        player.addListener(name, e => post(name, {message: String(e && e.message || '')}));
      player.connect();
    };
    </script><script src="https://sdk.scdn.co/spotify-player.js"></script></body></html>
    """
}
