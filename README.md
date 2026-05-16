# Phosphor

A premium, self-hosted photo client for your personal [Immich](https://immich.app)
server. Ultra-minimal dark UI — Darkroom meets Apple Photos — built in pure
SwiftUI with no third-party dependencies.

> Personal project. Phosphor talks only to an Immich server **you** run; it
> stores nothing in any cloud service of its own.

## Features

Timeline, albums, search (smart + metadata), people, memories, a photo map,
stacks, trash, archive, duplicate review, shared links, multi-select bulk
actions, camera-roll backup with background upload, WidgetKit widgets, Siri
Shortcuts and Spotlight. See [CHANGELOG.md](CHANGELOG.md) for the full 1.0.0
list.

## Requirements

- **iOS 17.0+** (Swift 5.10, modern SwiftUI only)
- **Immich server** — developed against the current Immich API. The client
  uses: `/assets`, `/albums`, `/search/*`, `/people`, `/memories`,
  `/map/markers`, `/stacks`, `/duplicates`, `/shared-links`, `/trash/*`,
  `/server/statistics`, `/assets/bulk-upload-check`. Older Immich builds may
  return different response shapes for some of these — see the inline DTO
  caveats in `ImmichAPI.swift`.
- An Immich **API key** (Account Settings → API Keys).

## Configuration

On first launch the onboarding screen asks for:

1. **Server URL** — e.g. `https://immich.example.com` (include `/api` only if
   your deployment requires it; the trailing slash is trimmed automatically).
2. **API key** — sent as the `x-api-key` header on every request.

Credentials are stored in the shared App Group
(`group.com.sarpedon.phosphor`) so the widget can read them. Re-authentication
is prompted automatically if the key is later rejected.

## Building

There is no checked-in `.xcodeproj` — the project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd Phosphor
xcodegen generate
open Phosphor.xcodeproj
```

Targets: `Phosphor` (app) and `PhosphorWidgets` (widget extension). Both
require the App Group capability `group.com.sarpedon.phosphor` provisioned in
your Apple Developer account.

## Continuous Integration / TestFlight

`.github/workflows/build.yml` runs on `macos-15`, generates the project,
patches the build number, archives, exports with `ExportOptions.plist`, and
uploads to TestFlight. Configure these repository **Secrets**:

| Secret | Purpose |
| --- | --- |
| `APPLE_ID` | Apple ID used to upload to TestFlight |
| `APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `TEAM_ID` | 10-character Apple Developer Team ID |
| `CERTIFICATE_BASE64` | base64-encoded distribution `.p12` |
| `CERTIFICATE_PASSWORD` | password for the `.p12` |
| `PROVISIONING_PROFILE_BASE64` | base64-encoded `.mobileprovision` |
| `CODE_SIGN_IDENTITY` | e.g. `Apple Distribution: Your Name (TEAMID)` |
| `PROVISIONING_PROFILE_SPECIFIER` | provisioning profile name |

The build number is `${{ github.run_number }}`, patched into `project.yml`
(`CURRENT_PROJECT_VERSION`) before XcodeGen and into `Info.plist`
(`CFBundleVersion`) after — so it increases monotonically per CI run with no
manual bookkeeping.

## Architecture

- **MVVM** — `@MainActor` view models, no logic in view bodies
- **async/await + structured concurrency** — no Combine, no completion handlers
- **`ImmichAPI`** — singleton REST client; credentials read fresh from the App
  Group `UserDefaults` per request; 30 s timeout; 401/403 → re-auth signal
- **`ImageLoader`** — actor cache with in-flight de-duplication and
  memory-warning eviction
- **Design tokens** — `Typography`, `Color+Phosphor`, `Layout`
  (`Spacing` / `CornerRadius`)

## License

Personal project — no license granted for redistribution.
