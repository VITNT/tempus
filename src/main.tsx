import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

if (/Mac|iPhone|iPad/i.test(`${navigator.platform} ${navigator.userAgent}`)) {
  document.body.classList.add("os-macos");
}

createRoot(document.getElementById("root")!).render(<App />);
