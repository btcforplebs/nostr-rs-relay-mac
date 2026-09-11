# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

This repo bundles two things:
- `src/` (root Cargo crate `nostr-rs-relay`): a fork/vendored copy of the Rust [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay) Nostr relay server.
- `NostrRelayApp/`: a native SwiftUI macOS menu-bar app (`NostrRelayApp.xcodeproj`) that wraps the relay binary, giving it a menu-bar UI, dashboard, start/stop control, config editing, and log viewing. It embeds a pre-built relay binary in `NostrRelayApp/Resources/`.

## Common commands

### Rust relay
```bash
cargo build -r                                  # release build
cp target/release/nostr-rs-relay NostrRelayApp/Resources/   # sync binary into the Mac app bundle
cargo test --release                            # full test suite
cargo test <test_name>                          # single test
cargo clippy                                    # lint (used by pre-commit)
cargo fmt                                       # formatting (rustfmt.toml sets config)
```
The relay reads `config.toml` at the repo root for its settings (DB path, ports, rate limits, pay-to-relay, NIP-05 verification, etc.).

### macOS app
Open `NostrRelayApp/NostrRelayApp.xcodeproj` in Xcode (15+) and build/run from there. The app relies on the relay binary already being present in `NostrRelayApp/Resources/` (rebuild the Rust binary and copy it in first when relay code changes).

### Pre-commit
`.pre-commit-config.yaml` runs `cargo check` and `clippy` (plus generic whitespace/yaml/large-file hooks) on commit.

## Architecture

### Relay (`src/`)
- `main.rs` / `cli.rs` — process entry point and CLI arg parsing.
- `config.rs` — loads and validates `config.toml`.
- `server.rs` — sets up the hyper HTTP server and WebSocket upgrade handling; ties together connections, subscriptions, and the repo layer.
- `conn.rs` — per-client WebSocket connection state.
- `event.rs` / `close.rs` / `subscription.rs` / `notice.rs` — Nostr protocol message types (EVENT/REQ/CLOSE/NOTICE) and (de)serialization.
- `nauthz.rs` — pluggable event authorization (gRPC-based; see `proto/` and `docs/grpc-extensions.md`).
- `delegation.rs` — NIP-26 delegated event signing support.
- `nip05.rs` — NIP-05 identity verification (`docs/user-verification-nip05.md`).
- `dedup.rs` — duplicate event detection.
- `payment/` — pay-to-relay support: `lnbits.rs` and `cln_rest.rs` are alternate Lightning backend implementations behind a common interface in `mod.rs` (see `docs/pay-to-relay.md`).
- `repo/` — storage abstraction with two backends: `sqlite.rs` (+ `sqlite_migration.rs`) and `postgres.rs` (+ `postgres_migration.rs`), selected via config.
- `bin/bulkloader.rs` — standalone binary for bulk-importing events into the DB.
- `db.rs` — shared DB connection pooling helpers used by the repo layer.
- `proto/` — gRPC/protobuf definitions used by `nauthz.rs` and metrics; compiled via `build.rs` (tonic-build).

Integration tests live in `tests/` (`integration_test.rs`, `conn.rs`, `cli.rs`) with shared fixtures in `tests/common`.

### macOS app (`NostrRelayApp/NostrRelayApp/`)
- `NostrRelayApp.swift` — app entry point, menu-bar item setup.
- `RelayService.swift` — manages the relay subprocess lifecycle (start/stop/status) and reads `Resources/nostr-rs-relay`.
- `ConfigurationService.swift` — reads/writes the relay's `config.toml`.
- `WebSocketClient.swift` — connects to the running relay to stream live events for the dashboard.
- `DashboardView.swift` / `DashboardComponents.swift` / `EventViewer.swift` — main dashboard UI and live event feed visualization.
- `SettingsView.swift` / `LogsView.swift` — settings and log-viewing screens.
- `DatabaseStatsService.swift` / `SystemStatsService.swift` / `MetricsService.swift` — stats surfaced in the dashboard (DB size/counts, system resource use, relay metrics).
- `SpamFilterService.swift` — UI/control surface for spam filtering config.
- `NostrEvent.swift` — Swift model for Nostr events used by the UI.

The app and relay communicate only through: the relay's config file on disk, the relay subprocess's stdout/log files, and the relay's own WebSocket/HTTP API (no direct FFI).
