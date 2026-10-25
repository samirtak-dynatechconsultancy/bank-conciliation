import "./globals.css";
import type { ReactNode } from "react";

export const metadata = {
  title: "Recon Verify",
  description: "Verify bank reconciliation matches against the JDE source data",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
