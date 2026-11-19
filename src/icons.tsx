import type { SVGProps } from "react";

type Props = SVGProps<SVGSVGElement>;
const base = { width: 20, height: 20, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };

export const ArrowLeft = (p: Props) => <svg {...base} {...p}><path d="m15 18-6-6 6-6" /></svg>;
export const Camera = (p: Props) => <svg {...base} {...p}><path d="M14.5 4 16 7h3a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h3l1.5-3h5Z" /><circle cx="12" cy="13" r="3" /></svg>;
export const Check = (p: Props) => <svg {...base} {...p}><path d="m20 6-11 11-5-5" /></svg>;
export const Download = (p: Props) => <svg {...base} {...p}><path d="M12 3v12m0 0 4-4m-4 4-4-4M4 19h16" /></svg>;
export const Film = (p: Props) => <svg {...base} {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M7 4v16M17 4v16M3 9h4m10 0h4M3 15h4m10 0h4" /></svg>;
export const Gear = (p: Props) => <svg {...base} {...p}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-4v-.09A1.7 1.7 0 0 0 9 19.37a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.63 15 1.7 1.7 0 0 0 3.09 14H3v-4h.09A1.7 1.7 0 0 0 4.63 9a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.63h.01A1.7 1.7 0 0 0 10 3.09V3h4v.09A1.7 1.7 0 0 0 15 4.63a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.37 9v.01A1.7 1.7 0 0 0 20.91 10H21v4h-.09A1.7 1.7 0 0 0 19.4 15Z" /></svg>;
export const Monitor = (p: Props) => <svg {...base} {...p}><rect x="2" y="3" width="20" height="14" rx="2" /><path d="M8 21h8m-4-4v4" /></svg>;
export const Pause = (p: Props) => <svg {...base} {...p} fill="currentColor" stroke="none"><rect x="6" y="4" width="4" height="16" rx="1" /><rect x="14" y="4" width="4" height="16" rx="1" /></svg>;
export const Play = (p: Props) => <svg {...base} {...p} fill="currentColor" stroke="none"><path d="m7 4 13 8-13 8V4Z" /></svg>;
export const Plus = (p: Props) => <svg {...base} {...p}><path d="M12 5v14M5 12h14" /></svg>;
export const Trash = (p: Props) => <svg {...base} {...p}><path d="M4 7h16M10 11v6m4-6v6M9 4h6l1 3H8l1-3Zm-3 3 1 14h10l1-14" /></svg>;
export const X = (p: Props) => <svg {...base} {...p}><path d="m6 6 12 12M18 6 6 18" /></svg>;
