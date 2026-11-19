import { ArrowLeft } from "../icons";
import { Button } from "./Button";
import type { ReactNode } from "react";

interface Props {
  title: string;
  onBack?: () => void;
  trailing?: ReactNode;
}

export function Header({ title, onBack, trailing }: Props) {
  return (
    <header className="page-header" data-tauri-drag-region>
      <div className="header-side">
        {onBack && <Button size="sm" onClick={onBack}>{navigator.userAgent.includes("Mac") ? "← Gallery" : <><ArrowLeft width={15} /> Gallery</>}</Button>}
      </div>
      <h1>{title}</h1>
      <div className="header-side end">{trailing}</div>
    </header>
  );
}
