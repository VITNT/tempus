import type { ButtonHTMLAttributes, ReactNode } from "react";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "warning" | "success";

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: "sm" | "md" | "lg";
  loading?: boolean;
  icon?: ReactNode;
  full?: boolean;
}

export function Button({ variant = "secondary", size = "md", loading, icon, full, className = "", children, ...props }: Props) {
  return (
    <button className={`button ${variant} ${size} ${full ? "full" : ""} ${className}`} disabled={loading || props.disabled} {...props}>
      {loading ? <span className="spinner" /> : icon}
      {children}
    </button>
  );
}
