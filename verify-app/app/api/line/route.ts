import { NextRequest } from "next/server";
import { bankSource, findLineInWarehouse, glSourceByLineId, parseLineId } from "@/lib/recon";
import { handle } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** One line_id: where it appears in the warehouse + the source row in the lakehouse. */
export async function GET(req: NextRequest) {
  const id = req.nextUrl.searchParams.get("id")?.trim() ?? "";
  return handle(async () => {
    const parsed = parseLineId(id);
    if (!parsed) return { error: "Not a valid line_id (expected B|… or G|…)" };
    const [warehouse, source] = await Promise.all([
      findLineInWarehouse(id),
      parsed.side === "BANK" ? bankSource([parsed.key]) : glSourceByLineId(parsed.key),
    ]);
    return { side: parsed.side, warehouse, source };
  });
}
