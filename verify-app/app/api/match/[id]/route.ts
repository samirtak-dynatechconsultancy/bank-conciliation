import { bankKeyOf, bankSource, checkMatch, getCandidates, getMatch, glKeyOf, glSource } from "@/lib/recon";
import { handle } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** One match: warehouse header + lines, the same lines read from the lakehouse, and the automatic checks.
 *  MEDIUM matches also return their possible matches (equally valid partners), each checked against the lakehouse. */
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  return handle(async () => {
    const { id } = await params;   // Next.js 15: route params are async
    const { header, lines } = await getMatch(id);
    if (!header) return { error: "Match not found" };
    const [bankRows, glRows, candidates] = await Promise.all([
      bankSource(lines.filter((l) => l.side === "BANK").map(bankKeyOf)),
      glSource(lines.filter((l) => l.side === "GL").map(glKeyOf)),
      header.confidence === "MEDIUM" ? getCandidates(id) : Promise.resolve([]),
    ]);

    // the alternatives' source rows (the proposed line is already in bankRows / glRows)
    const alt = candidates.filter((c) => !c.is_proposed);
    const [altBank, altGl] = await Promise.all([
      bankSource(alt.filter((c) => c.side === "BANK").map(bankKeyOf)),
      glSource(alt.filter((c) => c.side === "GL").map(glKeyOf)),
    ]);
    const source = new Map<string, Record<string, unknown>>(
      [...bankRows, ...glRows, ...altBank, ...altGl].map((r) => [String(r.line_id), r]),
    );
    const possibleMatches = candidates.map((c) => {
      const src = source.get(c.line_id);
      const srcR = src ? String(src.reconciliation_code ?? src.reconciled_code ?? "") === "R" : null;
      return {
        ...c,
        in_lakehouse: !!src,
        source_amount: src?.amount ?? null,
        amount_ok: !!src && Number(src.amount) === Number(c.amount),
        source_reconciled: srcR,
      };
    });

    return { header, lines, bankRows, glRows, possibleMatches, checks: checkMatch(header, lines, bankRows, glRows) };
  });
}
