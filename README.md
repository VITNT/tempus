# Tempus

Tempus is a native, local-first timelapse recorder for macOS, inspired by [Hack Club Lookout](https://github.com/hackclub/lookout). It has no accounts, server or uploads.

## Features

- Record a display, a single window, or a camera
- **Screenshots mode:** a full-resolution HEIC frame every 5 s to 2 min, exported to MP4 whenever you like
- **Video mode:** a sped-up (5×–300×) hardware HEVC video written live, capped at 500 MB per recorded hour
- Pause, resume, stop and name sessions. Sessions survive a crash (video is written as fragmented MP4)
- Gallery, frame scrubber, built-in player, save or export to MP4
- Native SwiftUI interface with Liquid Glass and automatic light/dark mode

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later to build (tested with Xcode 27.1)

## Build and run

Open `Tempus.xcodeproj` in Xcode and press ⌘R, or from the terminal:

```bash
xcodebuild -project Tempus.xcodeproj -scheme Tempus -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Tempus.app
```

If `xcodebuild` complains that the active developer directory is the Command Line Tools, prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or switch it once with `sudo xcode-select -s /Applications/Xcode.app`.

On first use, macOS asks for **Screen Recording** (or **Camera**) access. Local builds are ad-hoc signed, so macOS may ask again after you rebuild.

## Test

```bash
xcodebuild -project Tempus.xcodeproj -scheme Tempus -derivedDataPath build/DerivedData test
```

The tests cover the bitrate plan, frame timing, formatting, and real HEVC and H.264 encodes through AVFoundation. Prefix the command with `TEST_RUNNER_TEMPUS_SNAPSHOTS=1` to also render each screen to PNGs in `~/Library/Containers/app.tempus.timelapse/Data/tmp/tempus-snapshots/`. Those images are approximate: they don't show Liquid Glass and dark mode renders on a transparent background.

## Release

`scripts/release.sh` archives a universal (Apple silicon + Intel) Release build, signs it, and packages `build/release/Tempus-<version>.dmg` with a drag-to-Applications window, a stable-named `Tempus.dmg` copy, and a SHA-256 checksum. It also writes the version, size and checksum into the download page at `docs/index.html`.

```bash
scripts/release.sh
```

For a DMG that opens on other Macs without a Gatekeeper warning, it must be signed with a **Developer ID Application** certificate and notarized. One-time setup:

1. In Xcode → Settings → Accounts, select your team, click **Manage Certificates…**, and add a **Developer ID Application** certificate (needs a paid Apple Developer Program membership, Account Holder or Admin role).
2. Save notarization credentials to the keychain, using an [app-specific password](https://account.apple.com):

   ```bash
   xcrun notarytool store-credentials tempus --apple-id <your Apple ID> --team-id WB59R5BKBH
   ```

Then build, sign, notarize and staple in one go:

```bash
NOTARY_PROFILE=tempus scripts/release.sh
```

The script picks up the Developer ID certificate automatically; without it, the DMG uses the development signature and is only suitable for testing. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project before each release.

To publish, host `docs/index.html`, `docs/icon.png` and `build/release/Tempus.dmg` in the same folder (for example GitHub Pages from `docs/`, with the DMG attached alongside).

## How it works

| Layer | Technology |
|---|---|
| UI | SwiftUI (`Tempus/Views`) |
| Capture | ScreenCaptureKit for displays and windows, AVFoundation for cameras (`Tempus/Capture`) |
| Encoding | AVAssetWriter → VideoToolbox HEVC, falling back to H.264 (`Tempus/Encoding`) |
| Library | SwiftData for session metadata. Media files are in `~/Library/Containers/app.tempus.timelapse/Data/Library/Application Support/Tempus/Sessions/` |

In video mode, ScreenCaptureKit delivers 4:2:0 frames no faster than `speed / 30` seconds apart, and only when the screen changes. Frames go straight from the GPU to the hardware encoder and are placed on a 30 fps timeline, so one hour at 60× plays back as one minute, and a static screen costs almost nothing.

## Privacy

Everything stays in the app's sandbox container on your Mac. Tempus makes no network requests.
