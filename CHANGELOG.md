# Changelog

All notable changes to Phosphor are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-05-15

First public release. A premium, self-hosted photo client for a personal
Immich server.

### Library & Viewing
- Paginated timeline grouped by month/year with infinite scroll
- Full-screen photo viewer: pinch-zoom (1–10×), pan, swipe between assets,
  drag-to-dismiss, single-tap chrome toggle
- Progressive image loading (thumbnail upgrades to full-res with no flash)
- Native video playback (AVPlayerViewController), short clips loop
- Live Photo support — composed `PHLivePhoto`, touch-and-hold to play
- EXIF detail sheet with map snapshot; graceful "No metadata available"
- Optimistic favorite / archive / trash with revert on failure

### Organization
- Albums: grid, create / rename / delete, sort, bulk remove, add-to-album
- Search: smart + metadata modes, 400 ms debounce, Explore mosaic,
  recent searches
- People: face strip → per-person grid
- Memories: "on this day" cards → auto-advancing slideshow with crossfade
- Map: geotagged markers with a live nearby-photos tray
- Stacks: badge + dedicated stack viewer
- Trash: restore / permanently delete / empty
- Archive: archive / unarchive
- Duplicates: card-style review (Keep / Stack / Skip)
- Shared Links: list, create (expiry / password / options), copy, delete
- Multi-select with a bulk-actions toolbar

### Backup & Platform
- Camera-roll backup with SHA1 de-duplication against the server
- Wi-Fi-only gate, resumable queue, background upload via BGTaskScheduler
- "Free Up Space" — deletes local copies only after server-confirmed presence
- WidgetKit widgets: small / medium / large / lock-screen
- Siri Shortcuts (Favorites, Memories, Backup, Search) + Spotlight indexing
- App Group credential sharing between app and widget

### Settings & Safety
- Onboarding wall until a connection succeeds
- Profile: server config, connection test with latency, library statistics
- Read-only mode — gates every destructive action app-wide
- Re-authentication prompt when the API key is rejected (401/403)
- Haptics toggle honoured globally

### Foundation
- MVVM, SwiftUI, async/await, structured concurrency throughout
- Actor-based image cache with in-flight de-duplication and memory-pressure eviction
- Centralized typography, color, spacing and corner-radius tokens
- Dark-only premium aesthetic; instant black launch screen
- 30-second request timeout; graceful offline / error / empty states
- Accessibility: labels, hints, zoom actions, 44 pt minimum tap targets
- No third-party dependencies; XcodeGen project; GitHub Actions CI → TestFlight
