import { useCallback, useEffect, useRef, useState } from "react";
import { Pause, Play } from "../icons";
import type { CaptureTarget, SourceType, TimelapseSession } from "../types";
import { addFrame } from "../db";
import { formatClock } from "../utils";
import { Button } from "../components/Button";
import { acquireCaptureStream, captureNativeFrame, captureNativeVideoFrame, capturePermissionError } from "../capture";
import { OUTPUT_FPS, VideoTimelapseRecorder, formatBytes } from "../video";

/** How often video mode writes progress (stats + thumbnail) to the session. */
const VIDEO_CHECKPOINT_MS = 5000;

interface Props {
  session: TimelapseSession;
  target: CaptureTarget;
  onReplaceTarget: (target: CaptureTarget) => void;
  onUpdate: (session: TimelapseSession) => Promise<void>;
  onComplete: (session: TimelapseSession) => void;
}

function canvasBlob(canvas: HTMLCanvasElement, sourceType: SourceType): Promise<Blob> {
  // Screen captures need lossless edges so small text survives the later video
  // encode. Photographic camera frames remain WebP to avoid enormous PNGs.
  const mimeType = sourceType === "screen" ? "image/png" : "image/webp";
  return new Promise((resolve, reject) => canvas.toBlob(
    (blob) => blob ? resolve(blob) : reject(new Error("Could not encode screenshot")),
    mimeType,
    sourceType === "camera" ? 1 : undefined,
  ));
}

function formatVideoLength(seconds: number): string {
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

export function RecordPage({ session: initialSession, target, onReplaceTarget, onUpdate, onComplete }: Props) {
  const [session, setSession] = useState(initialSession);
  const [displaySeconds, setDisplaySeconds] = useState(initialSession.trackedSeconds);
  const [latestUrl, setLatestUrl] = useState<string>();
  const [captureError, setCaptureError] = useState<string>();
  const [naming, setNaming] = useState(false);
  const [name, setName] = useState(initialSession.name);
  const [stopping, setStopping] = useState(false);
  const [reconnecting, setReconnecting] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const sessionRef = useRef(session);
  const displaySecondsRef = useRef(displaySeconds);
  const latestUrlRef = useRef<string | undefined>(undefined);
  const captureInFlightRef = useRef(false);
  const isCapturing = session.status === "recording";
  const isVideo = session.mode === "video";
  const speed = session.speed ?? 60;
  const recorderRef = useRef<Promise<VideoTimelapseRecorder> | undefined>(undefined);
  // Millisecond-accurate recording clock (pauses excluded) for frame timing.
  const activeBaseMsRef = useRef(initialSession.trackedSeconds * 1000);
  const resumedAtRef = useRef<number | undefined>(initialSession.status === "recording" ? performance.now() : undefined);
  const lastCheckpointRef = useRef(0);
  const activeMs = () => activeBaseMsRef.current + (resumedAtRef.current === undefined ? 0 : performance.now() - resumedAtRef.current);
  sessionRef.current = session;
  displaySecondsRef.current = displaySeconds;

  const update = useCallback(async (next: TimelapseSession) => {
    // Keep the frame clock in step with every recording/paused transition.
    const wasRecording = sessionRef.current.status === "recording";
    const nowRecording = next.status === "recording";
    if (wasRecording && !nowRecording && resumedAtRef.current !== undefined) {
      activeBaseMsRef.current += performance.now() - resumedAtRef.current;
      resumedAtRef.current = undefined;
    } else if (!wasRecording && nowRecording) {
      resumedAtRef.current = performance.now();
    }
    sessionRef.current = next;
    setSession(next);
    await onUpdate(next);
  }, [onUpdate]);

  const checkpointVideo = useCallback(async (recorder: VideoTimelapseRecorder, final = false) => {
    const thumbnail = await recorder.thumbnail();
    if (thumbnail) {
      const previous = latestUrlRef.current;
      const url = URL.createObjectURL(thumbnail);
      latestUrlRef.current = url;
      setLatestUrl(url);
      if (previous) URL.revokeObjectURL(previous);
    }
    const next: TimelapseSession = {
      ...sessionRef.current,
      screenshotCount: recorder.frames,
      videoBytes: recorder.bytes,
      videoSeconds: recorder.videoSeconds,
      videoCodec: recorder.plan.codec,
      videoWidth: recorder.plan.width,
      videoHeight: recorder.plan.height,
      videoBitrate: recorder.plan.bitrate,
      thumbnail: thumbnail ?? sessionRef.current.thumbnail,
    };
    if (final) return next;
    await update(next);
    return next;
  }, [update]);

  const captureVideoFrame = useCallback(async () => {
    const video = videoRef.current;
    if (sessionRef.current.status !== "recording" || captureInFlightRef.current) return;
    if (target.kind === "media" && (!video || !video.videoWidth)) return;
    captureInFlightRef.current = true;
    let bitmap: ImageBitmap | undefined;
    try {
      const at = activeMs() / 1000;
      if (target.kind === "native") bitmap = await createImageBitmap(await captureNativeVideoFrame(target.source));
      const image = bitmap ?? video!;
      const width = bitmap ? bitmap.width : video!.videoWidth;
      const height = bitmap ? bitmap.height : video!.videoHeight;
      // The encoder is sized from the first frame; later frames that change
      // size (window resized, stream reconnected) are letterboxed into it.
      recorderRef.current ??= VideoTimelapseRecorder.create({
        sessionId: sessionRef.current.id,
        width,
        height,
        speed,
        contentHint: sessionRef.current.sourceType === "screen" ? "detail" : "motion",
      });
      const recorder = await recorderRef.current.catch((reason) => { recorderRef.current = undefined; throw reason; });
      await recorder.addFrame(image, width, height, at);
      const now = performance.now();
      if (!lastCheckpointRef.current || now - lastCheckpointRef.current >= VIDEO_CHECKPOINT_MS) {
        lastCheckpointRef.current = now;
        await checkpointVideo(recorder);
      }
      setCaptureError(undefined);
    } catch (reason) {
      setCaptureError(typeof reason === "string" ? reason : reason instanceof Error ? reason.message : "A video frame could not be recorded.");
    } finally {
      bitmap?.close();
      captureInFlightRef.current = false;
    }
  }, [target, speed, checkpointVideo]);

  const captureScreenshot = useCallback(async () => {
    const video = videoRef.current;
    if (sessionRef.current.status !== "recording" || captureInFlightRef.current) return;
    if (target.kind === "media" && (!video || !video.videoWidth)) return;
    captureInFlightRef.current = true;
    try {
      let blob: Blob;
      if (target.kind === "native") {
        blob = await captureNativeFrame(target.source);
      } else {
        const canvas = document.createElement("canvas");
        canvas.width = video!.videoWidth;
        canvas.height = video!.videoHeight;
        const context = canvas.getContext("2d", { alpha: false });
        if (!context) throw new Error("Canvas is unavailable");
        context.drawImage(video!, 0, 0, canvas.width, canvas.height);
        blob = await canvasBlob(canvas, sessionRef.current.sourceType);
      }
      await addFrame({ sessionId: sessionRef.current.id, capturedAt: Date.now(), blob });
      const previous = latestUrlRef.current;
      const url = URL.createObjectURL(blob);
      latestUrlRef.current = url;
      setLatestUrl(url);
      if (previous) URL.revokeObjectURL(previous);
      const next = { ...sessionRef.current, screenshotCount: sessionRef.current.screenshotCount + 1, thumbnail: blob };
      await update(next);
      setCaptureError(undefined);
    } catch (reason) {
      setCaptureError(typeof reason === "string" ? reason : reason instanceof Error ? reason.message : "A screenshot could not be saved.");
    } finally {
      captureInFlightRef.current = false;
    }
  }, [target, update]);

  const captureFrame = isVideo ? captureVideoFrame : captureScreenshot;
  const captureIntervalMs = isVideo ? Math.max(1000 / OUTPUT_FPS, (speed * 1000) / OUTPUT_FPS) : session.intervalSeconds * 1000;

  useEffect(() => {
    if (target.kind !== "media") return;
    const video = videoRef.current;
    if (!video) return;
    video.srcObject = target.stream;
    void video.play();
    const ready = () => {
      // Keep WebKit's video sink at its native dimensions. Rendering the only
      // sink as a 1x1 element can trigger adaptive downscaling before capture.
      video.width = video.videoWidth;
      video.height = video.videoHeight;
      void captureFrame();
    };
    video.addEventListener("loadeddata", ready, { once: true });
    return () => video.removeEventListener("loadeddata", ready);
  }, [target, captureFrame]);

  useEffect(() => {
    if (target.kind === "native") void captureFrame();
  }, [target, captureFrame]);

  useEffect(() => {
    if (!isCapturing) return;
    const timer = window.setInterval(() => void captureFrame(), captureIntervalMs);
    return () => window.clearInterval(timer);
  }, [isCapturing, captureIntervalMs, captureFrame]);

  useEffect(() => {
    if (!isCapturing) return;
    const startedAt = Date.now();
    const base = session.trackedSeconds;
    const timer = window.setInterval(() => setDisplaySeconds(base + Math.floor((Date.now() - startedAt) / 1000)), 250);
    return () => window.clearInterval(timer);
  }, [isCapturing, session.trackedSeconds]);

  useEffect(() => {
    if (target.kind !== "media") return;
    const track = target.stream.getVideoTracks()[0];
    const ended = () => {
      if (sessionRef.current.status === "complete") return;
      const next = { ...sessionRef.current, status: "paused" as const, trackedSeconds: displaySecondsRef.current };
      void update(next);
      setCaptureError("Sharing ended. Select Resume to reconnect this timelapse to a capture source.");
    };
    if (!track) return;
    track.addEventListener("ended", ended);
    return () => track.removeEventListener("ended", ended);
  }, [target, update]);

  useEffect(() => () => {
    if (latestUrlRef.current) URL.revokeObjectURL(latestUrlRef.current);
    // Leaving without Stop (e.g. the session was deleted) abandons the encode.
    void recorderRef.current?.then((recorder) => recorder.cancel()).catch(() => undefined);
  }, []);

  const pause = async () => {
    await update({ ...sessionRef.current, status: "paused", trackedSeconds: displaySeconds });
  };
  const resume = async () => {
    if (target.kind === "native") {
      setCaptureError(undefined);
      await update({ ...sessionRef.current, status: "recording", trackedSeconds: displaySecondsRef.current });
      return;
    }
    const track = target.stream.getVideoTracks()[0];
    if (!track || track.readyState === "ended") {
      setReconnecting(true);
      setCaptureError(undefined);
      try {
        const replacement = await acquireCaptureStream(sessionRef.current.sourceType, isVideo ? OUTPUT_FPS / speed : undefined);
        const replacementTrack = replacement.getVideoTracks()[0];
        onReplaceTarget({ kind: "media", stream: replacement });
        await update({
          ...sessionRef.current,
          status: "recording",
          trackedSeconds: displaySecondsRef.current,
          sourceLabel: replacementTrack.label || sessionRef.current.sourceLabel,
        });
      } catch (reason) {
        setCaptureError(capturePermissionError(reason, "resume capture"));
      } finally {
        setReconnecting(false);
      }
      return;
    }
    setCaptureError(undefined);
    await update({ ...sessionRef.current, status: "recording", trackedSeconds: displaySecondsRef.current });
  };
  const finish = async () => {
    setStopping(true);
    let base = sessionRef.current;
    const pending = recorderRef.current;
    if (pending) {
      try {
        const recorder = await pending;
        // Stop sampling first so no frame races the final fragment.
        await update({ ...base, status: "paused", trackedSeconds: displaySecondsRef.current });
        while (captureInFlightRef.current) await new Promise((resolve) => window.setTimeout(resolve, 20));
        await recorder.finalize();
        base = await checkpointVideo(recorder, true);
        recorderRef.current = undefined;
      } catch (reason) {
        setCaptureError(reason instanceof Error ? `Could not finish the video: ${reason.message}` : "Could not finish the video.");
      }
    }
    const next = { ...base, name: name.trim() || "Untitled Timelapse", status: "complete" as const, trackedSeconds: displaySecondsRef.current, endedAt: Date.now() };
    await update(next);
    if (target.kind === "media") target.stream.getTracks().forEach((track) => track.stop());
    onComplete(next);
  };

  return (
    <main className="page recorder-page">
      {target.kind === "media" && <video ref={videoRef} autoPlay muted playsInline className="capture-video" />}
      <div className="recorder-shell">
        <section className="record-status-card">
          <div className="timer-group">
            {isCapturing ? <span className="record-dot" /> : <Pause width={13} />}
            <strong>{formatClock(displaySeconds)}</strong>
          </div>
          {isVideo ? (
            <span>{speed}× · {formatVideoLength(session.videoSeconds ?? 0)} video · {formatBytes(session.videoBytes ?? 0)}</span>
          ) : (
            <span>{session.screenshotCount} {session.screenshotCount === 1 ? "screenshot" : "screenshots"}</span>
          )}
        </section>

        <section className="live-preview">
          {latestUrl ? <img src={latestUrl} alt="Latest screenshot" /> : <div className="waiting-preview"><span className="spinner" /><p>Preparing your first capture…</p></div>}
          <span className="preview-label">{latestUrl ? (isVideo ? "Recording video" : "Latest capture") : "Live preview"}</span>
          <span className="local-chip">LOCAL</span>
        </section>

        <div className="recorder-source"><span>{session.sourceLabel}</span><small>{isVideo ? `Video · ${speed}× speed` : `Every ${session.intervalSeconds}s`}</small></div>
        {captureError && <div className="error-banner">{captureError}</div>}
        <div className="record-controls">
          {isCapturing ? (
            <Button variant="warning" size="lg" full onClick={pause} icon={<Pause width={15} />}>Pause</Button>
          ) : (
            <Button variant="success" size="lg" full onClick={resume} loading={reconnecting} icon={<Play width={15} />}>{reconnecting ? "Reconnecting" : "Resume"}</Button>
          )}
          <Button variant="danger" size="lg" full onClick={() => setNaming(true)}>Stop</Button>
        </div>
      </div>

      {naming && (
        <div className="naming-backdrop">
          <div className="naming-card">
            <h3>Name your timelapse</h3>
            <p>Give it a name, or skip to use the default.</p>
            <input
              autoFocus
              value={name}
              placeholder="My timelapse"
              maxLength={255}
              disabled={stopping}
              onChange={(event) => setName(event.target.value)}
              onKeyDown={(event) => event.key === "Enter" && void finish()}
            />
            <div className="naming-actions">
              <Button variant="primary" size="lg" full onClick={finish} loading={stopping}>Save &amp; Stop</Button>
              <Button variant="success" size="lg" full onClick={() => setNaming(false)} disabled={stopping}>Resume</Button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}
