import { NextRequest, NextResponse } from "next/server";

/**
 * HTTP Basic auth on every page and API route. Fails CLOSED: if APP_USERNAME / APP_PASSWORD
 * are not configured, nobody gets in. (Can be replaced later by Entra ID sign-in.)
 */
export function middleware(req: NextRequest) {
  const user = process.env.APP_USERNAME;
  const pass = process.env.APP_PASSWORD;
  if (!user || !pass) {
    return new NextResponse("Access is not configured (APP_USERNAME / APP_PASSWORD).", { status: 503 });
  }
  const header = req.headers.get("authorization") ?? "";
  if (header.startsWith("Basic ")) {
    const decoded = atob(header.slice(6));
    const sep = decoded.indexOf(":");
    if (sep > 0 && safeEqual(decoded.slice(0, sep), user) && safeEqual(decoded.slice(sep + 1), pass)) {
      return NextResponse.next();
    }
  }
  return new NextResponse("Authentication required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Bank Reconciliation Verify", charset="UTF-8"' },
  });
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const config = { matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"] };
