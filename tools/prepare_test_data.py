"""
Convert the JDE Excel extracts into typed Parquet files with Delta-safe snake_case column names.

    python tools/prepare_test_data.py

Output: test_data/jde_f09617_bank_statement.parquet, test_data/jde_f0911_gl.parquet
Identifiers (accounts, companies, document numbers ...) stay as text so leading zeros survive;
date columns become DATE and money columns DECIMAL(18,2).
"""
import re
import sys
import warnings
from decimal import Decimal
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

warnings.filterwarnings("ignore", category=UserWarning)   # openpyxl "no default style"

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "test_data"

FILES = {
    "jde_f09617_bank_statement": "Bank Statement Detail F09617 July 1 - Sept 11 2026.xlsx",
    "jde_f0911_gl": "GL F0911 All Bank Accts May 1 - Sept 11 2026.xlsx",
}
MONEY = {"debits_entered", "credits_entered", "foreign_debit", "foreign_credit", "tax",
         "foreign_tax", "taxable_amount", "foreign_taxable_amount", "amount", "currency_amount",
         "units", "exchange_rate", "historical_rate"}


def snake(name: str) -> str:
    s = re.sub(r"[^0-9a-zA-Z]+", "_", str(name).strip()).strip("_").lower()
    return s or "col"


def convert(df: pd.DataFrame) -> pa.Table:
    cols, seen = [], {}
    for c in df.columns:
        base = snake(re.sub(r"\.\d+$", "", str(c)))   # pandas suffixes duplicate headers with .1
        n = seen.get(base, 0)
        seen[base] = n + 1
        cols.append(base if n == 0 else f"{base}_{n}")
    df.columns = cols

    arrays, fields = [], []
    for c in df.columns:
        s = df[c]
        if c in MONEY:
            vals = pd.to_numeric(s, errors="coerce")
            arr = pa.array([None if pd.isna(v) else Decimal(str(round(v, 2))).quantize(Decimal("0.01"))
                            for v in vals], type=pa.decimal128(18, 2))
        elif "date" in c or c in {"cleared_date", "original_clear", "check_itm_date", "check_itm_date_1",
                                  "check_cleared", "historical_date"}:
            d = pd.to_datetime(s, errors="coerce")
            if d.notna().sum() >= s.notna().sum() * 0.9:      # only treat as date if it parses
                arr = pa.array(d.dt.date, type=pa.date32())
            else:
                arr = pa.array(s.astype("string").str.strip(), type=pa.string())
        else:
            arr = pa.array(s.astype("string").str.strip().where(s.notna(), None), type=pa.string())
        arrays.append(arr)
        fields.append(pa.field(c, arr.type))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


def main():
    OUT.mkdir(exist_ok=True)
    for table, xlsx in FILES.items():
        df = pd.read_excel(ROOT / xlsx, dtype=str)
        t = convert(df)
        path = OUT / f"{table}.parquet"
        pq.write_table(t, path)
        print(f"{xlsx} -> {path.relative_to(ROOT)}  rows={t.num_rows} cols={t.num_columns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
