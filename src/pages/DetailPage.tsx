import { useEffect, useMemo, useState } from "react";
import { Download } from "../icons";
import type { CapturedFrame, TimelapseSession } from "../types";
import { getFrames, getVideoBlob } from "../db";
import { formatBytes } from "../video";
import { blobUrl, formatTracked, safeFilename, wait } from "../utils";
import { Button } from "../components/Button";
import { BufferTarget, CanvasSource, Mp4OutputFormat, Output, Quality, canEncodeVideo } from "mediabunny";

interface Props {
  session: TimelapseSession;
  onBack: () => void;
  onDelete: () => void;
}

const MP4_MIME_TYPES = [
  // Prefer an explicit high-profile H.264 encoder. A generic MP4 request can
  // select a low AVC level that silently downsizes a large canvas.
  "video/mp4;codecs=avc1.64003C",
  "video/mp4;codecs=avc1.640033",
  "video/mp4;codecs=avc1.64002A",
  "video/mp4;codecs=avc1.4D4033",
  "video/mp4;codecs=avc1.42E01E",
  "video/mp4",
];
const FRAME_DURATION_MS = 1000;
const FRAME_RATE = 1;
const EXPORT_QUALITY = new Quality("very-high");

interface FrameSize {
  width: number;
  height: number;
}

function even(value: number): number {
  return value + (value % 2);
}

async function exportSize(frames: CapturedFrame[]): Promise<FrameSize> {
  let largest: FrameSize = { width: 0, height: 0 };

  for (const frame of frames) {
    const bitmap = await createImageBitmap(frame.blob);
    if (bitmap.width * bitmap.height > largest.width * largest.height) {
      largest = { width: bitmap.width, height: bitmap.height };
    }
    bitmap.close();
  }

  return { width: even(largest.width), height: even(largest.height) };
}

function drawFrame(context: CanvasRenderingContext2D, bitmap: ImageBitmap, size: FrameSize): void {
  const scale = Math.min(1, size.width / bitmap.width, size.height / bitmap.height);
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);
  const x = (size.width - width) / 2;
  const y = (size.height - height) / 2;

  context.fillStyle = "#000";
  context.fillRect(0, 0, size.width, size.height);
  context.imageSmoothingEnabled = scale !== 1;
  if (context.imageSmoothingEnabled) context.imageSmoothingQuality = "high";
  // Integer placement avoids softening every pixel when an odd-sized source
  // needs a one-pixel border for H.264's even-dimension requirement.
  context.drawImage(bitmap, Math.floor(x), Math.floor(y), width, height);
}

function createExportCanvas(size: FrameSize): { canvas: HTMLCanvasElement; context: CanvasRenderingContext2D } {
  const canvas = document.createElement("canvas");
  canvas.width = size.width;
  canvas.height = size.height;
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) throw new Error("Canvas is unavailable.");
  return { canvas, context };
}

async function encodeWithWebCodecs(
  frames: CapturedFrame[],
  size: FrameSize,
  onProgress: (value: number) => void,
): Promise<Blob | undefined> {
  if (typeof VideoEncoder === "undefined" || !await canEncodeVideo("avc", {
    width: size.width,
    height: size.height,
    quality: EXPORT_QUALITY,
    latencyMode: "quality",
    contentHint: "detail",
  })) return undefined;

  const { canvas, context } = createExportCanvas(size);
  const target = new BufferTarget();
  const output = new Output({
    format: new Mp4OutputFormat({ fastStart: "in-memory" }),
    target,
  });
  const source = new CanvasSource(canvas, {
    codec: "avc",
    quality: EXPORT_QUALITY,
    latencyMode: "quality",
    contentHint: "detail",
    alpha: "discard",
    keyFrameInterval: 2,
  });
  output.addVideoTrack(source, { frameRate: FRAME_RATE, maximumPacketCount: frames.length });

  try {
    await output.start();
    for (let index = 0; index < frames.length; index += 1) {
      const bitmap = await createImageBitmap(frames[index].blob);
      drawFrame(context, bitmap, size);
      bitmap.close();
      await source.add(index / FRAME_RATE, 1 / FRAME_RATE);
      onProgress(Math.round(((index + 1) / frames.length) * 100));
    }
    await output.finalize();
  } catch (reason) {
    if (output.state === "pending" || output.state === "started") await output.cancel();
    throw reason;
  }

  if (!target.buffer) throw new Error("The MP4 encoder produced no output.");
  return new Blob([target.buffer], { type: "video/mp4" });
}

async function encodeWithMediaRecorder(
  frames: CapturedFrame[],
  size: FrameSize,
  onProgress: (value: number) => void,
): Promise<Blob> {
  const mimeType = MP4_MIME_TYPES.find((candidate) => MediaRecorder.isTypeSupported(candidate));
  if (!mimeType) throw new Error("MP4 export is not supported by this browser. Open Tempus in the desktop app or a browser with MP4 recording support.");

  const { canvas, context } = createExportCanvas(size);
  const stream = canvas.captureStream(FRAME_RATE);
  const videoTrack = stream.getVideoTracks()[0];
  if (videoTrack) videoTrack.contentHint = "detail";
  const videoBitsPerSecond = Math.min(160_000_000, Math.max(16_000_000, canvas.width * canvas.height * 8));
  const recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond });
  const chunks: Blob[] = [];
  recorder.ondataavailable = (event) => { if (event.data.size) chunks.push(event.data); };
  const finished = new Promise<Blob>((resolve, reject) => {
    recorder.onerror = () => reject(new Error("Video encoding failed."));
    recorder.onstop = () => resolve(new Blob(chunks, { type: "video/mp4" }));
  });
  recorder.start(200);
  for (let index = 0; index < frames.length; index += 1) {
    const bitmap = await createImageBitmap(frames[index].blob);
    drawFrame(context, bitmap, size);
    bitmap.close();
    onProgress(Math.round(((index + 1) / frames.length) * 100));
    await wait(FRAME_DURATION_MS);
  }
  await wait(200);
  recorder.stop();
  stream.getTracks().forEach((track) => track.stop());
  return finished;
}

async function encodeTimelapse(frames: CapturedFrame[], onProgress: (value: number) => void): Promise<Blob> {
  if (!frames.length) throw new Error("This session has no screenshots.");
  const size = await exportSize(frames);
  try {
    const encoded = await encodeWithWebCodecs(frames, size, onProgress);
    if (encoded) return encoded;
  } catch (reason) {
    // Older WebKit builds can report an AVC configuration as supported and
    // still reject it when encoding starts. Keep a compatibility path for
    // those builds instead of failing the entire export.
    console.warn("High-quality frame encoder was unavailable; using MediaRecorder fallback.", reason);
    onProgress(0);
  }
  return encodeWithMediaRecorder(frames, size, onProgress);
}

async function saveBlob(blob: Blob, filename: string): Promise<void> {
  const resolvedFilename = filename.replace(/\.[^./\\]+$/i, "") + ".mp4";
  if (window.__TAURI_INTERNALS__) {
    const [{ save }, { writeFile }] = await Promise.all([import("@tauri-apps/plugin-dialog"), import("@tauri-apps/plugin-fs")]);
    const path = await save({ defaultPath: resolvedFilename, filters: [{ name: "MP4 video", extensions: ["mp4"] }] });
    if (path) {
      const mp4Path = path.replace(/\.[^./\\]+$/i, "") + ".mp4";
      await writeFile(mp4Path, new Uint8Array(await blob.arrayBuffer()));
    }
    return;
  }
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = resolvedFilename;
  anchor.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function formatLength(seconds: number): string {
  const whole = Math.round(seconds);
  return whole < 60 ? `${whole} sec` : `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

function VideoDetail({ session, onBack, onDelete }: Props) {
  const [video, setVideo] = useState<Blob | null>();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();
  useEffect(() => { void getVideoBlob(session.id).then((blob) => setVideo(blob ?? null)); }, [session.id]);
  const videoUrl = useMemo(() => blobUrl(video ?? undefined), [video]);
  useEffect(() => () => { if (videoUrl) URL.revokeObjectURL(videoUrl); }, [videoUrl]);

  const save = async () => {
    if (!video) return;
    setSaving(true);
    setError(undefined);
    try {
      await saveBlob(video, `${safeFilename(session.name)}.mp4`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not save the video.");
    } finally {
      setSaving(false);
    }
  };

  const size = video?.size ?? session.videoBytes ?? 0;
  return (
    <main className="page detail-page">
      <section className="detail-content">
        <div className="lookout-detail-header">
          <Button size="sm" onClick={onBack}>← Back</Button>
          <Button size="sm" onClick={onDelete}>Archive</Button>
        </div>
        <div className="detail-preview">
          {videoUrl ? <video src={videoUrl} controls playsInline /> : <div className="waiting-preview">{video === undefined ? "Loading video…" : "No video was recorded"}</div>}
        </div>
        <div className="detail-title-row">
          <div><h2>{session.name}</h2><p>{new Date(session.createdAt).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}</p></div>
        </div>
        <div className="stats-grid four">
          <div><strong>{formatTracked(session.trackedSeconds)}</strong><span>Recorded</span></div>
          <div><strong>{session.speed ?? 60}×</strong><span>Speed</span></div>
          <div><strong>{formatLength(session.videoSeconds ?? 0)}</strong><span>Video length</span></div>
          <div><strong>{formatBytes(size)}</strong><span>{session.videoWidth ? `${session.videoWidth}×${session.videoHeight} ${session.videoCodec === "hevc" ? "HEVC" : "H.264"}` : "File size"}</span></div>
        </div>
        {error && <div className="error-banner">{error}</div>}
        <Button variant="primary" size="lg" full onClick={save} loading={saving} disabled={!video} icon={<Download width={18} />}>
          {saving ? "Saving" : "Save video"}
        </Button>
      </section>
    </main>
  );
}

export function DetailPage(props: Props) {
  return props.session.mode === "video" ? <VideoDetail {...props} /> : <ScreenshotDetail {...props} />;
}

function ScreenshotDetail({ session, onBack, onDelete }: Props) {
  const [frames, setFrames] = useState<CapturedFrame[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [exporting, setExporting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string>();
  useEffect(() => { void getFrames(session.id).then(setFrames); }, [session.id]);
  const previewUrl = useMemo(() => blobUrl(frames[selectedIndex]?.blob || session.thumbnail), [frames, selectedIndex, session.thumbnail]);
  useEffect(() => () => { if (previewUrl) URL.revokeObjectURL(previewUrl); }, [previewUrl]);

  const exportVideo = async () => {
    setExporting(true);
    setError(undefined);
    try {
      const blob = await encodeTimelapse(frames, setProgress);
      await saveBlob(blob, `${safeFilename(session.name)}.mp4`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not export the video.");
    } finally {
      setExporting(false);
      setProgress(0);
    }
  };

  return (
    <main className="page detail-page">
      <section className="detail-content">
        <div className="lookout-detail-header">
          <Button size="sm" onClick={onBack}>← Back</Button>
          <Button size="sm" onClick={onDelete}>Archive</Button>
        </div>
        <div className="detail-preview">
          {previewUrl ? <img src={previewUrl} alt="Selected screenshot" /> : <div className="waiting-preview">No screenshots</div>}
          <span>{frames.length ? `${selectedIndex + 1} / ${frames.length}` : "No frames"}</span>
        </div>
        {frames.length > 1 && (
          <input className="frame-slider" type="range" min="0" max={frames.length - 1} value={selectedIndex} onChange={(event) => setSelectedIndex(Number(event.target.value))} aria-label="Preview frame" />
        )}
        <div className="detail-title-row">
          <div><h2>{session.name}</h2><p>{new Date(session.createdAt).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}</p></div>
        </div>
        <div className="stats-grid">
          <div><strong>{formatTracked(session.trackedSeconds)}</strong><span>Tracked time</span></div>
          <div><strong><span className="status-badge complete">Complete</span></strong><span>Status</span></div>
        </div>
        {error && <div className="error-banner">{error}</div>}
        <Button variant="primary" size="lg" full onClick={exportVideo} loading={exporting} icon={<Download width={18} />}>
          {exporting ? `Rendering ${progress}%` : "Export timelapse"}
        </Button>
      </section>
    </main>
  );
}
