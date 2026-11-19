# Tempus Swift rewrite plan

> **Status (2026-11-19): done.** The Swift app replaced the Tauri app, and the old files were removed. The last Tauri version is in commit `be7707d`. Notes on what changed from this plan: the project has no separate entitlements file (sandbox, camera and file access come from build settings); frames in video mode are not duplicated to fill gaps (the previous frame just stays on screen); and `NSScreenCaptureUsageDescription` was dropped because macOS doesn't use it.

Goal: replace the Tauri + React app with a native macOS app in Swift / SwiftUI that keeps every current feature, looks native (Liquid Glass, automatic dark mode), and records smaller, sharper video. Then delete the Tauri and web files.

## Decisions

| Topic | Choice | Notes |
|---|---|---|
| Minimum macOS | **26 (Tahoe)** | The first release with Liquid Glass APIs (`glassEffect`, `.buttonStyle(.glass)`). Builds with Xcode 27.1 / SDK 27 |
| UI | SwiftUI, AppKit only where needed | SF Symbols replace `src/icons.tsx` |
| Capture | ScreenCaptureKit (screens and windows), AVFoundation (camera) | Replaces `xcap`, `getDisplayMedia` and `getUserMedia` |
| Encode | AVAssetWriter → VideoToolbox **HEVC**, falling back to H.264 | Hardware-encoded, zero-copy 420v buffers |
| Metadata | SwiftData | Replaces IndexedDB `sessions` |
| Media | Files in `~/Library/Application Support/Tempus/Sessions/<id>/` | Replaces IndexedDB `frames` / `videoChunks` blobs |
| Settings | `@AppStorage` | Replaces `localStorage` (`tempus-interval`, `tempus-mode`, `tempus-speed`) |
| Project | Hand-written `Tempus.xcodeproj` using a synchronized folder group | New Swift files need no project edits, and no XcodeGen or Tuist |
| Old recordings | **Not migrated** | They live in the Tauri webview's IndexedDB. Export any you want to keep before the deletion phase |

## Features to keep (current app → Swift)

| Current (file) | Swift |
|---|---|
| Gallery grid with thumbnail, status badge, tracked time, speed, date, delete button (`GalleryPage.tsx`) | `GalleryView`: `LazyVGrid` of cards, context menu + hover ✕ to delete, empty state with `ContentUnavailableView` |
| Delete confirmation that names the session and its frame/video count (`App.tsx` Modal) | `.confirmationDialog`, which removes the SwiftData row and the session folder |
| Source page: Screenshots/Video mode, Screens & windows / Cameras, list of displays and windows with resolution, speed picker (5–300×), size estimate (`SourcePage.tsx`) | `NewSessionView`: segmented pickers, a list from `SCShareableContent` (Tempus's own windows excluded), speed chips, the same MB/hour estimate |
| Settings: capture interval 5/15/30/60/120 s, privacy note, about (`SettingsPage.tsx`) | `Settings` scene (⌘,) with a `Form` |
| Recorder: live clock, frame/size stats, latest-frame preview, source label, Pause/Resume, Stop → name sheet with Save & Stop / Resume (`RecordPage.tsx`) | `RecordView` with glass status card and glass control bar, name `.sheet` |
| Screenshot mode: one lossless frame every N seconds | `SCScreenshotManager.captureImage` on a timer, saved as **HEIC** (much smaller than PNG; text stays sharp at quality ≈0.9) |
| Video mode: samples at `30 / speed` fps onto a constant 30 fps timeline, holds the last frame when capture falls behind (capped at 2 s), pauses excluded from the clock, fragmented MP4 written every ~2 s so a crash keeps the video (`video.ts`) | `TimelapseWriter`: `SCStream` with `minimumFrameInterval = speed / 30`, the same slot and hold logic, `AVAssetWriter` with `movieFragmentInterval = 2 s` |
| Bitrate plan: HEVC 0.045 / H.264 0.07 bits per pixel, 1.5 Mbps floor, 500 MB/hour cap, step down through 4K/1440p/1080p if the encoder rejects a size | Ported as the pure function `VideoPlan`, plus unit tests |
| Thumbnail and stats checkpoint every 5 s | Same; a 640 px JPEG in the session folder |
| Detail, video mode: player, recorded time, speed, length, size, resolution + codec, Save video | `DetailView` with AVKit `VideoPlayer`, stats grid, `fileExporter` (copies the file) |
| Detail, screenshot mode: frame scrubber with `n / total`, Export timelapse with % progress at 1 fps | `Slider` scrubber; `FrameExporter` (AVAssetWriter, HEVC, 1 fps) with a progress bar, then `fileExporter` |
| Source lost (window closed / sharing ended) → auto-pause with a message; Resume reconnects | `SCStreamDelegate.didStopWithError` → pause + banner; Resume re-resolves the source or reopens the picker |
| Launch recovery: unfinished sessions marked complete | Same, on launch |
| Camera source | `AVCaptureSession` + `AVCaptureVideoDataOutput` feeding the same writer and screenshot sinks |
| Permission errors | `CGPreflightScreenCaptureAccess` / `AVCaptureDevice.authorizationStatus`, with a button that opens System Settings |

Dropped on purpose: browser dev mode (`npm run dev`) and the web fallback paths (MediaRecorder export, canvas encoding). The native app doesn't need them.

## UI direction

- Standard window with a unified toolbar. On macOS 26 the toolbar is Liquid Glass automatically. Default size is about 520×680 and resizable (the Tauri window was locked at 480×640).
- Glass used sparingly, only on floating controls: the recorder's status card and Pause/Stop bar inside a `GlassEffectContainer`, the gallery's floating "New timelapse" button, and the preview's LOCAL chip. Content (thumbnails, video) stays plain.
- `.buttonStyle(.glassProminent)` for primary actions (Start, Save video, Export), and `.glass` for the rest. Destructive actions use the `.destructive` role.
- Dark mode needs no extra work: semantic colours only (`.primary`, `.secondary`, `.tint`, materials), and an accent colour in the asset catalog.
- Navigation: `NavigationStack` (Gallery → New session → Recording → Detail), so back buttons and swipe gestures come for free.
- Accessibility: SF Symbols with labels, Dynamic Type through text styles, Reduce Motion / Reduce Transparency respected (glass falls back automatically).

## Project layout

```
Tempus.xcodeproj
Tempus/
  TempusApp.swift            App, WindowGroup, Settings scene, launch recovery
  Model/
    Session.swift            @Model: id, name, dates, status, mode, source, interval, speed, stats, video info
    SessionStore.swift       folders, thumbnails, delete
    VideoPlan.swift          bitrate/size planning (pure, tested)
    Formatting.swift         clock / tracked-time / bytes / speed summary (ports utils.ts and parts of video.ts)
  Capture/
    CaptureSource.swift      display / window / camera
    SourceCatalog.swift      SCShareableContent listing and permission checks
    ScreenCapturer.swift     SCStream + SCScreenshotManager
    CameraCapturer.swift     AVCaptureSession
    RecordingController.swift  @Observable: clock, pause/resume, frame routing, checkpoints
  Encoding/
    TimelapseWriter.swift    live HEVC writer with constant-frame-rate slots
    FrameExporter.swift      screenshots → MP4
  Views/
    GalleryView.swift  SessionCard.swift  NewSessionView.swift
    RecordView.swift   DetailView.swift   SettingsView.swift
  Resources/
    Assets.xcassets (AppIcon from src-tauri/app-icon.svg, AccentColor)
    Info.plist keys: NSScreenCaptureUsageDescription, NSCameraUsageDescription (text from src-tauri/Info.plist)
    Tempus.entitlements: App Sandbox, camera, user-selected files read/write
TempusTests/
  VideoPlanTests.swift  SlotTimingTests.swift  FormattingTests.swift
```

Bundle ID stays `app.tempus.timelapse`, and the version stays 0.1.0 (rename to 1.0 later if you like).

## Phases

1. **Prep.** Run `git init` and commit the current Tauri app, so the later deletion can be undone. Builds use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, because `xcode-select` currently points at the Command Line Tools (optionally fix it once with `sudo xcode-select -s /Applications/Xcode.app`).
2. **Scaffold.** Xcode project, app target, test target, Info.plist, entitlements, app icon. `xcodebuild` builds and launches an empty gallery.
3. **Model and storage.** SwiftData `Session`, session folders, launch recovery, delete. Gallery and Settings working with fake data.
4. **Sources.** Permission flow, display and window list, camera list, New Session screen with the mode, speed and estimate UI.
5. **Screenshot mode.** Interval capture → HEIC, recorder screen, pause/resume, name-and-stop, thumbnails.
6. **Video mode.** `TimelapseWriter` with slot logic, fragmented HEVC, 5 s checkpoints, source-lost handling.
7. **Camera** for both modes.
8. **Detail and export.** Video player, frame scrubber, screenshot → MP4 export with progress, Save via `fileExporter`.
9. **Polish.** Liquid Glass pass, dark and light check, empty and error states, keyboard shortcuts (⌘N new, Space pause/resume, ⌘. stop).
10. **Verify.** Unit tests (bitrate plan, slot timing, formatting), Release build, and a manual smoke test of each source × mode. The first run needs you to approve Screen Recording and Camera access in System Settings.
11. **Delete the old app.** Remove `src/`, `src-tauri/`, `node_modules/`, `dist/`, `index.html`, `package.json`, `package-lock.json`, `tsconfig.json`, `vite.config.ts` and the Vite entry in `.claude/launch.json`. Rewrite `README.md` (build with Xcode, Swift stack) and `.gitignore` (`DerivedData`, `xcuserdata`, `.build`). Commit.

## Expected gains

- No PNG → base64 → webview → canvas → WebCodecs path. Frames go straight from the GPU to the hardware encoder.
- Screenshot sessions: HEIC instead of PNG, roughly 5–10× less disk.
- Video sessions: the same 500 MB/hour ceiling, but VideoToolbox HEVC on screen content usually lands far below it.
- App size: about 1–3 MB instead of the Tauri bundle plus the web assets.

## Out of scope (possible later)

Menu bar recording indicator (`MenuBarExtra`), global hotkeys, idle auto-pause, region capture, iCloud sync, notarized distribution.
