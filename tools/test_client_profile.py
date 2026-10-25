"""
Check the "client" source profile without access to the client environment.

Rebuilds the test data in the client's shape - client column names, bank amounts stored in cents,
Line Extension Code NULL, plus noise the client GL has (AU units ledger, non-bank accounts) - and
asserts the client profile produces exactly the same matches as the test profile.

    python tools/test_client_profile.py
"""
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
import recon_engine as re_  # noqa: E402

DATA = ROOT / "test_data"


def to_client_shape():
    test, client = re_.SOURCE_PROFILES["test"], re_.SOURCE_PROFILES["client"]
    bank = pd.read_parquet(DATA / "jde_f09617_bank_statement.parquet")
    gl = pd.read_parquet(DATA / "jde_f0911_gl.parquet")

    cb = pd.DataFrame({client.bank_columns[k]: bank[v] for k, v in test.bank_columns.items()
                       if k in client.bank_columns})
    for c in ("Debits Entered", "Credits Entered"):          # client stores cents as float
        cb[c] = (pd.to_numeric(cb[c]).astype(float) * 100).round()
    cb["Bank Statement ID"] = pd.to_numeric(cb["Bank Statement ID"]).astype(float)
    cb["Line Number _ General"] = pd.to_numeric(cb["Line Number _ General"]).astype(float)
    cb["Bank Statement Transaction Code"] = cb["Bank Statement Transaction Code"] + " "   # char padding

    cg = pd.DataFrame({client.gl_columns[k]: gl[v] for k, v in test.gl_columns.items()
                       if k in client.gl_columns})
    cg["Line Extension Code"] = None                          # OPEN_ISSUES.md #1
    cg["Amount"] = pd.to_numeric(cg["Amount"]).astype(float)
    cg["Date For G_L _and Voucher Julian"] = pd.to_datetime(cg["Date For G_L _and Voucher Julian"]).dt.strftime("%Y-%m-%d")
    cg["Reconciled Code"] = cg["Reconciled Code"].fillna(" ")

    # Noise the client GL has: AU (units) copies of open lines, and lines on non-bank accounts
    au = cg[cg["Reconciled Code"].str.strip() != "R"].copy()
    au["Ledger Types"] = "AU"
    other = cg.head(200).copy()
    other["Account ID"] = "00999999"
    other["Reconciled Code"] = " "
    return cb, pd.concat([cg, au, other], ignore_index=True), len(au), len(other)


def run(bank, gl):
    cfg = re_.MatchConfig()
    b_open, g_open, scope = re_.select_open_lines(bank, gl, max_window_days=cfg.max_tolerance_days)
    res = re_.run_matching(b_open, g_open, cfg)
    sigs = {(g["match_type"], round(g["bank_amount"], 2), round(g["gl_amount"], 2)) for g in res.groups}
    return res, scope, sigs


def main():
    t = re_.SOURCE_PROFILES["test"]
    c = re_.SOURCE_PROFILES["client"]
    res_t, scope_t, sig_t = run(
        re_.prepare_bank(pd.read_parquet(DATA / "jde_f09617_bank_statement.parquet"), t.bank_columns),
        re_.prepare_gl(pd.read_parquet(DATA / "jde_f0911_gl.parquet"), t.gl_columns))

    cb, cg, n_au, n_other = to_client_shape()
    bank_c = re_.prepare_bank(cb, c.bank_columns, amount_divisor=c.bank_amount_divisor)
    gl_c = re_.prepare_gl(cg, c.gl_columns)
    res_c, scope_c, sig_c = run(bank_c, gl_c)

    print("test  :", scope_t, res_t.stats)
    print("client:", scope_c, res_c.stats)
    print(f"noise added to client GL: {n_au} AU rows, {n_other} non-bank-account rows")

    assert len(res_t.groups) == len(res_c.groups), "different number of proposals"
    assert sig_t == sig_c, f"different matches: {sorted(sig_t ^ sig_c)[:5]}"
    assert scope_c["gl_in_scope"] == scope_t["gl_in_scope"], "AU / non-bank GL rows leaked into scope"
    assert (bank_c["amount_cents"].abs() < 1_000_000_000_00).all(), "bank divisor not applied"
    sample = bank_c[(bank_c.bank_statement_id == "735") & (bank_c.line_number == "1")]
    assert sample["amount"].iloc[0] == 22345.12 and sample["line_id"].iloc[0] == "B|735|00498742|2026-09-01|1"
    print("OK - client profile reproduces the test results exactly")


if __name__ == "__main__":
    main()
