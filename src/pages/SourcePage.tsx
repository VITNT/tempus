import { useEffect, useRef, useState } from "react";
import { Camera, Check, Film, Monitor } from "../icons";
import type { CaptureMode, CaptureTarget, NativeCaptureSource, SourceType } from "../types";
import { OUTPUT_FPS, SPEED_OPTIONS, estimateMegabytesPerHour, formatSpeedSummary, planBitrate } from "../video";
import { Button } from "../components/Button";
import { Header } from "../components/Header";
import { acquireCaptureStream, capturePermissionError, listNativeCaptureSources, supportsNativeCapture } from "../capture";

interface Props {
  intervalSeconds: number;
  mode: CaptureMode;
  speed: number;
  onMode: (mode: CaptureMode) => void;
  onSpeed: (speed: number) => void;
  onBack: () => void;
  onStart: (target: CaptureTarget, type: SourceType, label: string) => void;
}

/** Rough upper bound for the picker; the real plan is chosen at record time. */
function estimateFor(speed: number, width: number, height: number) {
  const { bitrate } = planBitrate("hevc", width, height, speed);
  return estimateMegabytesPerHour(bitrate, speed);
}

export function SourcePage({ intervalSeconds, mode, speed, onMode, onSpeed, onBack, onStart }: Props) {
  const [selected, setSelected] = useState<SourceType>("screen");
  const [nativeSources, setNativeSources] = useState<NativeCaptureSource[]>([]);
  const [selectedNative, setSelectedNative] = useState<NativeCaptureSource>();
  const [loadingSources, setLoadingSources] = useState(supportsNativeCapture());
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; }, []);

  useEffect(() => {
    if (!supportsNativeCapture()) return;
    void listNativeCaptureSources()
      .then((sources) => {
        if (!mounted.current) return;
        setNativeSources(sources);
        setSelectedNative(sources[0]);
      })
      .catch((reason) => {
        if (mounted.current) setError(capturePermissionError(reason, "list capture sources"));
      })
      .finally(() => { if (mounted.current) setLoadingSources(false); });
  }, []);

  const choose = async () => {
    setStarting(true);
    setError(undefined);
    try {
      if (selected === "screen" && selectedNative) {
        onStart({ kind: "native", source: selectedNative }, selected, selectedNative.label);
        return;
      }
      const stream = await acquireCaptureStream(selected, mode === "video" ? OUTPUT_FPS / speed : undefined);
      const track = stream.getVideoTracks()[0];
      onStart({ kind: "media", stream }, selected, track.label || (selected === "screen" ? "Screen or window" : "Camera"));
    } catch (reason) {
      if (!mounted.current) return;
      setError(capturePermissionError(reason));
      setStarting(false);
    }
  };

  const estimateSize = selected === "screen" && selectedNative
    ? { width: selectedNative.width, height: selectedNative.height }
    : selected === "screen" ? { width: 3840, height: 2160 } : { width: 1920, height: 1080 };
  const estimate = estimateFor(speed, estimateSize.width, estimateSize.height);

  return (
    <main className="page source-page">
      <Header title="What should Tempus capture?" onBack={onBack} />
      <section className="source-content">
        <div className="source-tabs mode-tabs" role="tablist" aria-label="Recording mode">
          <button role="tab" aria-selected={mode === "screenshots"} className={mode === "screenshots" ? "active" : ""} onClick={() => onMode("screenshots")}><Monitor width={17} /> Screenshots</button>
          <button role="tab" aria-selected={mode === "video"} className={mode === "video" ? "active" : ""} onClick={() => onMode("video")}><Film width={17} /> Video</button>
        </div>

        <div className={`source-preview ${mode === "video" ? "compact" : ""}`}>
          <div className="preview-orbit one" />
          <div className="preview-orbit two" />
          {selected === "screen" ? <Monitor width={65} height={65} /> : <Camera width={65} height={65} />}
          <span>{selected === "screen" && nativeSources.length ? "Native full-resolution capture" : selected === "screen" ? "Your picker opens next" : "Camera permission opens next"}</span>
        </div>

        <div className="source-tabs" role="tablist">
          <button className={selected === "screen" ? "active" : ""} onClick={() => setSelected("screen")}><Monitor width={17} /> Screens & windows</button>
          <button className={selected === "camera" ? "active" : ""} onClick={() => setSelected("camera")}><Camera width={17} /> Cameras</button>
        </div>

        {selected === "screen" && nativeSources.length ? (
          <div className="native-source-list" aria-label="Available screens and windows">
            {nativeSources.map((source) => (
              <button
                key={`${source.type}-${source.id}`}
                className={`source-row ${selectedNative?.type === source.type && selectedNative.id === source.id ? "selected" : ""}`}
                onClick={() => setSelectedNative(source)}
              >
                <span className="source-row-icon"><Monitor /></span>
                <span><strong>{source.label}</strong><small>{source.type === "monitor" ? "Display" : "Window"} · {source.width}×{source.height}</small></span>
                {selectedNative?.type === source.type && selectedNative.id === source.id && <Check />}
              </button>
            ))}
          </div>
        ) : selected === "screen" ? (
          <button className="source-row selected" disabled={loadingSources} onClick={() => setSelected("screen")}>
            <span className="source-row-icon"><Monitor /></span><span><strong>{loadingSources ? "Finding screens and windows…" : "Screen or window"}</strong><small>{loadingSources ? "Using native desktop capture" : "Choose from the system picker"}</small></span>{!loadingSources && <Check />}
          </button>
        ) : (
          <button className="source-row selected" onClick={() => setSelected("camera")}>
            <span className="source-row-icon"><Camera /></span><span><strong>Camera</strong><small>Record a visual build or workspace</small></span><Check />
          </button>
        )}

        {mode === "video" && (
          <div className="speed-picker" role="radiogroup" aria-label="Playback speed">
            {SPEED_OPTIONS.map((option) => (
              <button key={option} role="radio" aria-checked={speed === option} className={speed === option ? "active" : ""} onClick={() => onSpeed(option)}>
                <strong>{option}×</strong>
                <small>{formatSpeedSummary(option).replace("1 hr → ", "")}</small>
              </button>
            ))}
          </div>
        )}

        {error && <div className="error-banner">{error}</div>}
        <div className="capture-note">
          {mode === "video"
            ? <>Records a {speed}× video ({formatSpeedSummary(speed)}) · up to ~{Math.round(estimate)} MB per hour</>
            : <>A screenshot is saved locally every {intervalSeconds} seconds.</>}
        </div>
        <Button variant="primary" size="lg" full loading={starting || loadingSources} disabled={selected === "screen" && loadingSources} onClick={choose}>Choose {selected === "screen" ? "screen or window" : "camera"}</Button>
      </section>
    </main>
  );
}
