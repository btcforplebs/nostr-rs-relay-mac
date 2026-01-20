# Nostr Relay for Mac

A native macOS menu bar application for running your own personal Nostr relay.
Wrapped around the powerful, Rust-based [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay).

![App Icon](NostrRelayApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png)

## Features

- **Menu Bar Utility**: Runs discreetly in your menu bar. No Dock icon clutter.
- **Universal Binary**: Optimized for Apple Silicon (M1/M2/M3) and Intel Macs.
- **Smart Dashboard**:
  - **Live Event Feed**: Watch events stream in with a beautiful, social-media style visualization.
  - **Relay Control**: Easy Start/Stop toggle.
  - **Smart Connect**: Automatically connects to the relay only when it's fully ready.
- **Logs & Config**: easy access to relay logs and configuration settings.

## Getting Started

1. Download the latest release.
2. Drag `NostrRelayApp.app` to your `Applications` folder.
3. Launch the app. You will see a small "Node/Egg" icon in your menu bar.
4. Click the icon -> **Open Dashboard**.
5. Click **Start Relay**.
6. Connect your Nostr clients (Damus, Amethyst, Snort, etc.) to:
   `ws://localhost:8080`

## Development

### Prerequisites
- Xcode 15+
- Rust & Cargo (for building the underlying relay binary)

### Building
1. Clone the repo.
2. Build the Rust binary (optional, a pre-built binary is included in resources but to update it):
   ```bash
   cargo build -r
   cp target/release/nostr-rs-relay NostrRelayApp/Resources/
   ```
3. Open `NostrRelayApp/NostrRelayApp.xcodeproj` in Xcode.
4. Build and Run.

## Credits

- **Relay Core**: [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay) by [gheartsfield](https://sr.ht/~gheartsfield/).
- **Mac App Wrapper**: Built with SwiftUI.

## License

MIT
