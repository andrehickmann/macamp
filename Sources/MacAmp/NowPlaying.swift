import MediaPlayer

/// Media keys, Control Center and the menu bar "Now Playing" widget.
@MainActor
final class NowPlaying {
    enum Command: Sendable {
        case play, pause, toggle, stop, next, previous, seek(Double)
    }

    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
        Self.registerCommands { [weak app] command in
            Task { @MainActor in app?.handle(command) }
        }
    }

    func update() {
        let player = app.player
        let center = MPNowPlayingInfoCenter.default()
        guard player.file != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let parts = app.currentTitle.components(separatedBy: " - ")
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : app.currentTitle,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
        ]
        if parts.count > 1 { info[MPMediaItemPropertyArtist] = parts[0] }
        center.nowPlayingInfo = info
        center.playbackState = switch player.state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    /// Built outside the main actor: MediaPlayer may invoke handlers off the main thread.
    private nonisolated static func registerCommands(_ handler: @escaping @Sendable (Command) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        let simple: [(MPRemoteCommand, Command)] = [
            (center.playCommand, .play), (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .toggle),
            (center.stopCommand, .stop), (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous),
        ]
        for (remote, command) in simple {
            remote.addTarget { _ in
                handler(command)
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handler(.seek(event.positionTime))
            return .success
        }
    }
}
