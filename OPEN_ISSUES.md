# Open Issues – Bank Reconciliation Agent

Issues found while moving to the client's Fabric environment. They are parked here to come back to.

---

## 1. GL `Line Extension Code` is empty in the client table (parked)

**Status:** Parked – does not block matching; must be resolved before the JDE write-back goes live.
**Raised:** 2026-10-21
**Owner:** Client data team (pipeline) / JDE IT (confirmation)

### What we found
- Client table `account_ledger_f0911`, column `Line Extension Code`, is typed **int** and is **NULL in all 1,399,224 rows**.
- In the JDE extract we tested with (`GL F0911 All Bank Accts May 1 - Sept 11 2026.xlsx`) the same field
  holds **`AE`** on 2,876 lines and is blank on 176 lines.
- Most likely cause: the client pipeline typed the column as a number, so text values such as `AE` could not be
  converted and became NULL.

### What the field is
- It is part of the **F0911 primary key**: Document Type, Document Number, Document Company, GL Date,
  JE Line Number, Ledger Type, **Line Extension Code**.
- `AE` = automatic entry: the cash-account line JDE generates when it posts a batch with automatic offsets
  (receipts RC, payments PK/PT/PO, voids RO). Blank = a manual journal entry line (JE).
- In our extract the pattern is exact: all 2,876 `AE` lines are auto-offset documents (Offset Method = `Y`),
  all 176 blank lines are document type `JE`.

### Impact
| Area | Impact |
|---|---|
| Matching (amount / date / account) | None – the field is not used |
| Line identity (locking, no double match, rejected combinations) | None in practice – the client data has **0 duplicate keys** even without it |
| **JDE output file** (`recon.vw_jde_output`, F0911 key + Reference 3) | **At risk** – if JDE IT's import finds F0911 records by the full 7-part key, a blank instead of `AE` will not find the record |

Current code behaviour: NULL is treated as blank (`''`), so nothing breaks while this is open.

### Options (in order of preference)
1. **Fix the pipeline** – client data team changes `Line Extension Code` to varchar and reloads.
2. **Confirm with JDE IT** whether their import needs this field. If they locate F0911 records with the other
   6 key parts, it can be dropped from the output.
3. **Fallback rule** – fill `AE` for auto-offset document types and blank for `JE`. Holds for 100% of our
   extract, but it is an inference: use only with JDE IT's agreement.

### To close this issue
- [ ] Ask the client data team to fix the column type and reload
- [ ] Re-run: `SELECT [Line Extension Code], COUNT(*) FROM account_ledger_f0911 GROUP BY [Line Extension Code]`
      – expect `AE` and blank, no NULL-only result
- [ ] Confirm with JDE IT which F0911 key fields the import needs

---

## 2. Bank `Line Number _ General` is stored x100 in the client table

**Status:** Open – no impact on matching; decide before the JDE write-back goes live.
**Raised:** 2026-10-21
**Owner:** JDE IT (confirmation)

### What we found
- Client table `proddta.auto_bank_statement_detail_f09617`, column `Line Number _ General`, holds
  `100, 200, … 1700` where the JDE extract we tested with shows `1, 2, … 17`.
- Same raw-storage pattern as the bank amounts (`Debits Entered` / `Credits Entered` are stored in cents and
  divided by 100 in the code). The GL side (`Journal Entry Line Number`) is **not** scaled: it shows `1`.

### Impact
| Area | Impact |
|---|---|
| Matching | None – the line ID only needs to be unique, and it is (0 duplicates) |
| **JDE output file** | The F09617 key (Line Number) and the F0911 **Reference 3** value (`<Statement ID>-<Line>`) must use the form JDE expects: `817-17` (display) or `817-1700` (stored). Reference 3 is only 8 characters, so the stored form also gets close to the limit (`1234-1700` = 9 chars). |

### To close this issue
- [ ] Ask JDE IT which form their import expects for the F09617 line number and for Reference 3
- [ ] If display form: divide the line number by 100 when building `vw_jde_output` (matching unaffected)
