# MacAmp

A native macOS player that recreates the classic Winamp 2.x interface and loads classic skins (`.wsz`).

<img src="docs/screenshot.png" alt="MacAmp main window, equalizer and playlist editor" width="275">

Plays MP3, AAC/M4A, ALAC, FLAC, Ogg Vorbis, Opus, WAV and AIFF through Core Audio, plus
Shoutcast/Icecast radio streams (MP3/AAC).

<img src="docs/library.png" alt="MacAmp media library" width="550">

## Run

```bash
swift run MacAmp          # development
scripts/bundle.sh         # builds .build/MacAmp.app (ad-hoc signed)
```

On first launch MacAmp asks for a skin (a `.wsz` file or an unpacked skin folder) and remembers it.
Audio files, folders and `.m3u`/`.pls` playlists can be passed as arguments, dropped onto a window,
or opened with `L` / the eject button. Dropping onto the playlist appends instead of replacing.

Development options (passed as user defaults):

- `-skinPath <path>` – use this skin for one run
- `-snapshot <out.png>` – render all windows to `out-main.png`, `out-equalizer.png`, `out-playlist.png` and quit
- `-snapshotDelay <seconds>` – wait longer before the snapshot (default 1.5)
- `-mainShade YES`, `-equalizerShade YES`, `-playlistShade YES` – start in shade mode
- `-libraryFolder <path>` – add a folder to the media library and scan it

## Features

- Main window, equalizer and playlist editor with shade modes, double size and `region.txt` shapes
- Windows snap to each other and to screen edges; dragging the main window moves docked windows
- 10-band equalizer with preamp, presets and per-file "Auto" curves
- Playlist: multi-select, drag to reorder, sort/reverse/randomize, remove missing, `.m3u` save/load, resize
- Internet radio: stream titles from ICY metadata, `.pls`/`.m3u` station links, equalizer and analyzer included
- Media library (`gen.bmp` frame): watched folders, tag scan, search, smart views (most/recently played,
  recently added, never played, top rated), ratings, play counts, saved playlists, drag to playlist
- Spectrum analyzer, media keys and Control Center "Now Playing"
- Settings, playlist and window positions persist across launches

## Keys

`Z` previous · `X` play · `C` pause · `V` stop · `B` next · `L` open · `R` repeat · `S` shuffle ·
`←/→` seek 5 s · `↑/↓` volume · `⌥G` equalizer · `⌥E` playlist · `⌥L` media library · `⌘L` open URL ·
`⌃W` shade · `⌃D` double size

In the playlist: `⌫` remove, `↩` play, `↑/↓` select, `⌘A` select all.
