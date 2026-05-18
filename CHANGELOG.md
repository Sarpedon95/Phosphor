# Changelog

All notable changes to Phosphor are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Stages 1–3: security hardening, authentication overhaul, and a broad UX,
editing, library, backup, map and accessibility pass.

### Security
- Credentials moved from UserDefaults to the iOS Keychain
  (`kSecClassGenericPassword`, `accessibleAfterFirstUnlock`) with a one-time
  launch migration from any legacy UserDefaults values
- Video playback no longer leaks the API key as a URL query parameter — auth
  is sent via an `AVURLAsset` request header instead
- Share action now shares the actual decoded image, not an authenticated URL
  that was useless (and credential-bearing) to recipients
- Disk thumbnail cache stored under Caches with a 500 MB LRU cap

### Authentication
- Email + password sign-in (`/auth/login`) with bearer-token storage,
  `validateToken`, and a password-based `probe`
- Bearer token preferred over `x-api-key`; API-key path retained for
  backward compatibility
- Redesigned three-step onboarding: mDNS discovery (NWBrowser) → email/
  password login → API-key fallback
- QR-code scanner that pre-fills the server address

### UX
- Double-tap to zoom (1× ⇄ 3×, centered on tap) in the photo viewer
- Context menus on grid cells (favorite, archive, add-to-album, share, trash)
  with a new album picker sheet
- Rubber-band drag multi-select; long-press a cell to enter selection mode
- iOS 18 zoom transition from grid thumbnail into the full-screen viewer
  (graceful fallback on iOS 17 — matchedGeometryEffect can't cross a modal)
- Shared-album management: search the user directory, add/remove people
- Per-year On-This-Day query (concurrent TaskGroup, capped at 100, sorted)
- Cycling grid / list / justified layout button in the Library toolbar
- Error-recovery states with Retry across Library, Search, People, Memories

### Editing
- Crop UI made functional: full-screen editor bound to crop rect + angle
- "Save as new photo?" confirmation before an edit is uploaded
- Press-and-hold Compare button (replaces the hidden two-finger tap)
- Preset intensity slider with `lastAppliedPreset` for live re-application

### Library
- Person detail: birthdate display and a "Merge with…" flow (handles the
  404 from servers that don't support face merging)
- Memory reactions: save (heart) and archive with confirmation

### Backup
- Excluded-albums section — skip chosen local albums during backup
- Estimated time remaining, surfaced in the Live Activity ("~3 min remaining")
- Dedicated Free-Up-Space screen with thumbnails, sizes and per-row delete

### Map
- Time-range filter sheet (from/to date pickers, Clear)
- Switched to an `MKMapView` wrapper with native marker clustering;
  tapping a cluster zooms to fit its members

### Accessibility
- Dynamic Type: typography rebuilt on system text styles
- Labels/values on every editing slider and category tab
- RGB histogram, grid cells, year and memory cards labelled

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
