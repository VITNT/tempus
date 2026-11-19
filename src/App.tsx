import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { deleteSession, getSessions, putSession } from "./db";
import type { CaptureMode, CaptureTarget, Page, SourceType, TimelapseSession } from "./types";
import { DEFAULT_SPEED, SPEED_OPTIONS } from "./video";

function readStored(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function writeStored(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* preference only */ }
}
import { GalleryPage } from "./pages/GalleryPage";
import { SourcePage } from "./pages/SourcePage";
import { RecordPage } from "./pages/RecordPage";
import { DetailPage } from "./pages/DetailPage";
import { SettingsPage } from "./pages/SettingsPage";
import { Modal } from "./components/Modal";

export function App() {
  const [page, setPage] = useState<Page>({ name: "gallery" });
  const [sessions, setSessions] = useState<TimelapseSession[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<TimelapseSession>();
  const [intervalSeconds, setIntervalSeconds] = useState(() => Number(localStorage.getItem("tempus-interval")) || 60);
  const [mode, setMode] = useState<CaptureMode>(() => readStored("tempus-mode") === "video" ? "video" : "screenshots");
  const [speed, setSpeed] = useState(() => {
    const stored = Number(readStored("tempus-speed"));
    return (SPEED_OPTIONS as readonly number[]).includes(stored) ? stored : DEFAULT_SPEED;
  });
  const [activeCapture, setActiveCapture] = useState<{ id: string; target: CaptureTarget }>();
  const activeCaptureRef = useRef(activeCapture);
  activeCaptureRef.current = activeCapture;

  const refresh = useCallback(async () => setSessions(await getSessions()), []);
  useEffect(() => {
    void (async () => {
      const stored = await getSessions();
      const recovered = await Promise.all(stored.map(async (session) => {
        if (session.status === "complete") return session;
        const next = { ...session, status: "complete" as const, endedAt: session.endedAt || Date.now() };
        await putSession(next);
        return next;
      }));
      setSessions(recovered);
      setLoaded(true);
    })();
  }, []);

  const updateSession = useCallback(async (next: TimelapseSession) => {
    await putSession(next);
    setSessions((current) => [next, ...current.filter((item) => item.id !== next.id)].sort((a, b) => b.createdAt - a.createdAt));
  }, []);

  const startSession = async (target: CaptureTarget, sourceType: SourceType, sourceLabel: string) => {
    const id = crypto.randomUUID();
    const session: TimelapseSession = {
      id,
      name: `Timelapse ${new Date().toLocaleDateString(undefined, { month: "short", day: "numeric" })}`,
      createdAt: Date.now(),
      status: "recording",
      sourceType,
      sourceLabel,
      intervalSeconds,
      trackedSeconds: 0,
      screenshotCount: 0,
      mode,
      ...(mode === "video" ? { speed, videoBytes: 0, videoSeconds: 0 } : {}),
    };
    setActiveCapture({ id, target });
    await updateSession(session);
    setPage({ name: "record", id });
  };

  const selectedSession = page.name === "record" || page.name === "detail" ? sessions.find((session) => session.id === page.id) : undefined;
  const changeInterval = (value: number) => {
    setIntervalSeconds(value);
    localStorage.setItem("tempus-interval", String(value));
  };
  const changeMode = (value: CaptureMode) => {
    setMode(value);
    writeStored("tempus-mode", value);
  };
  const changeSpeed = (value: number) => {
    setSpeed(value);
    writeStored("tempus-speed", String(value));
  };
  const confirmDelete = async () => {
    if (!deleteTarget) return;
    if (activeCaptureRef.current?.id === deleteTarget.id) {
      const target = activeCaptureRef.current.target;
      if (target.kind === "media") target.stream.getTracks().forEach((track) => track.stop());
      setActiveCapture(undefined);
    }
    await deleteSession(deleteTarget.id);
    setDeleteTarget(undefined);
    await refresh();
    setPage({ name: "gallery" });
  };

  let content: ReactNode;
  if (!loaded) {
    content = <div className="app-loading"><span className="spinner" /><span>Opening Tempus…</span></div>;
  } else if (page.name === "gallery") {
    content = <GalleryPage sessions={sessions} onAdd={() => setPage({ name: "source" })} onSettings={() => setPage({ name: "settings" })} onOpen={(session) => setPage({ name: "detail", id: session.id })} onDelete={setDeleteTarget} />;
  } else if (page.name === "source") {
    content = <SourcePage intervalSeconds={intervalSeconds} mode={mode} speed={speed} onMode={changeMode} onSpeed={changeSpeed} onBack={() => setPage({ name: "gallery" })} onStart={startSession} />;
  } else if (page.name === "settings") {
    content = <SettingsPage intervalSeconds={intervalSeconds} onInterval={changeInterval} onBack={() => setPage({ name: "gallery" })} />;
  } else if (page.name === "record" && selectedSession && activeCapture?.id === page.id) {
    content = <RecordPage session={selectedSession} target={activeCapture.target} onReplaceTarget={(target) => setActiveCapture({ id: page.id, target })} onUpdate={updateSession} onComplete={(session) => { setActiveCapture(undefined); setPage({ name: "detail", id: session.id }); }} />;
  } else if (selectedSession) {
    content = <DetailPage session={selectedSession} onBack={() => setPage({ name: "gallery" })} onDelete={() => setDeleteTarget(selectedSession)} />;
  } else {
    content = <GalleryPage sessions={sessions} onAdd={() => setPage({ name: "source" })} onSettings={() => setPage({ name: "settings" })} onOpen={(session) => setPage({ name: "detail", id: session.id })} onDelete={setDeleteTarget} />;
  }

  return (
    <div className="app-shell">
      <div className="window-drag-region" data-tauri-drag-region aria-hidden="true" />
      <div className="page-transition" key={page.name}>{content}</div>
      {deleteTarget && (
        <Modal title="Delete timelapse?" confirmLabel="Delete" confirmVariant="danger" onConfirm={confirmDelete} onCancel={() => setDeleteTarget(undefined)}>
          <p>This permanently removes “{deleteTarget.name}” and its {deleteTarget.mode === "video" ? "recorded video" : `${deleteTarget.screenshotCount} local screenshots`}.</p>
        </Modal>
      )}
    </div>
  );
}
