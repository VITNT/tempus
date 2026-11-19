import type { NativeCaptureSource, SourceType } from "./types";

// Ask for up to 8K and let the browser negotiate the highest resolution the
// selected screen, window, or camera can actually provide.
const HIGH_RESOLUTION_VIDEO: MediaTrackConstraints & { resizeMode: { ideal: string } } = {
  width: { ideal: 7680 },
  height: { ideal: 4320 },
  // Tempus takes stills, so spending capture bandwidth on 30 frames per second
  // only gives WebKit a reason to trade resolution for motion smoothness.
  frameRate: { ideal: 1, max: 5 },
  resizeMode: { ideal: "none" },
};

function optimizeCaptureStream(stream: MediaStream, sourceType: SourceType): MediaStream {
  const track = stream.getVideoTracks()[0];
  if (track) {
    // Preserve fine UI/text detail for screens. Camera sources still benefit
    // from motion-oriented processing rather than screen-content sharpening.
    track.contentHint = sourceType === "screen" ? "detail" : "motion";
  }
  return stream;
}

/**
 * @param frameRate Video mode samples the live stream several times a second,
 * so it asks for enough frames to sample from; screenshot mode keeps the low
 * default.
 */
export async function acquireCaptureStream(sourceType: SourceType, frameRate?: number): Promise<MediaStream> {
  const video = frameRate
    ? { ...HIGH_RESOLUTION_VIDEO, frameRate: { ideal: Math.min(30, Math.ceil(frameRate)), max: 30 } }
    : HIGH_RESOLUTION_VIDEO;
  if (sourceType === "screen") {
    const stream = await navigator.mediaDevices.getDisplayMedia({
      video,
      audio: false,
    });
    return optimizeCaptureStream(stream, sourceType);
  }

  const stream = await navigator.mediaDevices.getUserMedia({
    video,
    audio: false,
  });
  return optimizeCaptureStream(stream, sourceType);
}

interface NativeCaptureResult {
  base64: string;
  width: number;
  height: number;
}

export function supportsNativeCapture(): boolean {
  return Boolean(window.__TAURI_INTERNALS__);
}

export async function listNativeCaptureSources(): Promise<NativeCaptureSource[]> {
  if (!supportsNativeCapture()) return [];
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<NativeCaptureSource[]>("list_capture_sources");
}

export async function captureNativeFrame(source: NativeCaptureSource): Promise<Blob> {
  const { invoke } = await import("@tauri-apps/api/core");
  const result = await invoke<NativeCaptureResult>("capture_screenshot", {
    source: { type: source.type, id: source.id },
  });
  const binary = atob(result.base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return new Blob([bytes], { type: "image/png" });
}

/** Fast-path native grab for video mode: binary IPC, fast PNG compression. */
export async function captureNativeVideoFrame(source: NativeCaptureSource): Promise<Blob> {
  const { invoke } = await import("@tauri-apps/api/core");
  const bytes = await invoke<ArrayBuffer>("capture_video_frame", {
    source: { type: source.type, id: source.id },
  });
  return new Blob([bytes], { type: "image/png" });
}

export function capturePermissionError(reason: unknown, action = "start capture"): string {
  if (reason instanceof DOMException && reason.name === "NotAllowedError") {
    return `Capture permission was cancelled. Choose a source when you’re ready to ${action}.`;
  }
  if (typeof reason === "string") return reason;
  return reason instanceof Error ? reason.message : `Could not ${action}.`;
}
