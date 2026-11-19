# Tempus

Tempus is a standalone, local-first screenshot timelapse recorder inspired by [Hack Club Lookout](https://github.com/hackclub/lookout). It has no accounts, tokens, program integration, YSWS integration, server, or uploads.

## Features

- Capture a screen or app window at native resolution in the desktop app, or use a camera
- Configurable screenshot interval
- Pause, resume, stop, and name sessions
- Local gallery and frame scrubber
- Full-resolution local MP4 timelapse export
- Light and dark system themes
- Browser development mode and a Tauri desktop shell

## Develop

```bash
npm install
npm run dev
```

Open `http://localhost:1420`. Screen capture requires localhost or another secure context.

## Desktop

Install the [Rust toolchain](https://rustup.rs/), then run:

```bash
npm run tauri dev
```

Build installers with `npm run tauri build`.

## Privacy

Session metadata and screenshots are stored in IndexedDB inside the app's webview profile. Exports are created locally using the browser media encoder.
