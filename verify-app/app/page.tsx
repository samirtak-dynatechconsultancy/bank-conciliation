"use client";

import { useCallback, useEffect, useState } from "react";

type Row = Record<string, any>;
type Tab = "matches" | "line" | "totals";

const fmtDate = (v: any) => (v ? String(v).slice(0, 10) : "-");
const fmtAmt = (v: any) =>
  v == null || v === "" ? "-" : Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

async function getJson(url: string) {
  const res = await fetch(url, { cache: "no-store" });
  const data = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
  if (!res.ok || (data && !Array.isArray(data) && data.error)) throw new Error(data?.error ?? `HTTP ${res.status}`);
  return data;
}

/** Generic table: columns = [key, label, kind?] */
function Table({ rows, cols, onRow, selected }: {
  rows: Row[]; cols: [string, string, ("date" | "amt" | "mono")?][]; onRow?: (r: Row) => void; selected?: (r: Row) => boolean;
}) {
  if (!rows.length) return <p className="muted">No rows.</p>;
  return (
    <table>
      <thead><tr>{cols.map(([k, l]) => <th key={k}>{l}</th>)}</tr></thead>
      <tbody>
        {rows.map((r, i) => (
          <tr key={i} className={`${onRow ? "click" : ""} ${selected?.(r) ? "selected" : ""}`} onClick={() => onRow?.(r)}>
            {cols.map(([k, , kind]) => (
              <td key={k} className={kind === "amt" ? "num" : kind === "mono" ? "mono" : ""}>
                {kind === "date" ? fmtDate(r[k]) : kind === "amt" ? fmtAmt(r[k]) : r[k] === true ? "yes" : r[k] === false ? "no" : r[k] ?? "-"}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default function Page() {
  const [tab, setTab] = useState<Tab>("matches");
  const [accounts, setAccounts] = useState<Row[]>([]);
  const [acct, setAcct] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    getJson("/api/accounts").then(setAccounts).catch((e) => setError(e.message));
  }, []);

  const current = accounts.find((a) => a.gl_bank_account === acct);

  return (
    <>
      <header className="top">
        <h1>Bank Reconciliation – Verify</h1>
        <select value={acct} onChange={(e) => setAcct(e.target.value)} aria-label="Bank account">
          <option value="">All bank accounts</option>
          {accounts.map((a) => (
            <option key={a.gl_bank_account} value={a.gl_bank_account}>
              {a.display_name} ({a.gl_bank_account})
            </option>
          ))}
        </select>
      </header>
      <main>
        {error && <div className="error">{error}</div>}
        {current && (
          <div className="summary">
            <span className="pill">Run: {current.last_run_status ?? "never"} {fmtDate(current.last_run_at)}</span>
            <span className="pill">Period {fmtDate(current.period_start)} – {fmtDate(current.period_end)}</span>
            <span className="pill">Bank rows {current.bank_lines ?? "-"}</span>
            <span className="pill">GL rows {current.gl_lines ?? "-"}</span>
            <span className="pill">Proposals {current.proposed_total}</span>
            <span className="pill">Approved {current.confirmed}</span>
            <span className="pill">Exceptions {current.exceptions_open}</span>
            <span className="pill">Unmatched bank {current.unmatched_bank} · GL {current.unmatched_gl}</span>
          </div>
        )}
        <nav className="tabs">
          <button className={tab === "matches" ? "active" : ""} onClick={() => setTab("matches")}>Matches</button>
          <button className={tab === "line" ? "active" : ""} onClick={() => setTab("line")}>Line lookup</button>
          <button className={tab === "totals" ? "active" : ""} onClick={() => setTab("totals")}>Totals check</button>
        </nav>
        {tab === "matches" && <Matches acct={acct} />}
        {tab === "line" && <LineLookup />}
        {tab === "totals" && <Totals />}
      </main>
    </>
  );
}

/* ------------------------------- Matches tab ------------------------------- */

function Matches({ acct }: { acct: string }) {
  const [filters, setFilters] = useState({ category: "", status: "", confidence: "", rule: "", amount: "" });
  const [offset, setOffset] = useState(0);
  const [data, setData] = useState<{ rows: Row[]; total: number }>({ rows: [], total: 0 });
  const [selected, setSelected] = useState<string>("");
  const [detail, setDetail] = useState<Row | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const pageSize = 50;

  const load = useCallback(async (off: number) => {
    setLoading(true); setError("");
    const q = new URLSearchParams({ ...filters, acct, offset: String(off), pageSize: String(pageSize) });
    try { setData(await getJson(`/api/matches?${q}`)); setOffset(off); }
    catch (e: any) { setError(e.message); }
    finally { setLoading(false); }
  }, [filters, acct]);

  useEffect(() => { load(0); setDetail(null); setSelected(""); }, [acct]); // eslint-disable-line react-hooks/exhaustive-deps

  const open = async (id: string) => {
    setSelected(id); setDetail(null); setError("");
    try { setDetail(await getJson(`/api/match/${id}`)); } catch (e: any) { setError(e.message); }
  };

  const set = (k: keyof typeof filters) => (e: any) => setFilters({ ...filters, [k]: e.target.value });

  return (
    <>
      <div className="panel">
        <div className="filters">
          <label>Category
            <select value={filters.category} onChange={set("category")}>
              <option value="">All</option><option>1:1</option><option>1:M</option><option>M:1</option>
            </select>
          </label>
          <label>Status
            <select value={filters.status} onChange={set("status")}>
              <option value="">All</option><option>PENDING</option><option>APPROVED</option><option>REJECTED</option><option>EXCEPTION</option>
            </select>
          </label>
          <label>Confidence
            <select value={filters.confidence} onChange={set("confidence")}>
              <option value="">All</option><option>HIGH</option><option>MEDIUM</option><option>POTENTIAL</option>
            </select>
          </label>
          <label>Rule contains<input value={filters.rule} onChange={set("rule")} placeholder="Exact, T+/-1, Many-to-one…" /></label>
          <label>Amount<input value={filters.amount} onChange={set("amount")} placeholder="e.g. 1646.40" /></label>
          <button className="btn" onClick={() => load(0)} disabled={loading}>{loading ? "Loading…" : "Search"}</button>
        </div>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="panel">
        <h2>Proposals ({data.total}) <span className="muted">– click a row to verify it against the lakehouse</span></h2>
        <Table
          rows={data.rows}
          onRow={(r) => open(r.match_id)}
          selected={(r) => r.match_id === selected}
          cols={[["gl_bank_account", "Account"], ["match_category", "Cat."], ["match_rule", "Rule"], ["confidence", "Confidence"],
                 ["recon_state", "Recon state"], ["status", "Status"], ["bank_line_count", "Bank #"], ["gl_line_count", "GL #"],
                 ["bank_amount", "Bank amount", "amt"], ["gl_amount", "GL amount", "amt"], ["max_date_gap_days", "Gap (days)"]]}
        />
        <div className="pager">
          <button className="btn secondary" disabled={offset === 0 || loading} onClick={() => load(Math.max(0, offset - pageSize))}>Previous</button>
          <span className="muted">{data.total ? `${offset + 1}–${Math.min(offset + pageSize, data.total)} of ${data.total}` : ""}</span>
          <button className="btn secondary" disabled={offset + pageSize >= data.total || loading} onClick={() => load(offset + pageSize)}>Next</button>
        </div>
      </div>
      {selected && !detail && !error && <div className="panel muted">Loading match and source rows…</div>}
      {detail && <MatchDetail d={detail} />}
    </>
  );
}

function MatchDetail({ d }: { d: Row }) {
  const h = d.header;
  const passed = d.checks.filter((c: Row) => c.ok).length;
  return (
    <>
      <div className="panel">
        <h2>
          Checks for {h.match_category} match <span className="mono">{h.match_id}</span>{" "}
          <span className={`pill ${passed === d.checks.length ? "ok" : "bad"}`}>{passed}/{d.checks.length} passed</span>
        </h2>
        <p className="muted">{h.match_rule} · {h.confidence} · {h.recon_state} · {h.status}{h.note ? ` · ${h.note}` : ""}</p>
        <div className="checks">
          {d.checks.map((c: Row, i: number) => (
            <div key={i} className={`check ${c.ok ? "ok" : "bad"}`}>
              <span>{c.ok ? "✓" : "✗"}</span>
              <div><b>{c.name}</b><small>{c.detail}</small></div>
            </div>
          ))}
        </div>
      </div>
      <div className="panel">
        <h2>Warehouse – lines in this match (dbo.bank_recon_match_line)</h2>
        <Table rows={d.lines} cols={[["side", "Side"], ["txn_date", "Date", "date"], ["amount", "Amount", "amt"], ["is_reconciled", "Was R"],
          ["bank_statement_id", "Stmt"], ["line_number", "Line"], ["doc_type", "Doc type"], ["doc_number", "Doc no"],
          ["doc_company", "Co"], ["je_line_number", "JE line"], ["description", "Description"], ["line_id", "line_id", "mono"]]} />
      </div>
      {h.confidence === "MEDIUM" && <PossibleMatches rows={d.possibleMatches ?? []} />}
      <div className="panel">
        <h2>Lakehouse – bank rows (proddta.auto_bank_statement_detail_f09617)</h2>
        <Table rows={d.bankRows} cols={[["gl_bank_account", "Account"], ["bank_statement_id", "Stmt"], ["statement_date", "Stmt date", "date"],
          ["line_number", "Line (stored)"], ["cleared_date", "Cleared date", "date"], ["tr_code", "TR"], ["debits_raw", "Debits (cents)"],
          ["credits_raw", "Credits (cents)"], ["amount", "Amount", "amt"], ["reconciliation_code", "Recon code"], ["misc_information", "Misc information"]]} />
      </div>
      <div className="panel">
        <h2>Lakehouse – GL rows (proddta.account_ledger_f0911)</h2>
        <Table rows={d.glRows} cols={[["gl_bank_account", "Account"], ["doc_type", "Doc type"], ["doc_number", "Doc no"], ["doc_company", "Co"],
          ["gl_date", "GL date", "date"], ["je_line_number", "JE line"], ["ledger_type", "LT"], ["amount", "Amount", "amt"],
          ["reconciled_code", "Recon code"], ["name_alpha", "Name alpha"], ["name_remark", "Name remark"], ["batch_number", "Batch"]]} />
      </div>
    </>
  );
}

/** MEDIUM = several lines were equally valid partners (same amount, same date gap). Shows every option, the engine's
 *  choice first, and checks each one against the lakehouse. */
function PossibleMatches({ rows }: { rows: Row[] }) {
  const flag = (ok: boolean | null) => (ok == null ? "-" : ok ? "✓" : "✗");
  const view = rows.map((r) => ({
    ...r,
    choice: r.is_proposed ? "Proposed" : "Alternative",
    usable: r.used_in_other_match ? "In another match" : "Available",
    in_lh: flag(r.in_lakehouse),
    amt_ok: flag(r.in_lakehouse ? r.amount_ok : null),
    src_r: r.source_reconciled == null ? "-" : r.source_reconciled ? "R" : "open",
    ref: r.side === "BANK" ? `Stmt ${r.bank_statement_id ?? "-"} / line ${r.line_number ?? "-"}`
                           : `${r.doc_type ?? ""} ${r.doc_number ?? ""} / ${r.doc_company ?? ""} / JE ${r.je_line_number ?? "-"}`,
  }));
  const alternatives = rows.filter((r) => !r.is_proposed).length;
  return (
    <div className="panel">
      <h2>Possible matches (MEDIUM confidence – {alternatives} equally valid alternative{alternatives === 1 ? "" : "s"})</h2>
      <p className="muted">
        Each line below has the same amount and the same date gap as the proposed partner, so the engine had to pick one.
        Alternatives marked “In another match” are already used by a different proposal.
      </p>
      {rows.length
        ? <Table rows={view} selected={(r) => !!r.is_proposed} cols={[["choice", "Choice"], ["side", "Side"], ["txn_date", "Date", "date"],
            ["gap_days", "Gap (days)"], ["amount", "Amount", "amt"], ["ref", "Reference"], ["description", "Description"],
            ["usable", "Usable"], ["in_lh", "In lakehouse"], ["amt_ok", "Amount ="], ["src_r", "Source R"], ["line_id", "line_id", "mono"]]} />
        : <p className="muted">No candidate rows stored for this match (dbo.bank_recon_match_candidate is empty for it).</p>}
    </div>
  );
}

/* ------------------------------- Line lookup tab ------------------------------- */

function LineLookup() {
  const [id, setId] = useState("");
  const [res, setRes] = useState<Row | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const go = async () => {
    setLoading(true); setError(""); setRes(null);
    try { setRes(await getJson(`/api/line?id=${encodeURIComponent(id.trim())}`)); }
    catch (e: any) { setError(e.message); }
    finally { setLoading(false); }
  };

  return (
    <>
      <div className="panel">
        <div className="filters">
          <label style={{ flex: 1 }}>line_id (from a match, or B|stmt|account|date|line / G|type|doc|co|date|jeline|LT|)
            <input value={id} onChange={(e) => setId(e.target.value)} placeholder="B|312|00358555|2025-12-24|15200" />
          </label>
          <button className="btn" onClick={go} disabled={!id.trim() || loading}>{loading ? "Loading…" : "Look up"}</button>
        </div>
      </div>
      {error && <div className="error">{error}</div>}
      {res && (
        <>
          <div className="panel">
            <h2>Warehouse – where this line appears</h2>
            {res.warehouse.length
              ? <Table rows={res.warehouse} cols={[["found_in", "Found in"], ["match_id", "match_id", "mono"], ["detail", "Status / side"], ["info", "Rule / reason"], ["extra", "Extra"]]} />
              : <p className="muted">Not in any match, unmatched list, candidate list or decision. The engine did not use it:
                  e.g. already reconciled with no open partner, amount 0, GL older than the bank data, not ledger AA, or not a bank account.</p>}
          </div>
          <div className="panel">
            <h2>Lakehouse – source row ({res.side})</h2>
            <Table rows={res.source} cols={res.side === "BANK"
              ? [["gl_bank_account", "Account"], ["bank_statement_id", "Stmt"], ["statement_date", "Stmt date", "date"], ["line_number", "Line"],
                 ["cleared_date", "Cleared", "date"], ["tr_code", "TR"], ["amount", "Amount", "amt"], ["reconciliation_code", "Recon code"], ["misc_information", "Misc"]]
              : [["gl_bank_account", "Account"], ["doc_type", "Doc type"], ["doc_number", "Doc no"], ["doc_company", "Co"], ["gl_date", "GL date", "date"],
                 ["je_line_number", "JE line"], ["ledger_type", "LT"], ["amount", "Amount", "amt"], ["reconciled_code", "Recon code"], ["name_alpha", "Name"]]} />
          </div>
        </>
      )}
    </>
  );
}

/* ------------------------------- Totals tab ------------------------------- */

function Totals() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState("");
  useEffect(() => { getJson("/api/totals").then(setRows).catch((e) => setError(e.message)); }, []);
  if (error) return <div className="error">{error}</div>;
  if (!rows) return <div className="panel muted">Counting lines in the lakehouse and the warehouse…</div>;
  return (
    <div className="panel">
      <h2>Did the latest run read every source line?</h2>
      <p className="muted">Bank rows and GL rows (bank accounts, ledger AA) must be equal on both sides.</p>
      <Table
        rows={rows.map((r) => ({ ...r, bank: r.bank_ok ? "✓" : "✗", gl: r.gl_ok ? "✓" : "✗" }))}
        cols={[["display_name", "Account"], ["gl_bank_account", "ID"], ["bank_lines_source", "Bank rows (lakehouse)"],
               ["bank_lines_run", "Bank rows (run)"], ["bank", "Bank"], ["gl_lines_source", "GL rows (lakehouse)"],
               ["gl_lines_run", "GL rows (run)"], ["gl", "GL"], ["period_source", "Period (lakehouse)"], ["period_run", "Period (run)"]]}
      />
    </div>
  );
}
