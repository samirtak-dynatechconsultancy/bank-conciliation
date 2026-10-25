import { getAccounts, iso, sourceTotals } from "@/lib/recon";
import { handle } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Per account: line counts in the lakehouse vs what the latest run read (warehouse). */
export async function GET() {
  return handle(async () => {
    const [wh, src] = await Promise.all([getAccounts(), sourceTotals()]);
    const byAcct = new Map(src.map((r) => [String(r.gl_bank_account), r]));
    return wh.map((w) => {
      const s = byAcct.get(String(w.gl_bank_account)) ?? {};
      return {
        gl_bank_account: w.gl_bank_account,
        display_name: w.display_name,
        bank_lines_source: s.bank_lines ?? null,
        bank_lines_run: w.bank_lines ?? null,
        gl_lines_source: s.gl_lines ?? null,
        gl_lines_run: w.gl_lines ?? null,
        period_source: `${iso(s.period_start) ?? "-"} - ${iso(s.period_end) ?? "-"}`,
        period_run: `${iso(w.period_start) ?? "-"} - ${iso(w.period_end) ?? "-"}`,
        bank_ok: s.bank_lines === w.bank_lines,
        gl_ok: s.gl_lines === w.gl_lines,
      };
    });
  });
}
