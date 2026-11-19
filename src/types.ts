export type SessionStatus = "recording" | "paused" | "complete";
export type SourceType = "screen" | "camera";
export type CaptureMode = "screenshots" | "video";

export interface NativeCaptureSource {
  type: "monitor" | "window";
  id: number;
  label: string;
  width: number;
  height: number;
  isPrimary: boolean;
}

export type CaptureTarget =
  | { kind: "media"; stream: MediaStream }
  | { kind: "native"; source: NativeCaptureSource };

export interface TimelapseSession {
  id: string;
  name: string;
  createdAt: number;
  endedAt?: number;
  status: SessionStatus;
  sourceType: SourceType;
  sourceLabel: string;
  intervalSeconds: number;
  trackedSeconds: number;
  screenshotCount: number;
  thumbnail?: Blob;
  /** Missing on sessions created before video mode existed. */
  mode?: CaptureMode;
  /** Video mode: playback speed multiplier (e.g. 60 = 1 hour becomes 1 minute). */
  speed?: number;
  videoBytes?: number;
  videoSeconds?: number;
  videoCodec?: string;
  videoWidth?: number;
  videoHeight?: number;
  videoBitrate?: number;
}

export interface VideoChunk {
  id?: number;
  sessionId: string;
  data: Blob;
}

export interface CapturedFrame {
  id?: number;
  sessionId: string;
  capturedAt: number;
  blob: Blob;
}

export type Page =
  | { name: "gallery" }
  | { name: "source" }
  | { name: "record"; id: string }
  | { name: "detail"; id: string }
  | { name: "settings" };
