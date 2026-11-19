import { Header } from "../components/Header";

interface Props {
  intervalSeconds: number;
  onInterval: (value: number) => void;
  onBack: () => void;
}

const options = [5, 15, 30, 60, 120];

export function SettingsPage({ intervalSeconds, onInterval, onBack }: Props) {
  return (
    <main className="page settings-page">
      <Header title="Settings" onBack={onBack} />
      <section className="settings-content">
        <div className="settings-group">
          <label htmlFor="capture-frequency">Capture frequency</label>
          <p>How often Tempus saves a screenshot while recording.</p>
          <select id="capture-frequency" value={intervalSeconds} onChange={(event) => onInterval(Number(event.target.value))}>
            {options.map((seconds) => <option value={seconds} key={seconds}>Every {seconds < 60 ? `${seconds} seconds` : `${seconds / 60} ${seconds === 60 ? "minute" : "minutes"}`}</option>)}
          </select>
        </div>
        <div className="privacy-card">
          <span className="privacy-dot" />
          <div><strong>Local-only by design</strong><p>Frames are stored in this app’s local database. Tempus has no server, account, analytics, or upload endpoint.</p></div>
        </div>
        <div className="settings-group about">
          <label>About Tempus</label>
          <p>Standalone screenshot timelapses, inspired by Hack Club Lookout. Unlike Lookout, Tempus creates and owns its sessions directly.</p>
          <span>Version 0.1.0</span>
        </div>
      </section>
    </main>
  );
}
