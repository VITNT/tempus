import type { CapturedFrame, TimelapseSession, VideoChunk } from "./types";

const DB_NAME = "tempus-local";
const DB_VERSION = 2;

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("sessions")) {
        db.createObjectStore("sessions", { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains("frames")) {
        const frames = db.createObjectStore("frames", { keyPath: "id", autoIncrement: true });
        frames.createIndex("sessionId", "sessionId", { unique: false });
      }
      if (!db.objectStoreNames.contains("videoChunks")) {
        const chunks = db.createObjectStore("videoChunks", { keyPath: "id", autoIncrement: true });
        chunks.createIndex("sessionId", "sessionId", { unique: false });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function getSessions(): Promise<TimelapseSession[]> {
  const db = await openDatabase();
  const rows = await requestResult(db.transaction("sessions", "readonly").objectStore("sessions").getAll());
  db.close();
  return (rows as TimelapseSession[]).sort((a, b) => b.createdAt - a.createdAt);
}

export async function getSession(id: string): Promise<TimelapseSession | undefined> {
  const db = await openDatabase();
  const row = await requestResult(db.transaction("sessions", "readonly").objectStore("sessions").get(id));
  db.close();
  return row as TimelapseSession | undefined;
}

export async function putSession(session: TimelapseSession): Promise<void> {
  const db = await openDatabase();
  await requestResult(db.transaction("sessions", "readwrite").objectStore("sessions").put(session));
  db.close();
}

export async function addFrame(frame: CapturedFrame): Promise<number> {
  const db = await openDatabase();
  const id = await requestResult(db.transaction("frames", "readwrite").objectStore("frames").add(frame));
  db.close();
  return Number(id);
}

export async function getFrames(sessionId: string): Promise<CapturedFrame[]> {
  const db = await openDatabase();
  const index = db.transaction("frames", "readonly").objectStore("frames").index("sessionId");
  const rows = await requestResult(index.getAll(IDBKeyRange.only(sessionId)));
  db.close();
  return (rows as CapturedFrame[]).sort((a, b) => a.capturedAt - b.capturedAt);
}

/**
 * Video mode streams fragmented MP4 bytes straight to disk-backed storage, so a
 * long recording never has to sit in memory and survives an unexpected quit.
 */
export async function addVideoChunk(chunk: VideoChunk): Promise<void> {
  const db = await openDatabase();
  await requestResult(db.transaction("videoChunks", "readwrite").objectStore("videoChunks").add(chunk));
  db.close();
}

export async function getVideoBlob(sessionId: string): Promise<Blob | undefined> {
  const db = await openDatabase();
  const index = db.transaction("videoChunks", "readonly").objectStore("videoChunks").index("sessionId");
  const rows = await requestResult(index.getAll(IDBKeyRange.only(sessionId))) as VideoChunk[];
  db.close();
  if (!rows.length) return undefined;
  // Auto-increment keys preserve write order, which fragmented MP4 depends on.
  rows.sort((a, b) => (a.id ?? 0) - (b.id ?? 0));
  return new Blob(rows.map((row) => row.data), { type: "video/mp4" });
}

export async function deleteSession(id: string): Promise<void> {
  const db = await openDatabase();
  const transaction = db.transaction(["sessions", "frames", "videoChunks"], "readwrite");
  transaction.objectStore("sessions").delete(id);
  for (const store of ["frames", "videoChunks"]) {
    const index = transaction.objectStore(store).index("sessionId");
    const keys = await requestResult(index.getAllKeys(IDBKeyRange.only(id)));
    for (const key of keys) transaction.objectStore(store).delete(key);
  }
  await new Promise<void>((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  db.close();
}
