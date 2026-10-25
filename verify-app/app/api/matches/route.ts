import { NextRequest } from "next/server";
import { getMatches } from "@/lib/recon";
import { handle } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const q = req.nextUrl.searchParams;
  const opt = (k: string) => q.get(k)?.trim() || undefined;
  return handle(() =>
    getMatches({
      acct: opt("acct"), category: opt("category"), status: opt("status"), confidence: opt("confidence"), rule: opt("rule"), amount: opt("amount"),
      offset: Number(q.get("offset") ?? 0) || 0, pageSize: Number(q.get("pageSize") ?? 50) || 50,
    }),
  );
}
