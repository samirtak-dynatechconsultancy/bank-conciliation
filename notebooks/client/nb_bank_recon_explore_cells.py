# Bank Reconciliation - nb_bank_recon_explore: ALL notebook cells (Steps 1-11)
# Copy each "# %% STEP n" block into its own notebook cell, in order.
# Steps 8 and 10 are SQL (warehouse SQL editor): 8 = sql/client/01 -> 02 -> 03, 10 = sql/client/99_bank_recon_checks.sql
# Fill in WAREHOUSE_WORKSPACE_ID and WAREHOUSE_NAME in Step 1 before Step 9.

# %% =====================================================================================
# STEP 1 - Connection settings + read the JDE source tables
# =========================================================================================
from pyspark.sql import functions as F

# --- Source: lakehouse holding the proddta JDE tables ----------------------------
SOURCE_WORKSPACE_ID = "f2f8c0b7-8734-4ba9-b50e-e85e393e1290"
SOURCE_ITEM_ID      = "26c0ea37-9386-4eac-ba77-66fb7ae2d79f"   # lakehouse (not the SQL endpoint)
SOURCE_SCHEMA       = "proddta"
BANK_TABLE          = "auto_bank_statement_detail_f09617"
GL_TABLE            = "account_ledger_f0911"

# --- Target: warehouse with the dbo.bank_recon_* objects ------------------------------
WAREHOUSE_WORKSPACE_ID = "<workspace id of the warehouse>"
WAREHOUSE_NAME         = "<warehouse name>"
# ----------------------------------------------------------------------------------

def read_source(table):
    """Read a Delta table from OneLake; the workspace is part of the path, so any workspace works."""
    path = (f"abfss://{SOURCE_WORKSPACE_ID}@onelake.dfs.fabric.microsoft.com/"
            f"{SOURCE_ITEM_ID}/Tables/{SOURCE_SCHEMA}/{table}")
    return spark.read.format("delta").load(path)

bank_sdf = read_source(BANK_TABLE)
gl_sdf   = read_source(GL_TABLE)

print(f"Bank: {bank_sdf.count():>10,} rows, {len(bank_sdf.columns)} columns")
print(f"GL:   {gl_sdf.count():>10,} rows, {len(gl_sdf.columns)} columns")


# %% =====================================================================================
# STEP 2 - Bank lines: pick the needed columns, apply the client's data rules
# =========================================================================================
def trimmed(col):
    """Text value without the padding spaces JDE adds (e.g. 'CR ' -> 'CR')."""
    return F.trim(F.col(col).cast("string"))

def as_id(col):
    """IDs stored as float (631.0) -> clean text '631'."""
    return F.col(col).cast("bigint").cast("string")

bank = bank_sdf.select(
    # --- primary key (identifies the line; used for locking and the JDE output) ---
    as_id("Bank Statement ID").alias("bank_statement_id"),
    trimmed("G_L Bank Account").alias("gl_bank_account"),
    F.col("Statement Date").cast("date").alias("statement_date"),
    as_id("Line Number _ General").alias("line_number"),
    # --- filter: 'R' = already reconciled in JDE ---
    (F.upper(F.coalesce(trimmed("Reconciliation Code"), F.lit(""))) == "R").alias("is_reconciled"),
    # --- matching: amount (stored in cents -> / 100; credits - debits = + in / - out) and date ---
    F.round((F.coalesce(F.col("Credits Entered"), F.lit(0))
             - F.coalesce(F.col("Debits Entered"), F.lit(0))) / 100, 2).cast("decimal(18,2)").alias("amount"),
    F.col("Date _ Cleared_Value").cast("date").alias("txn_date"),
    # --- shown to the reviewer (UI: Reference / Transaction Type) ---
    trimmed("Bank Statement Transaction Code").alias("tr_code"),
    trimmed("Misc Information").alias("description"),
    trimmed("External Transaction Type").alias("external_txn_type"),
    trimmed("Reference 1 _ JE Voucher Invoice etc").alias("bank_reference_1"),
    # --- data freshness for the UI overview ---
    F.col("LoadDate").alias("loaded_at"),
)
bank = bank.withColumn("line_id", F.concat_ws("|", F.lit("B"), "bank_statement_id", "gl_bank_account",
                                              F.date_format("statement_date", "yyyy-MM-dd"), "line_number"))

print("Total bank lines     :", f"{bank.count():,}")
print("Duplicate line_ids   :", bank.count() - bank.select("line_id").distinct().count())
print("Lines without a date :", bank.where(F.col("txn_date").isNull()).count())
print("Zero-amount lines    :", bank.where(F.col("amount") == 0).count())
print("\nBy transaction code and reconciled flag:")
(bank.groupBy("tr_code", "is_reconciled")
     .agg(F.count("*").alias("lines"), F.sum("amount").alias("total_amount"),
          F.min("txn_date").alias("first_date"), F.max("txn_date").alias("last_date"))
     .orderBy("tr_code", "is_reconciled").show(truncate=False))


# %% =====================================================================================
# STEP 3 - GL lines: keep bank-account + AA-ledger lines, pick the needed columns
# =========================================================================================
def nonblank(col):
    """Trimmed text, or NULL when empty (so it is skipped when joining descriptions)."""
    t = trimmed(col)
    return F.when(t == "", None).otherwise(t)

# The GL table is the WHOLE general ledger -> keep only the accounts that appear on bank statements
bank_accounts = sorted(r[0] for r in bank.select("gl_bank_account").distinct().collect())
print("Bank accounts:", bank_accounts)

gl_bankacct = gl_sdf.where(trimmed("Account ID").isin(bank_accounts))
gl_raw = gl_bankacct.where(trimmed("Ledger Types") == "AA")   # AA = money; AU = units, never matched

gl = gl_raw.select(
    # --- primary key (7 parts) ---
    trimmed("Document Type").alias("doc_type"),
    as_id("Document _Voucher Invoice etc").alias("doc_number"),
    trimmed("Document Company").alias("doc_company"),
    F.to_date(trimmed("Date For G_L _and Voucher Julian")).alias("gl_date"),      # stored as text 'yyyy-MM-dd'
    as_id("Journal Entry Line Number").alias("je_line_number"),
    trimmed("Ledger Types").alias("ledger_type"),
    F.coalesce(trimmed("Line Extension Code"), F.lit("")).alias("line_ext_code"), # NULL today - OPEN_ISSUES #1
    # --- matching: account, amount (already in currency units on the GL side) ---
    trimmed("Account ID").alias("gl_bank_account"),
    F.round(F.col("Amount"), 2).cast("decimal(18,2)").alias("amount"),
    # --- filter ---
    (F.upper(F.coalesce(trimmed("Reconciled Code"), F.lit(""))) == "R").alias("is_reconciled"),
    # --- shown to the reviewer (UI: Name - Alpha / Remark / Document / Batch / Account / BU) ---
    F.concat_ws(" / ", nonblank("Name Alpha Explanation"), nonblank("Name Remark Explanation")).alias("description"),
    nonblank("Name Alpha Explanation").alias("gl_alpha_name"),
    nonblank("Name Remark Explanation").alias("gl_remark"),
    as_id("Batch Number").alias("batch_number"),
    trimmed("Account Number Input _Mode Unknown").alias("account_number"),
    trimmed("Business Unit").alias("business_unit"),
    # --- data freshness for the UI overview ---
    F.col("LoadDate").alias("loaded_at"),
)
gl = (gl.withColumn("txn_date", F.col("gl_date"))
        .withColumn("line_id", F.concat_ws("|", F.lit("G"), "doc_type", "doc_number", "doc_company",
                                           F.date_format("gl_date", "yyyy-MM-dd"), "je_line_number",
                                           "ledger_type", "line_ext_code")))

total, on_bank = gl_sdf.count(), gl_bankacct.count()
print(f"\nGL lines in table         : {total:>10,}")
print(f"  on other accounts (out) : {total - on_bank:>10,}")
print(f"  on bank accounts        : {on_bank:>10,}")
print(f"    not ledger AA (out)   : {on_bank - gl.count():>10,}")
print(f"    kept (AA, bank accts) : {gl.count():>10,}")
print("\nDuplicate line_ids   :", gl.count() - gl.select("line_id").distinct().count())
print("Lines without a date :", gl.where(F.col("gl_date").isNull()).count())
print("Zero-amount lines    :", gl.where(F.col("amount") == 0).count())
print("\nUI fields filled (sample):")
gl.select("doc_type", "doc_number", "gl_alpha_name", "gl_remark", "batch_number", "account_number",
          "business_unit", "loaded_at").show(5, truncate=40)


# %% =====================================================================================
# STEP 4 (optional) - Preview: open lines per month + how many bank lines have a 1:1 candidate
# =========================================================================================
bank_open = bank.where(~F.col("is_reconciled") & (F.col("amount") != 0))
gl_open   = gl.where(~F.col("is_reconciled") & (F.col("amount") != 0))
print(f"Open bank lines: {bank_open.count():,}   Open GL lines: {gl_open.count():,}")

by_month = (bank_open.groupBy(F.date_format("txn_date", "yyyy-MM").alias("month")).agg(F.count("*").alias("bank_open"))
            .join(gl_open.groupBy(F.date_format("txn_date", "yyyy-MM").alias("month")).agg(F.count("*").alias("gl_open")),
                  "month", "full")
            .fillna(0).orderBy("month"))
by_month.show(60)


# %% =====================================================================================
# STEP 5 - 1:1 matching: exact date first, then +-1 ... +-5 days
#          Pairs with ONE side already 'R' are included and flagged; pairs with BOTH sides 'R' are skipped.
# =========================================================================================
import numpy as np
import pandas as pd

MAX_TOL = 5

# 5a. Lines that can take part (zero amounts never match; no GL older than the bank data)
first_bank_date = bank.agg(F.min("txn_date")).first()[0]
b = (bank.where(F.col("amount") != 0)
         .select("line_id", "gl_bank_account", "amount", "txn_date", "is_reconciled",
                 "bank_statement_id", "line_number", "tr_code", "description")
         .toPandas())
g = (gl.where((F.col("amount") != 0) &
              (F.col("txn_date") >= F.date_sub(F.lit(first_bank_date), MAX_TOL)))
       .select("line_id", "gl_bank_account", "amount", "txn_date", "is_reconciled",
               "doc_type", "doc_number", "doc_company", "description")
       .toPandas())
for df in (b, g):
    df["cents"] = (pd.to_numeric(df["amount"]) * 100).round().astype("int64")   # exact comparison in cents
    df["txn_date"] = pd.to_datetime(df["txn_date"])

# Lines already in a pending / approved / exception proposal of an earlier run are skipped (Step 11 fills 'locked')
locked = globals().get("locked", set())
b = b[~b["line_id"].isin(locked)]
g = g[~g["line_id"].isin(locked)]
print(f"Bank lines: {len(b):,} ({(~b.is_reconciled).sum():,} open)   "
      f"GL lines: {len(g):,} ({(~g.is_reconciled).sum():,} open, from {first_bank_date} - {MAX_TOL} days)   "
      f"locked by earlier runs: {len(locked):,}")

# 5b. Candidate pairs: same account + same amount + within 5 days
allc = b.merge(g, on=["gl_bank_account", "cents"], suffixes=("_b", "_g"))
allc["day_diff"] = (allc["txn_date_g"] - allc["txn_date_b"]).dt.days       # + = GL after bank (T+n)
allc["gap"] = allc["day_diff"].abs()
allc = allc[allc["gap"] <= MAX_TOL]

both_r = allc["is_reconciled_b"] & allc["is_reconciled_g"]
rr_bank, rr_gl = set(allc.loc[both_r, "line_id_b"]), set(allc.loc[both_r, "line_id_g"])
cand = allc[~both_r]                                                          # rule: never both 'R'
taken_elsewhere = ((cand["is_reconciled_g"] & cand["line_id_g"].isin(rr_gl)) |  # safeguard: the 'R' side
                   (cand["is_reconciled_b"] & cand["line_id_b"].isin(rr_bank))) # already pairs with an 'R' line
cand = cand[~taken_elsewhere].copy()
cand["recon_state"] = np.select(
    [~cand["is_reconciled_b"] & ~cand["is_reconciled_g"], cand["is_reconciled_b"]],
    ["BOTH_OPEN", "BANK_R_GL_OPEN"], "GL_R_BANK_OPEN")
cand["state_rank"] = (cand["recon_state"] != "BOTH_OPEN").astype(int)          # open pairs first
print(f"Pairs within {MAX_TOL} days: {len(allc):,}  ->  both 'R' (skipped): {both_r.sum():,}  "
      f"->  'R' side already paired (skipped): {taken_elsewhere.sum():,}  ->  candidates: {len(cand):,}")

# 5c. Tiered assignment: tier 0 = same day, then 1 ... 5 days; each line used at most once
used_b, used_g, matches = set(), set(), []
for tier in range(MAX_TOL + 1):
    t = cand[(cand["gap"] <= tier) & ~cand["line_id_b"].isin(used_b) & ~cand["line_id_g"].isin(used_g)]
    if t.empty:
        continue
    n_b = t.groupby("line_id_b")["line_id_g"].transform("count")     # how many partners each line has here
    n_g = t.groupby("line_id_g")["line_id_b"].transform("count")
    t = t.assign(ambiguous=(n_b > 1) | (n_g > 1)).sort_values(
        ["gap", "state_rank", "txn_date_b", "line_id_b", "txn_date_g", "line_id_g"])
    for r in t.itertuples(index=False):
        if r.line_id_b in used_b or r.line_id_g in used_g:
            continue
        used_b.add(r.line_id_b)
        used_g.add(r.line_id_g)
        matches.append({**r._asdict(), "tier": tier})

m = pd.DataFrame(matches, columns=list(cand.columns) + ["ambiguous", "tier"])   # also works with 0 matches
m["match_type"] = np.where(m["tier"] == 0, "EXACT", "TOLERANCE_T" + m["tier"].astype(str))
m["match_rule"] = np.where(m["tier"] == 0, "Rule 2 - Exact match",
                           "Rule " + (m["tier"] + 2).astype(str) + " - Tolerance T+/-" + m["tier"].astype(str) + " (1:1)")
m["confidence"] = np.where(m["ambiguous"], "MEDIUM", "HIGH")

print(f"\n1:1 matches: {len(m):,}")
if len(m):
    print(pd.crosstab(m["match_rule"], m["recon_state"], margins=True, margins_name="Total"))
    print("\nBy confidence:")
    print(pd.crosstab(m["confidence"], m["recon_state"], margins=True, margins_name="Total"))


# %% =====================================================================================
# STEP 6 - Split payments: 1:M (1 bank = sum of GL lines) and M:1 (sum of bank lines = 1 GL line)
#          Only lines still unmatched after Step 5 AND open on both sides. Every result is POTENTIAL.
# =========================================================================================
import time

AGG_MAX_LINES      = 5        # at most 5 lines combined into one sum
AGG_MAX_CANDIDATES = 25       # per anchor line, look at the 25 closest-dated candidates only
AGG_NODE_LIMIT     = 50_000   # search budget per anchor line (keeps the run fast)
AGG_MIN_PART_SHARE = 0.01     # every line in a sum must be >= 1% of the anchor amount (no tiny "fillers")

def subset_sum(target, amounts, gaps, max_lines, node_limit):
    """Find 2..max_lines amounts that add up EXACTLY to target (all values in cents, positive).
    Prefers fewest lines, then smallest total date gap. Returns (indexes or None, search_complete)."""
    best = None                                   # pairs: fast lookup instead of a search
    seen = {}
    for j, a in enumerate(amounts):
        for i in seen.get(target - a, ()):
            if best is None or gaps[i] + gaps[j] < best[1]:
                best = ([i, j], gaps[i] + gaps[j])
        seen.setdefault(a, []).append(j)
    if best:
        return best[0], True

    n = len(amounts)                              # 3..max_lines: depth-first search with pruning
    suffix = [0] * (n + 1)
    for i in range(n - 1, -1, -1):
        suffix[i] = suffix[i + 1] + amounts[i]
    budget = [node_limit]
    for size in range(3, max_lines + 1):
        found = [None]
        def dfs(start, remaining, picked, gap_sum):
            budget[0] -= 1
            if budget[0] <= 0:
                return
            k = size - len(picked)
            if k == 0:
                if remaining == 0 and (found[0] is None or gap_sum < found[0][1]):
                    found[0] = (list(picked), gap_sum)
                return
            for i in range(start, n - k + 1):
                if amounts[i] > remaining:
                    continue                      # too big (amounts are sorted largest first)
                if suffix[i] < remaining:
                    break                         # everything left together is still too small
                picked.append(i)
                dfs(i + 1, remaining - amounts[i], picked, gap_sum + gaps[i])
                picked.pop()
                if budget[0] <= 0:
                    return
        dfs(0, target, [], 0)
        if found[0]:
            return found[0][0], True
        if budget[0] <= 0:
            return None, False
    return None, True

def match_aggregate(anchors, others, used_anchor, used_other, kind):
    """For each anchor line, find 2-5 lines on the other side whose amounts add up EXACTLY to the anchor.
    A part must be: same account, same direction, smaller than the anchor but >= AGG_MIN_PART_SHARE of it,
    within the current date window (widens 0 -> MAX_TOL days), and not already matched."""
    by_acct = {}
    for r in others.itertuples(index=False):
        by_acct.setdefault(r.gl_bank_account, []).append((r.line_id, int(r.cents), r.txn_date))
    anchor_recs = sorted(((r.line_id, r.gl_bank_account, int(r.cents), r.txn_date)
                          for r in anchors.itertuples(index=False)), key=lambda x: -abs(x[2]))
    failed, found = {}, []
    for tier in range(MAX_TOL + 1):
        for a_id, acct, a_cents, a_date in anchor_recs:
            if a_id in used_anchor:
                continue
            target = abs(a_cents)
            min_part = target * AGG_MIN_PART_SHARE
            pool = []
            for lid, c, d in by_acct.get(acct, ()):
                if lid in used_other:
                    continue
                if (c > 0) != (a_cents > 0):              # same direction only
                    continue
                if not (min_part <= abs(c) < target):     # smaller than the anchor, but not a tiny filler
                    continue
                gap = abs((d - a_date).days)
                if gap <= tier:
                    pool.append((lid, abs(c), gap, d))
            if len(pool) < 2 or sum(p[1] for p in pool) < target:
                continue
            if len(pool) > AGG_MAX_CANDIDATES:
                pool = sorted(pool, key=lambda p: (p[2], p[3]))[:AGG_MAX_CANDIDATES]
            ids = frozenset(p[0] for p in pool)
            if a_id in failed and ids <= failed[a_id]:
                continue                                  # window widened but nothing new to try
            pool.sort(key=lambda p: -p[1])
            pick, complete = subset_sum(target, [p[1] for p in pool], [p[2] for p in pool],
                                        AGG_MAX_LINES, AGG_NODE_LIMIT)
            if pick is None:
                if complete:
                    failed[a_id] = ids
                continue
            parts = [pool[i] for i in pick]
            used_anchor.add(a_id)
            used_other.update(p[0] for p in parts)
            found.append({"match_type": kind, "anchor_line_id": a_id, "gl_bank_account": acct,
                          "amount": a_cents / 100, "tier": tier, "n_parts": len(parts),
                          "max_gap": max(p[2] for p in parts), "part_line_ids": [p[0] for p in parts]})
    return found

# Inputs: open on both sides, not matched in Step 5
b_rest = b[~b["is_reconciled"] & ~b["line_id"].isin(used_b)]
g_rest = g[~g["is_reconciled"] & ~g["line_id"].isin(used_g)]
print(f"Still unmatched and open:  bank {len(b_rest):,}   GL {len(g_rest):,}")

t0 = time.time()
one_to_many = match_aggregate(b_rest, g_rest, used_b, used_g, "ONE_TO_MANY")   # anchor = bank line
many_to_one = match_aggregate(g_rest, b_rest, used_g, used_b, "MANY_TO_ONE")   # anchor = GL line
print(f"Search took {time.time() - t0:.1f}s")

agg = pd.DataFrame(one_to_many + many_to_one)
if len(agg):
    window = np.where(agg["tier"] == 0, "same date", "within +/-" + agg["tier"].astype(str) + " days")
    agg["match_rule"] = np.where(
        agg["match_type"] == "ONE_TO_MANY",
        "Rule 8 - One-to-many (1:M, potential): 1 bank line = sum of " + agg["n_parts"].astype(str) + " GL lines, " + window,
        "Rule 9 - Many-to-one (M:1, potential): " + agg["n_parts"].astype(str) + " bank lines sum to 1 GL line, " + window)
    print(f"\nSplit-payment matches: {len(agg):,}")
    print(pd.crosstab(agg["match_type"], agg["n_parts"], margins=True, margins_name="Total"))
else:
    print("No split-payment matches found.")
print(f"\nLeft unmatched after Steps 5 + 6:  bank open {(~b['is_reconciled'] & ~b['line_id'].isin(used_b)).sum():,}"
      f"   GL open {(~g['is_reconciled'] & ~g['line_id'].isin(used_g)).sum():,}")


# %% =====================================================================================
# STEP 7 - Combine Steps 5 + 6 into the final result (in memory - nothing is written yet)
import hashlib, uuid, datetime as dt

RUN_ID      = str(uuid.uuid4())
RUN_STARTED = dt.datetime.utcnow()
KEY_COLS = ["bank_statement_id", "statement_date", "line_number", "tr_code",                                # F09617 key
            "doc_type", "doc_number", "doc_company", "gl_date", "je_line_number", "ledger_type", "line_ext_code"]  # F0911 key
UI_COLS  = ["external_txn_type", "bank_reference_1",                                                         # bank display
            "gl_alpha_name", "gl_remark", "batch_number", "account_number", "business_unit"]                 # GL display

def signature(bank_ids, gl_ids):
    """Fingerprint of the exact set of lines - a rejected combination is never proposed again."""
    raw = "||".join(sorted(bank_ids)) + "##" + "||".join(sorted(gl_ids))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()

def line_record(line_id, x, side):
    """One line in the shape of bank_recon_match_line (keys + display columns)."""
    return dict(side=side, line_id=line_id, gl_bank_account=x["gl_bank_account"], txn_date=x["txn_date"],
                amount=x["amount"], is_reconciled=bool(x["is_reconciled"]),
                description=(x["description"] or "")[:500],
                **{c: x.get(c) for c in KEY_COLS + UI_COLS})

# 7a. Full details (keys, dates, descriptions, UI fields) of every bank / GL line, looked up by line_id
bank_d = (bank.select("line_id", "gl_bank_account", "txn_date", "amount", "is_reconciled", "description",
                      "bank_statement_id", "statement_date", "line_number", "tr_code",
                      "external_txn_type", "bank_reference_1", "loaded_at")
              .toPandas().set_index("line_id"))
gl_d = (gl.select("line_id", "gl_bank_account", "txn_date", "amount", "is_reconciled", "description",
                  "doc_type", "doc_number", "doc_company", "gl_date", "je_line_number", "ledger_type", "line_ext_code",
                  "gl_alpha_name", "gl_remark", "batch_number", "account_number", "business_unit", "loaded_at")
          .toPandas().set_index("line_id"))
for d in (bank_d, gl_d):
    d["txn_date"] = pd.to_datetime(d["txn_date"])
    d["amount"] = d["amount"].astype(float)

# 7b. Every match as (header fields, bank line ids, GL line ids) - 1:1 from Step 5, 1:M / M:1 from Step 6
groups = []
for r in m.itertuples(index=False):
    groups.append(dict(match_type=r.match_type, match_rule=r.match_rule, match_category="1:1",
                       confidence=r.confidence, recon_state=r.recon_state, tolerance_days=int(r.tier),
                       bank_ids=[r.line_id_b], gl_ids=[r.line_id_g],
                       note="Several lines with the same amount inside the window - check pairing" if r.ambiguous else None))
for r in agg.itertuples(index=False):
    one_to_many = r.match_type == "ONE_TO_MANY"
    groups.append(dict(match_type=r.match_type, match_rule=r.match_rule,
                       match_category="1:M" if one_to_many else "M:1",
                       confidence="POTENTIAL", recon_state="BOTH_OPEN", tolerance_days=int(r.tier),
                       bank_ids=[r.anchor_line_id] if one_to_many else list(r.part_line_ids),
                       gl_ids=list(r.part_line_ids) if one_to_many else [r.anchor_line_id],
                       note=f"{r.n_parts} lines add up to the {'bank' if one_to_many else 'GL'} amount - review before approving"))

# 7c. Warehouse rows: proposals, match lines, and - for MEDIUM matches - the alternative candidates
proposal_rows, line_rows, candidate_rows = [], [], []
for grp in groups:
    match_id = str(uuid.uuid4())
    bl, gll = bank_d.loc[grp["bank_ids"]], gl_d.loc[grp["gl_ids"]]
    proposal_rows.append(dict(
        match_id=match_id, run_id=RUN_ID, match_type=grp["match_type"], match_rule=grp["match_rule"],
        match_category=grp["match_category"], confidence=grp["confidence"], recon_state=grp["recon_state"],
        tolerance_days=grp["tolerance_days"],
        max_date_gap_days=max(abs((bd - gd).days) for bd in bl["txn_date"] for gd in gll["txn_date"]),
        gl_bank_account=bl["gl_bank_account"].iloc[0],
        bank_line_count=len(bl), gl_line_count=len(gll),
        bank_amount=round(bl["amount"].sum(), 2), gl_amount=round(gll["amount"].sum(), 2),
        group_signature=signature(grp["bank_ids"], grp["gl_ids"]), note=grp["note"],
        status="PENDING", decided_by=None, decided_at=None, decision_comment=None,
        export_batch_id=None, exported_at=None, created_at=RUN_STARTED))
    for side, det in (("BANK", bl), ("GL", gll)):
        for line_id, x in det.iterrows():
            line_rows.append(dict(match_id=match_id, run_id=RUN_ID, **line_record(line_id, x, side)))

    # Exception screen: every line that was an equally valid partner at the same tier (incl. the chosen one)
    if grp["confidence"] == "MEDIUM":
        b_id, g_id, tier = grp["bank_ids"][0], grp["gl_ids"][0], grp["tolerance_days"]
        alt = cand[(cand["gap"] <= tier) & ((cand["line_id_b"] == b_id) | (cand["line_id_g"] == g_id))]
        seen, options = set(), []
        for a in alt.itertuples(index=False):
            for side, lid, det in (("GL", a.line_id_g, gl_d), ("BANK", a.line_id_b, bank_d)):
                # GL alternatives of this bank line, and bank alternatives of this GL line
                if (side == "GL" and a.line_id_b != b_id) or (side == "BANK" and a.line_id_g != g_id):
                    continue
                if (side, lid) in seen:
                    continue
                seen.add((side, lid))
                options.append(dict(match_id=match_id, run_id=RUN_ID,
                                    is_proposed=lid in (b_id, g_id), gap_days=int(a.gap),
                                    **line_record(lid, det.loc[lid], side)))
        # keep only the side(s) with a real choice (more than one line)
        sides = pd.Series([o["side"] for o in options]).value_counts()
        candidate_rows += [o for o in options if sides[o["side"]] > 1]

proposals   = pd.DataFrame(proposal_rows)
match_lines = pd.DataFrame(line_rows)
candidates  = pd.DataFrame(candidate_rows)

# 7d. Unmatched = OPEN lines in scope that are in no match, with the nearest same-amount line on the other side
def unmatched_side(own, other, used, side, other_name, details):
    left = own[~own["is_reconciled"] & ~own["line_id"].isin(used)]
    near = left[["line_id", "gl_bank_account", "cents", "txn_date"]].merge(
        other[["gl_bank_account", "cents", "txn_date"]], on=["gl_bank_account", "cents"], suffixes=("", "_o"))
    near["gap"] = (near["txn_date"] - near["txn_date_o"]).dt.days.abs()
    nearest = near.groupby("line_id")["gap"].min()
    out = details.loc[left["line_id"]].reset_index()
    out["side"] = side
    out["nearest_same_amount_gap_days"] = out["line_id"].map(nearest)
    out["reason"] = np.where(
        out["nearest_same_amount_gap_days"].isna(), f"No {other_name} line with this amount",
        np.where(out["nearest_same_amount_gap_days"] > MAX_TOL,
                 f"Same amount on {other_name} side, but more than {MAX_TOL} days apart",
                 f"Same amount on {other_name} side within {MAX_TOL} days, but that line is reconciled or used by another match"))
    out["description"] = out["description"].fillna("").str.slice(0, 500)
    return out

unmatched = pd.concat([unmatched_side(b, g, used_b, "BANK", "GL", bank_d),
                       unmatched_side(g, b, used_g, "GL", "bank", gl_d)], ignore_index=True)
unmatched["run_id"] = RUN_ID

# 7e. Per-account statistics for the UI overview (one row per bank account)
run_account = pd.DataFrame({"gl_bank_account": sorted(bank_accounts)})
cnt = lambda df, mask=None: (df if mask is None else df[mask]).groupby("gl_bank_account").size()
run_account["run_id"]         = RUN_ID
run_account["bank_lines"]     = run_account["gl_bank_account"].map(cnt(bank_d)).fillna(0).astype(int)
run_account["gl_lines"]       = run_account["gl_bank_account"].map(cnt(gl_d)).fillna(0).astype(int)
run_account["bank_open"]      = run_account["gl_bank_account"].map(cnt(b, ~b["is_reconciled"])).fillna(0).astype(int)
run_account["gl_open"]        = run_account["gl_bank_account"].map(cnt(g, ~g["is_reconciled"])).fillna(0).astype(int)
run_account["proposals"]      = run_account["gl_bank_account"].map(cnt(proposals) if len(proposals) else {}).fillna(0).astype(int)
run_account["bank_unmatched"] = run_account["gl_bank_account"].map(cnt(unmatched, unmatched["side"] == "BANK")).fillna(0).astype(int)
run_account["gl_unmatched"]   = run_account["gl_bank_account"].map(cnt(unmatched, unmatched["side"] == "GL")).fillna(0).astype(int)
run_account["period_end"]     = run_account["gl_bank_account"].map(bank_d.groupby("gl_bank_account")["statement_date"].max())
run_account["period_start"]   = run_account["gl_bank_account"].map(bank_d.groupby("gl_bank_account")["statement_date"].min())
run_account["bank_loaded_at"] = run_account["gl_bank_account"].map(bank_d.groupby("gl_bank_account")["loaded_at"].max())
run_account["gl_loaded_at"]   = run_account["gl_bank_account"].map(gl_d.groupby("gl_bank_account")["loaded_at"].max())

# 7f. Checks - must all pass before anything is written
n_dup = int(match_lines.duplicated(["side", "line_id"]).sum()) if len(match_lines) else 0
n_unbalanced = int((proposals["bank_amount"] != proposals["gl_amount"]).sum()) if len(proposals) else 0
open_b, open_g = int((~b["is_reconciled"]).sum()), int((~g["is_reconciled"]).sum())
matched_open_b = int(((match_lines["side"] == "BANK") & ~match_lines["is_reconciled"]).sum()) if len(match_lines) else 0
matched_open_g = int(((match_lines["side"] == "GL") & ~match_lines["is_reconciled"]).sum()) if len(match_lines) else 0
unm_b, unm_g = int((unmatched["side"] == "BANK").sum()), int((unmatched["side"] == "GL").sum())
n_medium = int((proposals["confidence"] == "MEDIUM").sum()) if len(proposals) else 0
n_medium_with_cands = candidates["match_id"].nunique() if len(candidates) else 0

print(f"Run id: {RUN_ID}")
print(f"Proposals: {len(proposals):,}   match lines: {len(match_lines):,}   unmatched lines: {len(unmatched):,}   "
      f"exception candidates: {len(candidates):,}")
print(f"Check - lines used twice           : {n_dup}  (must be 0)")
print(f"Check - proposals not balancing     : {n_unbalanced}  (must be 0)")
print(f"Check - open bank: {open_b:,} = matched {matched_open_b:,} + unmatched {unm_b:,}  -> "
      f"{'OK' if open_b == matched_open_b + unm_b else 'MISMATCH'}")
print(f"Check - open GL  : {open_g:,} = matched {matched_open_g:,} + unmatched {unm_g:,}  -> "
      f"{'OK' if open_g == matched_open_g + unm_g else 'MISMATCH'}")
print(f"Check - MEDIUM matches with candidates: {n_medium_with_cands} of {n_medium}  -> "
      f"{'OK' if n_medium_with_cands == n_medium else 'MISMATCH'}")
if len(proposals):
    print("\nProposals by rule and recon_state:")
    print(pd.crosstab(proposals["match_rule"].str.slice(0, 45), proposals["recon_state"], margins=True, margins_name="Total"))
print("\nPer account (UI overview):")
print(run_account[["gl_bank_account", "bank_lines", "gl_lines", "bank_open", "gl_open", "proposals",
                   "bank_unmatched", "gl_unmatched", "period_start", "period_end"]].to_string(index=False))


# %% =====================================================================================
# STEP 9 - Write the results to the warehouse (dbo.bank_recon_*) - run_log goes LAST
# =========================================================================================
import json
from decimal import Decimal
from pyspark.sql import types as T
import com.microsoft.spark.fabric                      # registers .synapsesql on Spark readers/writers
from com.microsoft.spark.fabric.Constants import Constants

TRIGGERED_BY = "manual - nb_bank_recon_explore"

def _conv(v, t):
    """pandas value -> plain Python value of the Spark type (None for empty)."""
    if v is None or (not isinstance(v, (str, bool)) and pd.isna(v)):
        return None
    if isinstance(t, T.DateType):      return pd.Timestamp(v).date()
    if isinstance(t, T.TimestampType): return pd.Timestamp(v).to_pydatetime()
    if isinstance(t, T.DecimalType):   return Decimal(str(round(float(v), 2)))
    if isinstance(t, T.IntegerType):   return int(v)
    if isinstance(t, T.BooleanType):   return bool(v)
    return str(v)

def wh_append(pdf, table, schema):
    """Append a pandas DataFrame to dbo.<table> in the warehouse (any workspace)."""
    if pdf is None or len(pdf) == 0:
        print(f"  dbo.{table}: nothing to write")
        return 0
    cols = [f.name for f in schema.fields]
    rows = [tuple(_conv(v, f.dataType) for v, f in zip(rec, schema.fields))
            for rec in pdf.reindex(columns=cols).itertuples(index=False, name=None)]
    (spark.createDataFrame(rows, schema).write.mode("append")
          .option(Constants.WorkspaceId, WAREHOUSE_WORKSPACE_ID)
          .synapsesql(f"{WAREHOUSE_NAME}.dbo.{table}"))
    print(f"  dbo.{table}: {len(rows):,} rows written")
    return len(rows)

# Column layouts - SAME ORDER as the tables (01_bank_recon_tables.sql + columns added by 03_bank_recon_ui.sql)
S, D, I, N, TS, B = T.StringType(), T.DateType(), T.IntegerType(), T.DecimalType(18, 2), T.TimestampType(), T.BooleanType()
fld = lambda n, t: T.StructField(n, t, True)
KEYS = [fld("bank_statement_id", S), fld("statement_date", D), fld("line_number", S), fld("tr_code", S),
        fld("doc_type", S), fld("doc_number", S), fld("doc_company", S), fld("gl_date", D),
        fld("je_line_number", S), fld("ledger_type", S), fld("line_ext_code", S)]
UI = [fld("external_txn_type", S), fld("bank_reference_1", S), fld("gl_alpha_name", S), fld("gl_remark", S),
      fld("batch_number", S), fld("account_number", S), fld("business_unit", S)]
SCHEMA_PROPOSAL = T.StructType([fld(n, t) for n, t in [
    ("match_id", S), ("run_id", S), ("match_type", S), ("match_rule", S), ("match_category", S),
    ("confidence", S), ("recon_state", S), ("tolerance_days", I), ("max_date_gap_days", I),
    ("gl_bank_account", S), ("bank_line_count", I), ("gl_line_count", I), ("bank_amount", N), ("gl_amount", N),
    ("group_signature", S), ("note", S), ("status", S), ("decided_by", S), ("decided_at", TS),
    ("decision_comment", S), ("export_batch_id", S), ("exported_at", TS), ("created_at", TS)]])
SCHEMA_LINE = T.StructType([fld(n, t) for n, t in [
    ("match_id", S), ("run_id", S), ("side", S), ("line_id", S), ("gl_bank_account", S),
    ("txn_date", D), ("amount", N), ("is_reconciled", B), ("description", S)]] + KEYS + UI)
SCHEMA_UNMATCHED = T.StructType([fld(n, t) for n, t in [
    ("run_id", S), ("side", S), ("line_id", S), ("gl_bank_account", S), ("txn_date", D),
    ("amount", N), ("description", S)]] + KEYS
    + [fld("nearest_same_amount_gap_days", I), fld("reason", S)] + UI)
SCHEMA_CANDIDATE = T.StructType([fld(n, t) for n, t in [
    ("match_id", S), ("run_id", S), ("side", S), ("line_id", S), ("is_proposed", B), ("gap_days", I),
    ("gl_bank_account", S), ("txn_date", D), ("amount", N), ("is_reconciled", B), ("description", S)]] + KEYS + UI)
SCHEMA_RUN_ACCOUNT = T.StructType([fld(n, t) for n, t in [
    ("run_id", S), ("gl_bank_account", S), ("bank_lines", I), ("gl_lines", I), ("bank_open", I), ("gl_open", I),
    ("proposals", I), ("bank_unmatched", I), ("gl_unmatched", I), ("period_end", D),
    ("bank_loaded_at", TS), ("gl_loaded_at", TS), ("period_start", D)]])   # period_start added last (03 ALTER)
SCHEMA_ACCOUNT = T.StructType([fld(n, t) for n, t in [
    ("gl_bank_account", S), ("gl_account_number", S), ("display_name", S), ("bank_account_number", S),
    ("sort_order", I), ("is_active", B), ("first_seen_run_id", S), ("first_seen_at", TS),
    ("updated_by", S), ("updated_at", TS)]])
SCHEMA_RUN = T.StructType([fld(n, t) for n, t in [
    ("run_id", S), ("triggered_by", S), ("bank_accounts", S), ("date_from", D), ("date_to", D),
    ("status", S), ("started_at", TS), ("finished_at", TS),
    ("bank_total", I), ("gl_total", I), ("bank_reconciled_skipped", I), ("gl_reconciled_skipped", I),
    ("bank_locked_skipped", I), ("gl_locked_skipped", I), ("bank_in_scope", I), ("gl_in_scope", I),
    ("proposals", I), ("bank_matched", I), ("gl_matched", I), ("bank_unmatched", I), ("gl_unmatched", I),
    ("config_json", S), ("error_message", S)]])

# 9a. Safety: Step 7 checks passed, and this run id has not been written already
assert n_dup == 0 and n_unbalanced == 0, "Step 7 checks failed - nothing written"
written_runs = globals().setdefault("written_runs", set())
assert RUN_ID not in written_runs, "This run is already written - re-run Step 7 for a new run id"

# 9b. Can we reach the warehouse? (reads the settings table)
print("Warehouse settings rows:",
      spark.read.option(Constants.WorkspaceId, WAREHOUSE_WORKSPACE_ID)
           .synapsesql(f"{WAREHOUSE_NAME}.dbo.bank_recon_config").count())

# 9b2. Accounts found in the data that the account master does not know yet -> add them (nothing hard-coded).
#      GL account number = the most frequent F0911 Account Number of that account. Name / bank number stay empty.
known = set(spark.read.option(Constants.WorkspaceId, WAREHOUSE_WORKSPACE_ID)
                 .synapsesql(f"{WAREHOUSE_NAME}.dbo.bank_recon_account")
                 .select("gl_bank_account").toPandas()["gl_bank_account"])
gl_acct_no = (gl_d.dropna(subset=["account_number"]).groupby("gl_bank_account")["account_number"]
                  .agg(lambda x: x.value_counts().index[0]))
new_accounts = pd.DataFrame([dict(gl_bank_account=a, gl_account_number=gl_acct_no.get(a), display_name=None,
                                  bank_account_number=None, sort_order=None, is_active=True,
                                  first_seen_run_id=RUN_ID, first_seen_at=RUN_STARTED, updated_by=None, updated_at=None)
                             for a in bank_accounts if a not in known])
print(f"Accounts: {len(known)} known, {len(new_accounts)} new")

# 9c. The run_log row
locked_set = globals().get("locked", set())
run_row = dict(
    run_id=RUN_ID, triggered_by=TRIGGERED_BY, bank_accounts=",".join(bank_accounts),
    date_from=None, date_to=None, started_at=RUN_STARTED,
    bank_total=len(bank_d), gl_total=len(gl_d),
    bank_reconciled_skipped=int(bank_d["is_reconciled"].sum()), gl_reconciled_skipped=int(gl_d["is_reconciled"].sum()),
    bank_locked_skipped=len(locked_set & set(bank_d.index)), gl_locked_skipped=len(locked_set & set(gl_d.index)),
    bank_in_scope=open_b, gl_in_scope=open_g, proposals=len(proposals),
    bank_matched=int((match_lines["side"] == "BANK").sum()) if len(match_lines) else 0,
    gl_matched=int((match_lines["side"] == "GL").sum()) if len(match_lines) else 0,
    bank_unmatched=unm_b, gl_unmatched=unm_g,
    config_json=json.dumps(dict(max_tolerance_days=MAX_TOL, aggregate_max_lines=AGG_MAX_LINES,
                                aggregate_max_candidates=AGG_MAX_CANDIDATES, aggregate_min_part_share=AGG_MIN_PART_SHARE,
                                aggregate_search_node_limit=AGG_NODE_LIMIT, gl_ledger_types="AA", bank_amount_divisor=100)))

# 9d. Write - run_log LAST: the views only show runs with a COMPLETED row, so a failure leaves nothing visible
try:
    wh_append(new_accounts, "bank_recon_account",        SCHEMA_ACCOUNT)
    wh_append(unmatched,   "bank_recon_unmatched_line",  SCHEMA_UNMATCHED)
    wh_append(match_lines, "bank_recon_match_line",      SCHEMA_LINE)
    wh_append(candidates,  "bank_recon_match_candidate", SCHEMA_CANDIDATE)
    wh_append(run_account, "bank_recon_run_account",     SCHEMA_RUN_ACCOUNT)
    wh_append(proposals,   "bank_recon_match_proposal",  SCHEMA_PROPOSAL)
    run_row.update(status="COMPLETED", finished_at=dt.datetime.utcnow(), error_message=None)
    wh_append(pd.DataFrame([run_row]), "bank_recon_run_log", SCHEMA_RUN)
    written_runs.add(RUN_ID)
    print(f"\nRun {RUN_ID} COMPLETED")
except Exception as e:
    run_row.update(status="FAILED", finished_at=dt.datetime.utcnow(), error_message=str(e)[:4000])
    try:
        wh_append(pd.DataFrame([run_row]), "bank_recon_run_log", SCHEMA_RUN)
    except Exception as log_err:
        print("Could not write the FAILED run_log row:", log_err)
    raise


# %% =====================================================================================
# STEP 11 - Re-run test: lines already proposed must be skipped by a second run
#           Run this cell, then Steps 5 -> 6 -> 7 -> 9 again. Expect ~0 new proposals.
# =========================================================================================
from com.microsoft.spark.fabric.Constants import Constants
locked = set(spark.read.option(Constants.WorkspaceId, WAREHOUSE_WORKSPACE_ID)
                  .synapsesql(f"{WAREHOUSE_NAME}.dbo.vw_bank_recon_locked_lines")
                  .toPandas()["line_id"])
print(f"Lines locked by earlier runs: {len(locked):,}")
