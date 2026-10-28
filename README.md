# Harbor

A native macOS menu bar app for searching torrents and managing downloads through Transmission.

## Features

- Search APIBay, TorrentsCSV, Internet Archive, Knaben and Nyaa from one interface.
- Manage downloads, queues, files, bandwidth limits and seeding rules.
- Override speed limits and seed ratios for individual torrents.
- Search from a native macOS menu, view individual transfer progress and speeds, and pause or resume downloads. Display options use a standard checked submenu.
- Choose an icon-only menu bar item, activity arrows, or total upload/download speeds. Progress is blue while downloading, green while seeding, and gray when paused or completed.
- Keep downloads running when the window closes; stop the engine when quitting Harbor.

## Build and setup

Requires macOS 14 or later, Swift 6, and Transmission 4.1 or later. The build script currently targets Apple Silicon.

```sh
brew install transmission-cli
bash scripts/build.sh
```

The app is built at `dist/Harbor.app`. It is ad-hoc signed, not notarized.

**First-run setup is still manual.** Harbor currently needs a configured local Transmission session and saved connection credentials before it can manage its daemon. See [setup](docs/setup.md). A fresh-install setup assistant is not implemented yet.

Do not start Transmission with `brew services`: Harbor manages its own engine. Avoid running another Transmission instance alongside it.

## Using Harbor

Search, select a result, then choose **Add to Downloads…**. You can choose a folder and start immediately or add the transfer paused.

**Downloads** shows transfer progress, speeds and files. Its inspector and context menu offer per-torrent speed limits and seeding settings. Removing a transfer keeps downloaded files.

Open **Download Settings…** with **⌘,** to change bandwidth, queue, seeding, network and folder preferences. Per-torrent overrides take precedence where enabled. Changing default folders does not move existing downloads.

Closing the window leaves Harbor in the menu bar. **Quit Harbor & Stop Transfers** stops the managed daemon before exiting.

## Local data

Connection credentials are stored in macOS Keychain. The daemon's settings and transfer state are stored under `~/Library/Application Support/Harbor/`; logs are under `~/Library/Logs/Harbor/`. The control API is restricted to this Mac.

Searches are sent to the enabled indexes. Source availability and reported seed counts depend on those services. Search results are not a guarantee of download availability or file safety.

## Development

```sh
swift test --build-system native --disable-sandbox
swift run HarborCheck ubuntu
```

- `Sources/HarborApp`: SwiftUI interface and engine lifecycle.
- `Sources/HarborCore`: search adapters, result handling and Transmission RPC client.
- `Tests/HarborCoreTests`: parser and RPC tests.

The build uses SwiftPM's native backend to work around local signing issues. That backend is deprecated and may need replacing in a future Swift release.

## License

[MIT](LICENSE). Copyright © 2026 Koen Prange.

Harbor is powered by [Transmission](https://transmissionbt.com/), the open-source BitTorrent engine developed by the Transmission contributors. Transmission is installed separately and retains its [own license](https://github.com/transmission/transmission/blob/4.1.4/COPYING).
