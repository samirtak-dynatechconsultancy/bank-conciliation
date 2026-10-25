"""
Run the matching engine locally against the Parquet test data and write a review workbook.

    python tools/run_local_test.py              # normal run: unreconciled lines only
    python tools/run_local_test.py --backtest   # also replay already-reconciled lines to measure hit-rate

Output: test_data/local_run_results.xlsx
"""
import argparse
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
import recon_engine as re_  # noqa: E402

DATA = ROOT / "test_data"


def load():
    bank = re_.prepare_bank(pd.read_parquet(DATA / "jde_f09617_bank_statement.parquet"))
    gl = re_.prepare_gl(pd.read_parquet(DATA / "jde_f0911_gl.parquet"))
    return bank, gl


def explode(res, bank, gl):
    groups = pd.DataFrame(res.groups)
    links = pd.DataFrame(res.links)
    lines = pd.concat([bank.assign(side="BANK"), gl.assign(side="GL")], ignore_index=True)
    detail = links.merge(groups[["group_seq", "match_type", "match_rule", "confidence"]], on="group_seq").merge(
        lines[["side", "line_id", "gl_bank_account", "txn_date", "amount", "description"]],
        on=["side", "line_id"])
    return groups, detail.sort_values(["group_seq", "side"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backtest", action="store_true")
    args = ap.parse_args()

    cfg = re_.MatchConfig()
    bank, gl = load()

    b_open, g_open, scope = re_.select_open_lines(bank, gl, max_window_days=cfg.max_tolerance_days)
    print("Scope:", scope)
    res = re_.run_matching(b_open, g_open, cfg)
    print("Result:", res.stats)
    groups, detail = explode(res, b_open, g_open)

    out = DATA / "local_run_results.xlsx"
    with pd.ExcelWriter(out) as xw:
        pd.DataFrame([{**scope, **{k: str(v) for k, v in res.stats.items()}}]).T.to_excel(xw, sheet_name="summary")
        groups.to_excel(xw, sheet_name="proposals", index=False)
        detail.to_excel(xw, sheet_name="proposal_lines", index=False)
        res.unmatched.drop(columns=["reconciled"], errors="ignore").to_excel(xw, sheet_name="unmatched", index=False)
    print("Wrote", out.relative_to(ROOT))

    if args.backtest:
        # Pretend nothing is reconciled, then see how many reconciled bank lines the engine pairs up.
        b_all = bank.assign(reconciled=False)
        g_all = gl.assign(reconciled=False)
        rb = re_.run_matching(*re_.select_open_lines(b_all, g_all)[:2], cfg)
        links = pd.DataFrame(rb.links)
        rec_bank = set(bank.loc[bank["reconciled"], "line_id"])
        hit = links[(links.side == "BANK") & links.line_id.isin(rec_bank)]
        print(f"Backtest: {len(hit)}/{len(rec_bank)} already-reconciled bank lines got a proposal "
              f"({len(hit) / max(len(rec_bank), 1):.1%}); by type:",
              pd.DataFrame(rb.groups)["match_type"].value_counts().to_dict())


if __name__ == "__main__":
    main()
