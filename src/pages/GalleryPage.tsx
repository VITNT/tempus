import { useEffect, useMemo } from "react";
import { Gear, Monitor, Plus, X } from "../icons";
import type { TimelapseSession } from "../types";
import { blobUrl, formatTracked } from "../utils";
import { Button } from "../components/Button";

interface Props {
  sessions: TimelapseSession[];
  onAdd: () => void;
  onSettings: () => void;
  onOpen: (session: TimelapseSession) => void;
  onDelete: (session: TimelapseSession) => void;
}

function SessionCard({ session, onOpen, onDelete }: { session: TimelapseSession; onOpen: () => void; onDelete: () => void }) {
  const thumbnail = useMemo(() => blobUrl(session.thumbnail), [session.thumbnail]);
  useEffect(() => () => { if (thumbnail) URL.revokeObjectURL(thumbnail); }, [thumbnail]);
  const date = new Date(session.createdAt).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  const status = session.status === "recording" ? "Recording" : session.status === "paused" ? "Paused" : "Complete";

  return (
    <div className="session-card" role="button" tabIndex={0} onClick={onOpen} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") onOpen(); }}>
      <div className="thumbnail">
        {thumbnail ? <img src={thumbnail} alt="Timelapse thumbnail" /> : <Monitor width={34} height={34} />}
        <span className={`status-badge ${session.status}`}>{status}</span>
        <button className="archive-button" title="Delete timelapse" onClick={(event) => { event.stopPropagation(); onDelete(); }}><X width={14} /></button>
      </div>
      <div className="session-info">
        <strong>{session.name}</strong>
        <span>{formatTracked(session.trackedSeconds)}{session.mode === "video" ? ` · ${session.speed ?? 60}× video` : ""} · {date}</span>
      </div>
    </div>
  );
}

export function GalleryPage({ sessions, onAdd, onSettings, onOpen, onDelete }: Props) {
  return (
    <main className="page gallery-page">
      <header className="gallery-header" data-tauri-drag-region>
        <h1>Your Timelapses</h1>
        <div className="header-actions">
          <Button variant="ghost" className="icon-button" title="Settings" aria-label="Settings" onClick={onSettings}><Gear width={25} height={25} /></Button>
          <Button variant="ghost" className="icon-button" title="Start a timelapse" aria-label="Start a timelapse" onClick={onAdd}><Plus width={27} height={27} /></Button>
        </div>
      </header>

      {sessions.length === 0 ? (
        <section className="empty-state">
          <Monitor width={48} height={48} className="empty-monitor" />
          <h2>No timelapses yet</h2>
          <p>Start a recording session to see it here.</p>
        </section>
      ) : (
        <section className="session-grid">
          {sessions.map((session) => <SessionCard key={session.id} session={session} onOpen={() => onOpen(session)} onDelete={() => onDelete(session)} />)}
        </section>
      )}
    </main>
  );
}
