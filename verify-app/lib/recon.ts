import { query, Params } from "./db";

/* =====================================================================================
   Warehouse (results) and Lakehouse (JDE source) queries + the automatic checks.
   Everything is read-only.
   ===================================================================================== */

export const iso = (d: unknown): string | null =>
  d instanceof Date ? d.toISOString().slice(0, 10) : d == null ? null : String(d).slice(0, 10);

const daysBetween = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);

/* ---------------------------------- Warehouse ---------------------------------- */

export async function getAccounts() {
  return query("warehouse", `
    SELECT gl_bank_account, display_name, gl_account_number, last_run_status, last_run_at,
           period_start, period_end, bank_lines, gl_lines, bank_open, gl_open,
           proposed_total, pending_review, confirmed, rejected, exceptions_open, unmatched_bank, unmatched_gl
    FROM dbo.vw_bank_recon_ui_overview
    ORDER BY ISNULL(sort_order, 999), display_name;`);
}

export type MatchFilter = {
  acct?: string; category?: string; status?: string; confidence?: string; rule?: string; amount?: string;
  offset?: number; pageSize?: number;
};

export async function getMatches(f: MatchFilter) {
  const where = `
    WHERE (@acct IS NULL OR p.gl_bank_account = @acct)
      AND (@category IS NULL OR p.match_category = @category)
      AND (@status IS NULL OR p.status = @status)
      AND (@confidence IS NULL OR p.confidence = @confidence)
      AND (@rule IS NULL OR p.match_rule LIKE '%' + @rule + '%')
      AND (@amount IS NULL OR ABS(p.bank_amount) = ABS(TRY_CONVERT(decimal(18,2), @amount)))`;
  const params: Params = {
    acct: f.acct, category: f.category, status: f.status, confidence: f.confidence, rule: f.rule, amount: f.amount,
    offset: f.offset ?? 0, pageSize: Math.min(f.pageSize ?? 50, 200),
  };
  const rows = await query("warehouse", `
    SELECT p.match_id, p.gl_bank_account, p.match_category, p.match_rule, p.confidence, p.recon_state, p.status,
           p.bank_line_count, p.gl_line_count, p.bank_amount, p.gl_amount, p.max_date_gap_days, p.tolerance_days
    FROM dbo.bank_recon_match_proposal p
    JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
    ${where}
    ORDER BY p.match_category DESC, ABS(p.bank_amount) DESC, p.match_id
    OFFSET @offset ROWS FETCH NEXT @pageSize ROWS ONLY;`, params);
  const total = await query<{ n: number }>("warehouse", `
    SELECT COUNT(*) AS n
    FROM dbo.bank_recon_match_proposal p
    JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
    ${where};`, params);
  return { rows, total: total[0]?.n ?? 0 };
}

export type MatchLine = {
  side: "BANK" | "GL"; line_id: string; gl_bank_account: string; txn_date: unknown; amount: number;
  is_reconciled: boolean; bank_statement_id: string | null; statement_date: unknown; line_number: string | null;
  doc_type: string | null; doc_number: string | null; doc_company: string | null; gl_date: unknown;
  je_line_number: string | null; ledger_type: string | null; description: string | null;
};

export async function getMatch(matchId: string) {
  const header = await query("warehouse", `
    SELECT match_id, run_id, gl_bank_account, match_type, match_rule, match_category, confidence, recon_state, status,
           tolerance_days, max_date_gap_days, bank_line_count, gl_line_count, bank_amount, gl_amount, note,
           decided_by, decided_at, export_batch_id, exported_at, created_at
    FROM dbo.bank_recon_match_proposal WHERE match_id = @id;`, { id: matchId });
  const lines = await query<MatchLine>("warehouse", `
    SELECT side, line_id, gl_bank_account, txn_date, amount, is_reconciled, bank_statement_id, statement_date,
           line_number, doc_type, doc_number, doc_company, gl_date, je_line_number, ledger_type, description
    FROM dbo.bank_recon_match_line WHERE match_id = @id ORDER BY side, txn_date;`, { id: matchId });
  return { header: header[0] ?? null, lines };
}

/** Alternative lines of a MEDIUM match (several equally valid partners); is_proposed = the engine's choice. */
export type Candidate = MatchLine & { is_proposed: boolean; gap_days: number; used_in_other_match: number };

export async function getCandidates(matchId: string) {
  return query<Candidate>("warehouse", `
    SELECT side, line_id, is_proposed, gap_days, used_in_other_match, gl_bank_account, txn_date, amount, is_reconciled,
           bank_statement_id, statement_date, line_number, doc_type, doc_number, doc_company, gl_date,
           je_line_number, ledger_type, description
    FROM dbo.vw_bank_recon_ui_exception_candidates
    WHERE match_id = @id
    ORDER BY side, is_proposed DESC, gap_days, txn_date;`, { id: matchId });
}

export async function findLineInWarehouse(lineId: string) {
  return query("warehouse", `
    SELECT 'In a match' AS found_in, l.match_id, p.status AS detail, p.match_rule AS info, p.recon_state AS extra
    FROM dbo.bank_recon_match_line l
    JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
    JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
    WHERE l.line_id = @id
    UNION ALL
    SELECT 'Unmatched (latest run)', NULL, u.side, u.reason, CAST(u.nearest_same_amount_gap_days AS varchar(10))
    FROM dbo.vw_bank_recon_unmatched_latest u WHERE u.line_id = @id
    UNION ALL
    SELECT 'Alternative candidate', c.match_id, CASE WHEN c.is_proposed = 1 THEN 'proposed line' ELSE 'alternative' END,
           CONCAT('gap ', c.gap_days, ' day(s)'), NULL
    FROM dbo.bank_recon_match_candidate c WHERE c.line_id = @id
    UNION ALL
    SELECT 'Reviewer decision', NULL, d.decision, d.comment, CONCAT(d.decided_by, ' / ', CONVERT(varchar(19), d.decided_at, 120))
    FROM dbo.bank_recon_line_decision d WHERE d.line_id = @id AND d.is_active = 1;`, { id: lineId });
}

/* ---------------------------------- Lakehouse ---------------------------------- */

const BANK_SELECT = `
  SELECT CONCAT('B|', CAST(CAST([Bank Statement ID] AS bigint) AS varchar(20)), '|', LTRIM(RTRIM([G_L Bank Account])), '|',
                CONVERT(varchar(10), [Statement Date], 23), '|', CAST(CAST([Line Number _ General] AS bigint) AS varchar(20))) AS line_id,
         LTRIM(RTRIM([G_L Bank Account])) AS gl_bank_account,
         CAST([Bank Statement ID] AS bigint) AS bank_statement_id,
         [Statement Date] AS statement_date,
         CAST([Line Number _ General] AS bigint) AS line_number,
         [Date _ Cleared_Value] AS cleared_date,
         LTRIM(RTRIM([Bank Statement Transaction Code])) AS tr_code,
         [Debits Entered] AS debits_raw, [Credits Entered] AS credits_raw,
         CAST(ROUND((ISNULL([Credits Entered],0) - ISNULL([Debits Entered],0)) / 100.0, 2) AS decimal(18,2)) AS amount,
         LTRIM(RTRIM(ISNULL([Reconciliation Code], ''))) AS reconciliation_code,
         LTRIM(RTRIM([Misc Information])) AS misc_information
  FROM proddta.auto_bank_statement_detail_f09617`;

const GL_SELECT = `
  SELECT CONCAT('G|', LTRIM(RTRIM([Document Type])), '|', CAST(CAST([Document _Voucher Invoice etc] AS bigint) AS varchar(20)), '|',
                LTRIM(RTRIM([Document Company])), '|', CONVERT(varchar(10), CAST([Date For G_L _and Voucher Julian] AS date), 23), '|',
                CAST(CAST([Journal Entry Line Number] AS bigint) AS varchar(20)), '|', LTRIM(RTRIM([Ledger Types])), '|',
                ISNULL(LTRIM(RTRIM(CAST([Line Extension Code] AS varchar(10)))), '')) AS line_id,
         LTRIM(RTRIM([Account ID])) AS gl_bank_account,
         LTRIM(RTRIM([Document Type])) AS doc_type,
         CAST([Document _Voucher Invoice etc] AS bigint) AS doc_number,
         LTRIM(RTRIM([Document Company])) AS doc_company,
         CAST([Date For G_L _and Voucher Julian] AS date) AS gl_date,
         CAST([Journal Entry Line Number] AS bigint) AS je_line_number,
         LTRIM(RTRIM([Ledger Types])) AS ledger_type,
         CAST(ROUND([Amount], 2) AS decimal(18,2)) AS amount,
         LTRIM(RTRIM(ISNULL([Reconciled Code], ''))) AS reconciled_code,
         LTRIM(RTRIM([Name Alpha Explanation])) AS name_alpha,
         LTRIM(RTRIM([Name Remark Explanation])) AS name_remark,
         [Batch Number] AS batch_number
  FROM proddta.account_ledger_f0911`;

type BankKey = { acct: string; stmt: number; date: string; line: number };
type GlKey = { acct: string; type: string; doc: number; co: string; date: string; jeln: number; lt: string };

export async function bankSource(keys: BankKey[]) {
  if (!keys.length) return [];
  const params: Params = {};
  const conds = keys.map((k, i) => {
    Object.assign(params, { [`a${i}`]: k.acct, [`s${i}`]: k.stmt, [`d${i}`]: k.date, [`l${i}`]: k.line });
    return `(LTRIM(RTRIM([G_L Bank Account])) = @a${i} AND CAST([Bank Statement ID] AS bigint) = @s${i}
             AND [Statement Date] = CAST(@d${i} AS date) AND CAST([Line Number _ General] AS bigint) = @l${i})`;
  });
  return query("lakehouse", `${BANK_SELECT} WHERE ${conds.join(" OR ")};`, params);
}

export async function glSource(keys: GlKey[]) {
  if (!keys.length) return [];
  const params: Params = {};
  const conds = keys.map((k, i) => {
    Object.assign(params, {
      [`a${i}`]: k.acct, [`t${i}`]: k.type, [`n${i}`]: k.doc, [`c${i}`]: k.co, [`d${i}`]: k.date, [`j${i}`]: k.jeln, [`lt${i}`]: k.lt,
    });
    return `(LTRIM(RTRIM([Account ID])) = @a${i} AND LTRIM(RTRIM([Document Type])) = @t${i}
             AND CAST([Document _Voucher Invoice etc] AS bigint) = @n${i} AND LTRIM(RTRIM([Document Company])) = @c${i}
             AND CAST([Date For G_L _and Voucher Julian] AS date) = CAST(@d${i} AS date)
             AND CAST([Journal Entry Line Number] AS bigint) = @j${i} AND LTRIM(RTRIM([Ledger Types])) = @lt${i})`;
  });
  return query("lakehouse", `${GL_SELECT} WHERE ${conds.join(" OR ")};`, params);
}

export const bankKeyOf = (l: MatchLine): BankKey => ({
  acct: l.gl_bank_account, stmt: Number(l.bank_statement_id), date: iso(l.statement_date)!, line: Number(l.line_number),
});
export const glKeyOf = (l: MatchLine): GlKey => ({
  acct: l.gl_bank_account, type: l.doc_type ?? "", doc: Number(l.doc_number), co: l.doc_company ?? "",
  date: iso(l.gl_date)!, jeln: Number(l.je_line_number), lt: l.ledger_type ?? "",
});

/** line_id -> key: 'B|stmt|acct|stmtdate|line' or 'G|type|doc|co|gldate|jeln|lt|ext' */
export function parseLineId(id: string): { side: "BANK"; key: BankKey } | { side: "GL"; key: GlKey } | null {
  const p = id.trim().split("|");
  if (p[0] === "B" && p.length === 5)
    return { side: "BANK", key: { stmt: Number(p[1]), acct: p[2], date: p[3], line: Number(p[4]) } };
  if (p[0] === "G" && p.length >= 7)
    return { side: "GL", key: { type: p[1], doc: Number(p[2]), co: p[3], date: p[4], jeln: Number(p[5]), lt: p[6], acct: "" } };
  return null;
}

export async function glSourceByLineId(k: GlKey) {
  // account is not part of the GL line_id - search by the document key only
  return query("lakehouse", `${GL_SELECT}
    WHERE LTRIM(RTRIM([Document Type])) = @t AND CAST([Document _Voucher Invoice etc] AS bigint) = @n
      AND LTRIM(RTRIM([Document Company])) = @c AND CAST([Date For G_L _and Voucher Julian] AS date) = CAST(@d AS date)
      AND CAST([Journal Entry Line Number] AS bigint) = @j AND LTRIM(RTRIM([Ledger Types])) = @lt;`,
    { t: k.type, n: k.doc, c: k.co, d: k.date, j: k.jeln, lt: k.lt });
}

/** Source totals per bank account (same definitions as the notebook) */
export async function sourceTotals() {
  return query("lakehouse", `
    WITH bank AS (
      SELECT LTRIM(RTRIM([G_L Bank Account])) AS acct,
             CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciliation Code], '')))) = 'R' THEN 1 ELSE 0 END AS is_r,
             [Statement Date] AS stmt_date
      FROM proddta.auto_bank_statement_detail_f09617),
    gl AS (
      SELECT LTRIM(RTRIM([Account ID])) AS acct,
             CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciled Code], '')))) = 'R' THEN 1 ELSE 0 END AS is_r
      FROM proddta.account_ledger_f0911
      WHERE LTRIM(RTRIM([Ledger Types])) = 'AA'
        AND LTRIM(RTRIM([Account ID])) IN (SELECT DISTINCT LTRIM(RTRIM([G_L Bank Account])) FROM proddta.auto_bank_statement_detail_f09617))
    SELECT a.acct AS gl_bank_account, a.bank_lines, a.bank_reconciled, a.period_start, a.period_end,
           ISNULL(g.gl_lines, 0) AS gl_lines, ISNULL(g.gl_reconciled, 0) AS gl_reconciled
    FROM (SELECT acct, COUNT(*) AS bank_lines, SUM(is_r) AS bank_reconciled, MIN(stmt_date) AS period_start, MAX(stmt_date) AS period_end
          FROM bank GROUP BY acct) a
    LEFT JOIN (SELECT acct, COUNT(*) AS gl_lines, SUM(is_r) AS gl_reconciled FROM gl GROUP BY acct) g ON g.acct = a.acct;`);
}

/* ---------------------------------- Checks ---------------------------------- */

export type Check = { name: string; ok: boolean; detail: string };

type Row = Record<string, unknown>;
const num = (v: unknown) => Math.round(Number(v ?? 0) * 100);   // compare in cents
const money = (cents: number) => (cents / 100).toFixed(2);

export function checkMatch(header: Row, lines: MatchLine[], bankRows: Row[], glRows: Row[]): Check[] {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean, detail: string) => checks.push({ name, ok, detail });
  const wBank = lines.filter((l) => l.side === "BANK");
  const wGl = lines.filter((l) => l.side === "GL");

  add("Bank lines found in lakehouse", bankRows.length === wBank.length,
      `${bankRows.length} of ${wBank.length} bank line(s) found by their F09617 key`);
  add("GL lines found in lakehouse", glRows.length === wGl.length,
      `${glRows.length} of ${wGl.length} GL line(s) found by their F0911 key`);

  const bankSum = bankRows.reduce((s, r) => s + num(r.amount), 0);
  const glSum = glRows.reduce((s, r) => s + num(r.amount), 0);
  add("Bank total = proposal", bankSum === num(header.bank_amount),
      `lakehouse ${money(bankSum)} vs warehouse ${money(num(header.bank_amount))}`);
  add("GL total = proposal", glSum === num(header.gl_amount),
      `lakehouse ${money(glSum)} vs warehouse ${money(num(header.gl_amount))}`);
  add("Bank total = GL total (to the cent)", bankSum === glSum, `${money(bankSum)} vs ${money(glSum)}`);

  const accounts = new Set([...bankRows, ...glRows].map((r) => String(r.gl_bank_account)));
  add("Same bank account on both sides", accounts.size === 1, [...accounts].join(", ") || "-");

  let maxGap = 0;
  for (const b of bankRows) for (const gr of glRows) {
    const gap = Math.abs(daysBetween(iso(b.cleared_date)!, iso(gr.gl_date)!));
    maxGap = Math.max(maxGap, gap);
  }
  const tol = Number(header.tolerance_days ?? 5);
  add("Dates within the rule's window", maxGap <= tol && maxGap <= 5,
      `largest gap ${maxGap} day(s); rule window ${tol} day(s)`);

  const bankR = bankRows.some((r) => String(r.reconciliation_code).toUpperCase() === "R");
  const glR = glRows.some((r) => String(r.reconciled_code).toUpperCase() === "R");
  const expected = bankR && glR ? "BOTH_R (never allowed)" : bankR ? "BANK_R_GL_OPEN" : glR ? "GL_R_BANK_OPEN" : "BOTH_OPEN";
  add("Reconciled flags agree with recon_state", expected === header.recon_state,
      `lakehouse says ${expected}, warehouse says ${header.recon_state}`);

  const cat = String(header.match_category);
  const shapeOk = cat === "1:1" ? bankRows.length === 1 && glRows.length === 1
    : cat === "1:M" ? bankRows.length === 1 && glRows.length >= 2 && glRows.length <= 5
    : bankRows.length >= 2 && bankRows.length <= 5 && glRows.length === 1;
  add(`Shape fits ${cat}`, shapeOk, `${bankRows.length} bank / ${glRows.length} GL`);

  if (cat !== "1:1") {
    const single = cat === "1:M" ? bankRows : glRows;
    const parts = cat === "1:M" ? glRows : bankRows;
    const anchor = Math.abs(num(single[0]?.amount));
    const smallest = Math.min(...parts.map((p) => Math.abs(num(p.amount))));
    add("Each part >= 1% of the single side", parts.length > 0 && smallest >= anchor * 0.01,
        `smallest part ${money(smallest)} vs 1% = ${money(Math.round(anchor * 0.01))}`);
  }

  for (const l of lines) {
    const src = (l.side === "BANK" ? bankRows : glRows).find((r) => r.line_id === l.line_id);
    if (src && num(src.amount) !== num(l.amount))
      add(`Amount of ${l.line_id}`, false, `lakehouse ${money(num(src.amount))} vs warehouse ${money(num(l.amount))}`);
  }
  return checks;
}
