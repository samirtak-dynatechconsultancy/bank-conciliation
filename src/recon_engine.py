"""
Bank Reconciliation matching engine (pure pandas - runs locally and inside a Fabric notebook).

Matches unreconciled JDE bank statement lines (F09617) to GL cash lines (F0911):

    Tier 0      EXACT            amount equal, bank date == GL date               (1:1)
    Tier 1..N   TOLERANCE_T1..TN amount equal, |bank date - GL date| <= N days     (1:1)
    Aggregate   ONE_TO_MANY      1 bank line  == sum of several GL lines           (flagged POTENTIAL)
    Aggregate   MANY_TO_ONE      sum of several bank lines == 1 GL line           (flagged POTENTIAL)
    Leftovers   UNMATCHED_BANK / UNMATCHED_GL

Rules enforced:
  * Already reconciled lines are dropped (bank Reconciliation Code = 'R', GL R ND = 'R').
  * Lines locked by an open proposal from an earlier run are dropped (caller passes them in).
  * Matching only happens inside the same GL bank account (bank 'GL Bank Account' == GL 'Account ID').
  * Amounts are compared in integer cents after sign standardisation
    (bank: credits - debits, GL: Amount as posted -> deposits positive, payments negative).
  * A line is used at most once per run; 1:1 tiers run first and lock their lines,
    aggregates only see what is left.
  * Combinations a user has already rejected are not proposed again.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------


@dataclass
class MatchConfig:
    max_tolerance_days: int = 5          # 1:1 date window widens 0 -> max_tolerance_days
    aggregate_tolerance_days: int = 5    # date window for 1:M / M:1 (also widened step by step)
    aggregate_max_lines: int = 5         # cap on lines combined in one aggregate group
    aggregate_max_candidates: int = 25   # cap on candidate lines considered per anchor line
    aggregate_search_node_limit: int = 50_000   # DFS budget per anchor line
    enable_one_to_many: bool = True
    enable_many_to_one: bool = True

    @classmethod
    def from_dict(cls, d: dict) -> "MatchConfig":
        cfg = cls()
        for k, v in (d or {}).items():
            if hasattr(cfg, k) and v is not None and str(v).strip() != "":
                cur = getattr(cfg, k)
                if isinstance(cur, bool):
                    v = str(v).strip().lower() in ("1", "true", "yes", "y")
                elif isinstance(cur, int):
                    v = int(float(v))
                setattr(cfg, k, v)
        return cfg


# Logical column -> source column. Defaults match the sanitised lakehouse test tables
# (Excel headers -> snake_case). Other environments: see SOURCE_PROFILES below.
BANK_COLUMNS = {
    "bank_statement_id": "bank_statement_id",
    "gl_bank_account": "bank_acct_g_l",
    "statement_date": "statement_date",
    "line_number": "line_number",
    "reconciliation_code": "reconciliation_code",
    "debit": "debits_entered",
    "credit": "credits_entered",
    "txn_date": "cleared_date",               # bank value / cleared date used for matching
    "tr_code": "tr_cd",
    "external_txn_type": "external_transaction_type",
    "misc_info": "misc_information",
    "remark": "remark",
    "reference_1": "reference_1",
}

GL_COLUMNS = {
    "doc_type": "do_ty",
    "doc_number": "document_number",
    "doc_company": "doc_co",
    "gl_date": "g_l_date",
    "je_line_number": "je_line_number",
    "ledger_type": "lt",
    "line_ext_code": "line_extension",
    "gl_bank_account": "account_id",
    "account_number": "account_number",
    "amount": "amount",
    "reconciled_flag": "r_nd",
    "reference_3": "reference_3",
    "explanation": "explanation_alpha_name",
    "explanation_remark": "explanation_remark",
    "payment_number": "payment_number",
}

@dataclass
class SourceProfile:
    """Everything that differs between source environments: table names, column names, data quirks."""
    name: str
    bank_table: str
    gl_table: str
    schema: str = ""                         # "" = no schema folder (test lakehouse)
    bank_columns: dict = field(default_factory=lambda: dict(BANK_COLUMNS))
    gl_columns: dict = field(default_factory=lambda: dict(GL_COLUMNS))
    bank_amount_divisor: float = 1.0         # client F09617 stores amounts in cents: 89156916 = 891,569.16
    gl_ledger_types: tuple = ("AA",)         # AA = actual amounts; AU (units) must never be matched


SOURCE_PROFILES = {
    # Excel extracts loaded into LH_BankRecon (snake_case headers)
    "test": SourceProfile(name="test", bank_table="jde_f09617_bank_statement", gl_table="jde_f0911_gl"),

    # Client Fabric tables (proddta schema). Verified 2026-10-21 against reconciled pairs:
    # bank amount / 100 gives 9,008 same-account pairs within 5 days, as-is only 54.
    # Optional columns (description, references) are left out on purpose - see OPEN_ISSUES.md.
    "client": SourceProfile(
        name="client",
        schema="proddta",
        bank_table="auto_bank_statement_detail_f09617",
        gl_table="account_ledger_f0911",
        bank_amount_divisor=100.0,
        gl_ledger_types=("AA",),
        bank_columns={
            "bank_statement_id": "Bank Statement ID",
            "gl_bank_account": "G_L Bank Account",
            "statement_date": "Statement Date",
            "line_number": "Line Number _ General",
            "reconciliation_code": "Reconciliation Code",
            "debit": "Debits Entered",
            "credit": "Credits Entered",
            "txn_date": "Date _ Cleared_Value",
            "tr_code": "Bank Statement Transaction Code",
            "misc_info": "Misc Information",
        },
        gl_columns={
            "doc_type": "Document Type",
            "doc_number": "Document _Voucher Invoice etc",
            "doc_company": "Document Company",
            "gl_date": "Date For G_L _and Voucher Julian",   # varchar, holds ISO dates (yyyy-mm-dd)
            "je_line_number": "Journal Entry Line Number",
            "ledger_type": "Ledger Types",
            "line_ext_code": "Line Extension Code",          # NULL in client data - OPEN_ISSUES.md #1
            "gl_bank_account": "Account ID",
            "amount": "Amount",
            "reconciled_flag": "Reconciled Code",
            "explanation": "Name Alpha Explanation",
            "explanation_remark": "Name Remark Explanation",
        },
    ),
}

# Columns the engine cannot work without; everything else is optional (blank if not mapped)
BANK_REQUIRED = ["bank_statement_id", "gl_bank_account", "statement_date", "line_number",
                 "reconciliation_code", "debit", "credit", "txn_date"]
GL_REQUIRED = ["doc_type", "doc_number", "doc_company", "gl_date", "je_line_number", "ledger_type",
               "line_ext_code", "gl_bank_account", "amount", "reconciled_flag"]

BANK_KEY = ["bank_statement_id", "gl_bank_account", "statement_date", "line_number"]
GL_KEY = ["doc_type", "doc_number", "doc_company", "gl_date", "je_line_number", "ledger_type", "line_ext_code"]


# --------------------------------------------------------------------------------------
# Preparation
# --------------------------------------------------------------------------------------


def _s(series: pd.Series) -> pd.Series:
    return series.astype("string").fillna("").str.strip()


def _num(series: pd.Series) -> pd.Series:
    return pd.to_numeric(series, errors="coerce").fillna(0.0)


def _date(series: pd.Series) -> pd.Series:
    return pd.to_datetime(series, errors="coerce").dt.normalize()


def _int_str(series: pd.Series) -> pd.Series:
    """'631', 631, 631.0 -> '631' (keeps non-numeric text as is)."""
    s = _s(series)
    n = pd.to_numeric(s, errors="coerce")
    return s.where(n.isna(), n.astype("Int64").astype("string")).fillna("")


def _getter(raw: pd.DataFrame, colmap: dict, required: list, side: str):
    """Return col(key): the mapped source column, or blanks for an unmapped optional column."""
    missing = [k for k in required if not colmap.get(k) or colmap[k] not in raw.columns]
    if missing:
        raise KeyError(f"{side}: required columns missing from source: "
                       + ", ".join(f"{k} -> {colmap.get(k)!r}" for k in missing))

    def col(key: str) -> pd.Series:
        name = colmap.get(key)
        if name and name in raw.columns:
            return raw[name]
        return pd.Series([None] * len(raw), index=raw.index, dtype="object")
    return col


def bank_line_id(df: pd.DataFrame) -> pd.Series:
    return ("B|" + df["bank_statement_id"] + "|" + df["gl_bank_account"] + "|"
            + df["statement_date"].dt.strftime("%Y-%m-%d") + "|" + df["line_number"])


def gl_line_id(df: pd.DataFrame) -> pd.Series:
    return ("G|" + df["doc_type"] + "|" + df["doc_number"] + "|" + df["doc_company"] + "|"
            + df["gl_date"].dt.strftime("%Y-%m-%d") + "|" + df["je_line_number"] + "|"
            + df["ledger_type"] + "|" + df["line_ext_code"])


def prepare_bank(raw: pd.DataFrame, cols: dict | None = None, amount_divisor: float = 1.0) -> pd.DataFrame:
    c = cols if cols is not None else BANK_COLUMNS
    col = _getter(raw, c, BANK_REQUIRED, "bank")
    df = pd.DataFrame({
        "bank_statement_id": _int_str(col("bank_statement_id")),
        "gl_bank_account": _s(col("gl_bank_account")),
        "statement_date": _date(col("statement_date")),
        "line_number": _int_str(col("line_number")),
        "reconciled": _s(col("reconciliation_code")).str.upper().eq("R"),
        "txn_date": _date(col("txn_date")),
        "tr_code": _s(col("tr_code")),
        "external_txn_type": _int_str(col("external_txn_type")),
        "description": _s(col("misc_info")),
        "reference_1": _s(col("reference_1")),
    })
    # +ve = money in, -ve = money out; divisor converts sources that store cents (client: 100)
    amount = (_num(col("credit")) - _num(col("debit"))) / amount_divisor
    df["amount"] = amount.round(2)
    df["amount_cents"] = (amount * 100).round().astype("int64")
    df["txn_date"] = df["txn_date"].fillna(df["statement_date"])
    df["line_id"] = bank_line_id(df)
    return df


def prepare_gl(raw: pd.DataFrame, cols: dict | None = None) -> pd.DataFrame:
    c = cols if cols is not None else GL_COLUMNS
    col = _getter(raw, c, GL_REQUIRED, "GL")
    df = pd.DataFrame({
        "doc_type": _s(col("doc_type")),
        "doc_number": _int_str(col("doc_number")),
        "doc_company": _s(col("doc_company")),
        "gl_date": _date(col("gl_date")),
        "je_line_number": _int_str(col("je_line_number")),
        "ledger_type": _s(col("ledger_type")),
        "line_ext_code": _s(col("line_ext_code")),
        "gl_bank_account": _s(col("gl_bank_account")),
        "account_number": _s(col("account_number")),
        "reconciled": _s(col("reconciled_flag")).str.upper().eq("R"),
        "reference_3": _s(col("reference_3")),
        "payment_number": _s(col("payment_number")),
    })
    expl = _s(col("explanation"))
    rmk = _s(col("explanation_remark"))
    df["description"] = np.where((rmk != "") & (expl != ""), expl + " / " + rmk, expl + rmk)
    amount = _num(col("amount"))
    df["amount"] = amount.round(2)
    df["amount_cents"] = (amount * 100).round().astype("int64")
    df["txn_date"] = df["gl_date"]
    df["line_id"] = gl_line_id(df)
    return df


def select_open_lines(bank: pd.DataFrame, gl: pd.DataFrame, *,
                      bank_accounts: Iterable[str] | None = None,
                      date_from=None, date_to=None, max_window_days: int = 5,
                      locked_line_ids: Iterable[str] = (),
                      gl_ledger_types: Iterable[str] | None = ("AA",),
                      gl_accounts: Iterable[str] | None = None) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    """Drop reconciled lines, lines locked by open proposals, zero amounts; apply account/period scope.

    GL is limited to the given ledger types (AU = units, never money) and to bank accounts:
    gl_accounts if given, otherwise every account that appears in the bank lines.
    GL period is widened by the max date window so bank lines at the period edge can still match.
    """
    if gl_ledger_types:
        gl = gl[gl["ledger_type"].isin(list(gl_ledger_types))]
    acct_set = set(gl_accounts) if gl_accounts is not None else set(bank["gl_bank_account"])
    gl = gl[gl["gl_bank_account"].isin(acct_set)]

    stats = {"bank_total": len(bank), "gl_total": len(gl),
             "bank_reconciled_skipped": int(bank["reconciled"].sum()),
             "gl_reconciled_skipped": int(gl["reconciled"].sum())}
    b = bank[~bank["reconciled"] & (bank["amount_cents"] != 0)]
    g = gl[~gl["reconciled"] & (gl["amount_cents"] != 0)]

    accts = [a.strip() for a in (bank_accounts or []) if a and a.strip()]
    if accts:
        b = b[b["gl_bank_account"].isin(accts)]
        g = g[g["gl_bank_account"].isin(accts)]
    if date_from:
        df_ = pd.Timestamp(date_from)
        b = b[b["txn_date"] >= df_]
        g = g[g["txn_date"] >= df_ - pd.Timedelta(days=max_window_days)]
    if date_to:
        dt_ = pd.Timestamp(date_to)
        b = b[b["txn_date"] <= dt_]
        g = g[g["txn_date"] <= dt_ + pd.Timedelta(days=max_window_days)]

    locked = set(locked_line_ids or ())
    stats["bank_locked_skipped"] = int(b["line_id"].isin(locked).sum())
    stats["gl_locked_skipped"] = int(g["line_id"].isin(locked).sum())
    b = b[~b["line_id"].isin(locked)].reset_index(drop=True)
    g = g[~g["line_id"].isin(locked)].reset_index(drop=True)
    stats["bank_in_scope"] = len(b)
    stats["gl_in_scope"] = len(g)
    return b, g, stats


# --------------------------------------------------------------------------------------
# Matching
# --------------------------------------------------------------------------------------


def group_signature(bank_ids: Iterable[str], gl_ids: Iterable[str]) -> str:
    """Stable fingerprint of a match combination (used to suppress rejected proposals)."""
    raw = "||".join(sorted(bank_ids)) + "##" + "||".join(sorted(gl_ids))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


@dataclass
class MatchResult:
    groups: list = field(default_factory=list)   # one dict per proposal
    links: list = field(default_factory=list)    # one dict per (proposal, line)
    unmatched: pd.DataFrame | None = None
    stats: dict = field(default_factory=dict)


def describe_rule(match_type: str, tolerance_days: int, bank_lines: int, gl_lines: int) -> str:
    """Plain-English reason for a match, numbered as in the SOW rules table (section 3.2).

    Keep in sync with the backfill CASE in sql/03_add_match_rule.sql.
    """
    t = int(tolerance_days)
    window = "same date" if t == 0 else f"within +/-{t} day{'s' if t > 1 else ''}"
    if match_type == "EXACT":
        return "Rule 2 - Exact match: same amount, same date"
    if match_type.startswith("TOLERANCE_T"):
        return (f"Rule {t + 2} - Tolerance T+/-{t} (1:1): same amount, "
                f"dates {t} day{'s' if t > 1 else ''} apart")
    if match_type == "ONE_TO_MANY":
        return f"Rule 8 - One-to-many (1:M, potential): 1 bank line = sum of {gl_lines} GL lines, {window}"
    if match_type == "MANY_TO_ONE":
        return f"Rule 9 - Many-to-one (M:1, potential): {bank_lines} bank lines sum to 1 GL line, {window}"
    return match_type


def _add_group(res: MatchResult, used_b: set, used_g: set, *, match_type, category, confidence,
               tolerance_days, bank_rows: pd.DataFrame, gl_rows: pd.DataFrame, note=""):
    seq = len(res.groups) + 1
    max_gap = 0
    for bd in bank_rows["txn_date"]:
        for gd in gl_rows["txn_date"]:
            max_gap = max(max_gap, abs((bd - gd).days))
    res.groups.append({
        "group_seq": seq,
        "match_type": match_type,                 # EXACT / TOLERANCE_T1..T5 / ONE_TO_MANY / MANY_TO_ONE
        "match_rule": describe_rule(match_type, tolerance_days, len(bank_rows), len(gl_rows)),
        "match_category": category,               # 1:1 / 1:M / M:1
        "confidence": confidence,                 # HIGH / MEDIUM / POTENTIAL
        "tolerance_days": int(tolerance_days),
        "max_date_gap_days": int(max_gap),
        "bank_line_count": len(bank_rows),
        "gl_line_count": len(gl_rows),
        "bank_amount": round(float(bank_rows["amount"].sum()), 2),
        "gl_amount": round(float(gl_rows["amount"].sum()), 2),
        "gl_bank_account": bank_rows["gl_bank_account"].iloc[0],
        "group_signature": group_signature(bank_rows["line_id"], gl_rows["line_id"]),
        "note": note,
    })
    for side, rows, used in (("BANK", bank_rows, used_b), ("GL", gl_rows, used_g)):
        for r in rows.itertuples(index=False):
            used.add(r.line_id)
            res.links.append({"group_seq": seq, "side": side, "line_id": r.line_id})


def match_one_to_one(bank, gl, cfg: MatchConfig, res: MatchResult, used_b: set, used_g: set,
                     rejected: set):
    """Tiered 1:1 matching: exact date first, then +-1 .. +-max_tolerance_days."""
    cand = bank[["line_id", "gl_bank_account", "amount_cents", "txn_date"]].merge(
        gl[["line_id", "gl_bank_account", "amount_cents", "txn_date"]],
        on=["gl_bank_account", "amount_cents"], suffixes=("_b", "_g"))
    cand["gap"] = (cand["txn_date_b"] - cand["txn_date_g"]).dt.days.abs()
    cand = cand[cand["gap"] <= cfg.max_tolerance_days]
    if rejected:
        sig = [group_signature([b], [g]) for b, g in zip(cand["line_id_b"], cand["line_id_g"])]
        cand = cand[~pd.Series(sig, index=cand.index).isin(rejected)]

    b_idx = bank.set_index("line_id")
    g_idx = gl.set_index("line_id")
    for tier in range(cfg.max_tolerance_days + 1):
        t = cand[(cand["gap"] <= tier)
                 & ~cand["line_id_b"].isin(used_b) & ~cand["line_id_g"].isin(used_g)]
        if t.empty:
            continue
        # Ambiguity = how many equally valid partners each side had at this tier
        nb = t.groupby("line_id_b")["line_id_g"].transform("count")
        ng = t.groupby("line_id_g")["line_id_b"].transform("count")
        t = t.assign(ambiguous=(nb > 1) | (ng > 1)).sort_values(
            ["gap", "txn_date_b", "line_id_b", "txn_date_g", "line_id_g"])
        for r in t.itertuples(index=False):
            if r.line_id_b in used_b or r.line_id_g in used_g:
                continue
            _add_group(
                res, used_b, used_g,
                match_type="EXACT" if tier == 0 else f"TOLERANCE_T{tier}",
                category="1:1",
                confidence="MEDIUM" if r.ambiguous else "HIGH",
                tolerance_days=tier,
                bank_rows=b_idx.loc[[r.line_id_b]].reset_index(),
                gl_rows=g_idx.loc[[r.line_id_g]].reset_index(),
                note=("Several lines with the same amount inside the window - check pairing"
                      if r.ambiguous else ""))


def _subset_sum(target: int, amounts: list[int], gaps: list[int], max_lines: int, node_limit: int):
    """Find combinations (2..max_lines items) of positive ints summing exactly to target.

    Returns (best combination or None, search_complete). Best = fewest lines, then smallest total
    date gap. amounts must be sorted descending.
    """
    n = len(amounts)
    # Fast path for pairs: hash lookup instead of DFS
    best_pair = None
    seen: dict[int, list[int]] = {}
    for j, a in enumerate(amounts):
        for i in seen.get(target - a, ()):
            g = gaps[i] + gaps[j]
            if best_pair is None or g < best_pair[1]:
                best_pair = ([i, j], g)
        seen.setdefault(a, []).append(j)
    if best_pair is not None:
        return best_pair[0], True

    suffix = [0] * (n + 1)
    for i in range(n - 1, -1, -1):
        suffix[i] = suffix[i + 1] + amounts[i]
    budget = [node_limit]

    for size in range(3, max_lines + 1):
        best = None

        def dfs(start, remaining, picked, gap_sum):
            nonlocal best
            budget[0] -= 1
            if budget[0] <= 0:
                return
            k = size - len(picked)
            if k == 0:
                if remaining == 0 and (best is None or gap_sum < best[1]):
                    best = (list(picked), gap_sum)
                return
            for i in range(start, n - k + 1):
                a = amounts[i]
                if a > remaining:
                    continue
                if suffix[i] < remaining:          # even taking everything left is not enough
                    break
                picked.append(i)
                dfs(i + 1, remaining - a, picked, gap_sum + gaps[i])
                picked.pop()
                if budget[0] <= 0:
                    return

        dfs(0, target, [], 0)
        if best is not None:
            return best[0], True
        if budget[0] <= 0:
            return None, False
    return None, True


def match_aggregate(anchor_df, other_df, cfg: MatchConfig, res: MatchResult,
                    used_anchor: set, used_other: set, rejected: set, *, anchor_side: str):
    """1:M when anchor_side='BANK' (1 bank line = sum of GL lines); M:1 when anchor_side='GL'."""
    one_to_many = anchor_side == "BANK"
    match_type = "ONE_TO_MANY" if one_to_many else "MANY_TO_ONE"
    category = "1:M" if one_to_many else "M:1"

    # Plain-Python records per account: this loop runs per anchor per tier, pandas is too slow here
    other_idx = other_df.set_index("line_id")
    by_acct: dict[str, list] = {}
    for line_id, acct, cents, d in zip(other_df["line_id"], other_df["gl_bank_account"],
                                       other_df["amount_cents"], other_df["txn_date"]):
        by_acct.setdefault(acct, []).append((line_id, int(cents), d))
    anchor_recs = sorted(zip(anchor_df["line_id"], anchor_df["gl_bank_account"],
                             anchor_df["amount_cents"].astype(int), anchor_df["txn_date"]),
                         key=lambda r: -abs(r[2]))
    failed_pool: dict[str, frozenset] = {}   # anchor -> pool that was fully searched with no result

    for tier in range(cfg.aggregate_tolerance_days + 1):
        for a_id, a_acct, a_cents, a_date in anchor_recs:
            if a_id in used_anchor:
                continue
            target = abs(a_cents)
            pool = []
            for line_id, cents, d in by_acct.get(a_acct, ()):
                if line_id in used_other or (cents > 0) != (a_cents > 0) or abs(cents) >= target:
                    continue
                gap = abs((d - a_date).days)
                if gap <= tier:
                    pool.append((line_id, abs(cents), gap, d))
            if len(pool) < 2 or sum(p[1] for p in pool) < target:
                continue
            if len(pool) > cfg.aggregate_max_candidates:
                pool = sorted(pool, key=lambda p: (p[2], p[3]))[:cfg.aggregate_max_candidates]
            pool_ids = frozenset(p[0] for p in pool)
            if a_id in failed_pool and pool_ids <= failed_pool[a_id]:
                continue   # widening the window added nothing new - same search would fail again
            pool.sort(key=lambda p: -p[1])

            pick, complete = _subset_sum(target, [p[1] for p in pool], [p[2] for p in pool],
                                         cfg.aggregate_max_lines, cfg.aggregate_search_node_limit)
            if pick is None:
                if complete:
                    failed_pool[a_id] = pool_ids
                continue
            chosen = other_idx.loc[[pool[i][0] for i in pick]].reset_index()
            anchor_row = anchor_df[anchor_df["line_id"] == a_id]
            bank_rows, gl_rows = (anchor_row, chosen) if one_to_many else (chosen, anchor_row)
            if group_signature(bank_rows["line_id"], gl_rows["line_id"]) in rejected:
                continue
            used_b, used_g = (used_anchor, used_other) if one_to_many else (used_other, used_anchor)
            _add_group(res, used_b, used_g, match_type=match_type, category=category,
                       confidence="POTENTIAL", tolerance_days=tier,
                       bank_rows=bank_rows, gl_rows=gl_rows,
                       note=f"Potential {category}: {len(chosen)} lines sum to the "
                            f"{'bank' if one_to_many else 'GL'} amount - review before approving")


def _unmatched(bank, gl, used_b, used_g, cfg: MatchConfig) -> pd.DataFrame:
    """Leftover lines, with a hint when the same amount exists on the other side outside the window."""
    out = []
    for side, df, used, other in (("BANK", bank, used_b, gl), ("GL", gl, used_g, bank)):
        left = df[~df["line_id"].isin(used)].copy()
        if left.empty:
            continue
        same_amt = left[["line_id", "gl_bank_account", "amount_cents", "txn_date"]].merge(
            other[["gl_bank_account", "amount_cents", "txn_date"]],
            on=["gl_bank_account", "amount_cents"], suffixes=("", "_o"))
        same_amt["gap"] = (same_amt["txn_date"] - same_amt["txn_date_o"]).dt.days.abs()
        nearest = same_amt.groupby("line_id")["gap"].min()
        left["nearest_same_amount_gap_days"] = left["line_id"].map(nearest)
        other_name = "GL" if side == "BANK" else "bank"
        left["reason"] = np.where(
            left["nearest_same_amount_gap_days"].isna(),
            f"No {other_name} line with this amount within +-{cfg.max_tolerance_days} days",
            f"Same amount exists on {other_name} side but outside +-{cfg.max_tolerance_days} days "
            f"or already used by another match")
        left["side"] = side
        out.append(left)
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame()


def run_matching(bank_open: pd.DataFrame, gl_open: pd.DataFrame, cfg: MatchConfig,
                 rejected_signatures: Iterable[str] = ()) -> MatchResult:
    res = MatchResult()
    used_b: set = set()
    used_g: set = set()
    rejected = set(rejected_signatures or ())

    match_one_to_one(bank_open, gl_open, cfg, res, used_b, used_g, rejected)
    if cfg.enable_one_to_many:
        match_aggregate(bank_open, gl_open, cfg, res, used_b, used_g, rejected, anchor_side="BANK")
    if cfg.enable_many_to_one:
        match_aggregate(gl_open, bank_open, cfg, res, used_g, used_b, rejected, anchor_side="GL")

    res.unmatched = _unmatched(bank_open, gl_open, used_b, used_g, cfg)
    groups = pd.DataFrame(res.groups)
    res.stats = {
        "proposals": len(res.groups),
        "by_match_type": groups["match_type"].value_counts().to_dict() if len(groups) else {},
        "bank_matched": len(used_b),
        "gl_matched": len(used_g),
        "bank_unmatched": int((res.unmatched["side"] == "BANK").sum()) if len(res.unmatched) else 0,
        "gl_unmatched": int((res.unmatched["side"] == "GL").sum()) if len(res.unmatched) else 0,
    }
    # Safety net for the acceptance criterion "No line is matched more than once in a run"
    links = pd.DataFrame(res.links)
    if len(links):
        dup = links.duplicated(["side", "line_id"]).sum()
        assert dup == 0, f"{dup} lines were matched more than once"
    return res


# --------------------------------------------------------------------------------------
# JDE write-back helpers
# --------------------------------------------------------------------------------------


def jde_reference_3(bank_statement_id: str, line_number: str) -> str:
    """Value for F0911 Reference 3 (GLR3, 8 chars): '<Bank Statement ID>-<Line Number>'."""
    return f"{bank_statement_id}-{line_number}"[:8]
