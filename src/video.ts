import { AppendOnlyStreamTarget, CanvasSource, Mp4OutputFormat, Output, Quality, canEncodeVideo } from "mediabunny";
import { addVideoChunk } from "./db";

/**
 * Video mode records a timelapse directly to an MP4 instead of storing
 * screenshots. Frames are sampled from the source at `OUTPUT_FPS / speed` per
 * second and placed on a constant 30 fps timeline, so a 60× recording of one
 * hour plays back as one smooth minute.
 */
export const OUTPUT_FPS = 30;
export const SPEED_OPTIONS = [5, 10, 30, 60, 120, 300] as const;
export const DEFAULT_SPEED = 60;

/** Hard ceiling on file size: 500 MB per hour of recorded (real) time. */
export const MAX_BYTES_PER_HOUR = 500 * 1000 * 1000;
/** VBR encoders overshoot a little and MP4 adds container overhead. */
const BUDGET_HEADROOM = 0.85;

/**
 * Bits per pixel per frame that looks "high quality" for screen content.
 * HEVC needs roughly 35–40% fewer bits than H.264 for the same result.
 * At 4K30 this is ~17 Mbps for H.264 and ~11 Mbps for HEVC.
 */
const QUALITY_BITS_PER_PIXEL = { hevc: 0.045, avc: 0.07 } as const;
const MIN_BITRATE = 1_500_000;

type VideoCodecChoice = keyof typeof QUALITY_BITS_PER_PIXEL;

export interface VideoPlan {
  codec: VideoCodecChoice;
  width: number;
  height: number;
  bitrate: number;
  /** True when the 500 MB/hour cap, not the quality target, set the bitrate. */
  budgetLimited: boolean;
}

/** Seconds of output video per hour of recording. */
export function videoSecondsPerHour(speed: number): number {
  return 3600 / speed;
}

export function planBitrate(codec: VideoCodecChoice, width: number, height: number, speed: number): { bitrate: number; budgetLimited: boolean } {
  const quality = width * height * OUTPUT_FPS * QUALITY_BITS_PER_PIXEL[codec];
  const budget = (MAX_BYTES_PER_HOUR * 8 * BUDGET_HEADROOM) / videoSecondsPerHour(speed);
  const bitrate = Math.round(Math.max(MIN_BITRATE, Math.min(quality, budget)));
  return { bitrate, budgetLimited: budget < quality };
}

/** Worst-case MB written per hour of recording (VBR usually lands well under). */
export function estimateMegabytesPerHour(bitrate: number, speed: number): number {
  return (bitrate * videoSecondsPerHour(speed)) / 8 / 1_000_000;
}

function even(value: number): number {
  return Math.max(2, value - (value % 2));
}

function fit(width: number, height: number, maxWidth: number, maxHeight: number) {
  const scale = Math.min(1, maxWidth / width, maxHeight / height);
  return { width: even(Math.round(width * scale)), height: even(Math.round(height * scale)) };
}

/**
 * Prefer native resolution in HEVC (smaller files, supports 5K/6K), then
 * H.264, then step down to sizes H.264 hardware is guaranteed to accept.
 */
export async function chooseVideoPlan(sourceWidth: number, sourceHeight: number, speed: number, contentHint: string): Promise<VideoPlan> {
  if (typeof VideoEncoder === "undefined") {
    throw new Error("Video mode needs WebCodecs. Use the Tempus desktop app or a current browser.");
  }
  const portrait = sourceHeight > sourceWidth;
  const caps = [[Infinity, Infinity], [3840, 2160], [2560, 1440], [1920, 1080]].map(([w, h]) => portrait ? [h, w] : [w, h]);
  const sizes = caps
    .map(([w, h]) => fit(sourceWidth, sourceHeight, w, h))
    .filter((size, index, all) => all.findIndex((other) => other.width === size.width && other.height === size.height) === index);

  for (const size of sizes) {
    for (const codec of ["hevc", "avc"] as const) {
      const { bitrate, budgetLimited } = planBitrate(codec, size.width, size.height, speed);
      const supported = await canEncodeVideo(codec, {
        width: size.width,
        height: size.height,
        quality: new Quality({ bitrate, bitrateMode: "variable" }),
        latencyMode: "quality",
        contentHint,
      }).catch(() => false);
      if (supported) return { codec, ...size, bitrate, budgetLimited };
    }
  }
  throw new Error("This device has no hardware video encoder that can record this source.");
}

export class VideoTimelapseRecorder {
  readonly plan: VideoPlan;
  readonly speed: number;
  private readonly canvas: HTMLCanvasElement;
  private readonly context: CanvasRenderingContext2D;
  private readonly output: Output;
  private readonly source: CanvasSource;
  private readonly written: { bytes: number };
  private nextSlot = 0;
  private timeOrigin = 0;
  private hasFrame = false;
  private finished = false;

  private constructor(plan: VideoPlan, speed: number, output: Output, source: CanvasSource, canvas: HTMLCanvasElement, context: CanvasRenderingContext2D, written: { bytes: number }) {
    this.plan = plan;
    this.written = written;
    this.speed = speed;
    this.output = output;
    this.source = source;
    this.canvas = canvas;
    this.context = context;
  }

  static async create(options: { sessionId: string; width: number; height: number; speed: number; contentHint: "detail" | "motion" }): Promise<VideoTimelapseRecorder> {
    const plan = await chooseVideoPlan(options.width, options.height, options.speed, options.contentHint);
    const canvas = document.createElement("canvas");
    canvas.width = plan.width;
    canvas.height = plan.height;
    const context = canvas.getContext("2d", { alpha: false });
    if (!context) throw new Error("Canvas is unavailable.");

    const written = { bytes: 0 };
    // Fragmented MP4 is append-only: every finished fragment goes straight to
    // IndexedDB (disk), so memory stays flat and a crash loses at most the
    // last couple of seconds of output.
    const target = new AppendOnlyStreamTarget(new WritableStream<Uint8Array>({
      write: async (chunk) => {
        await addVideoChunk({ sessionId: options.sessionId, data: new Blob([chunk.slice()]) });
        written.bytes += chunk.byteLength;
      },
    }));
    const output = new Output({
      format: new Mp4OutputFormat({ fastStart: "fragmented", minimumFragmentDuration: 2 }),
      target,
    });
    const source = new CanvasSource(canvas, {
      codec: plan.codec,
      quality: new Quality({ bitrate: plan.bitrate, bitrateMode: "variable" }),
      latencyMode: "quality",
      contentHint: options.contentHint,
      alpha: "discard",
      keyFrameInterval: 4,
    });
    output.addVideoTrack(source, { frameRate: OUTPUT_FPS });
    await output.start();
    return new VideoTimelapseRecorder(plan, options.speed, output, source, canvas, context, written);
  }

  get bytes(): number { return this.written.bytes; }
  get frames(): number { return this.nextSlot; }
  get videoSeconds(): number { return this.nextSlot / OUTPUT_FPS; }

  /**
   * Adds a captured image at `activeSeconds` of recording time (pauses
   * excluded). The output is constant frame rate: if capture fell behind
   * (slow source, busy machine) the previous image is held for the missed
   * slots, so playback speed stays exactly `speed`×.
   */
  async addFrame(image: CanvasImageSource, width: number, height: number, activeSeconds: number): Promise<void> {
    if (this.finished) return;
    if (!this.hasFrame) this.timeOrigin = activeSeconds;
    const slot = Math.floor(((activeSeconds - this.timeOrigin) / this.speed) * OUTPUT_FPS);
    if (this.hasFrame && slot < this.nextSlot) return;

    // Never let a long stall flood the encoder with duplicates.
    const holdUntil = Math.min(slot, this.nextSlot + OUTPUT_FPS * 2);
    while (this.hasFrame && this.nextSlot < holdUntil) await this.encodeSlot();

    this.draw(image, width, height);
    this.hasFrame = true;
    await this.encodeSlot();
  }

  /** Small JPEG of the latest frame for the gallery and live preview. */
  thumbnail(maxWidth = 640): Promise<Blob | undefined> {
    if (!this.hasFrame) return Promise.resolve(undefined);
    const scale = Math.min(1, maxWidth / this.canvas.width);
    const thumb = document.createElement("canvas");
    thumb.width = Math.round(this.canvas.width * scale);
    thumb.height = Math.round(this.canvas.height * scale);
    const context = thumb.getContext("2d", { alpha: false });
    if (!context) return Promise.resolve(undefined);
    context.imageSmoothingQuality = "high";
    context.drawImage(this.canvas, 0, 0, thumb.width, thumb.height);
    return new Promise((resolve) => thumb.toBlob((blob) => resolve(blob ?? undefined), "image/jpeg", 0.85));
  }

  async finalize(): Promise<void> {
    if (this.finished) return;
    this.finished = true;
    if (this.hasFrame) await this.output.finalize();
    else await this.output.cancel();
  }

  async cancel(): Promise<void> {
    if (this.finished) return;
    this.finished = true;
    await this.output.cancel();
  }

  private async encodeSlot(): Promise<void> {
    await this.source.add(this.nextSlot / OUTPUT_FPS, 1 / OUTPUT_FPS);
    this.nextSlot += 1;
  }

  private draw(image: CanvasImageSource, sourceWidth: number, sourceHeight: number): void {
    const { width: cw, height: ch } = this.canvas;
    const scale = Math.min(cw / sourceWidth, ch / sourceHeight);
    const width = Math.round(sourceWidth * scale);
    const height = Math.round(sourceHeight * scale);
    this.context.fillStyle = "#000";
    this.context.fillRect(0, 0, cw, ch);
    this.context.imageSmoothingEnabled = scale !== 1;
    if (scale !== 1) this.context.imageSmoothingQuality = "high";
    this.context.drawImage(image, Math.floor((cw - width) / 2), Math.floor((ch - height) / 2), width, height);
  }
}

export function formatBytes(bytes: number): string {
  if (bytes < 1_000_000) return `${Math.max(1, Math.round(bytes / 1000))} KB`;
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(bytes < 10_000_000 ? 1 : 0)} MB`;
  return `${(bytes / 1_000_000_000).toFixed(2)} GB`;
}

export function formatSpeedSummary(speed: number): string {
  const seconds = videoSecondsPerHour(speed);
  const length = seconds >= 60 ? `${Math.round(seconds / 6) / 10} min` : `${Math.round(seconds)} sec`;
  return `1 hr → ${length.replace(".0 ", " ")}`;
}
