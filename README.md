# Bank Reconciliation Agent – Backend (Fabric)

Matches unreconciled JDE bank statement lines (**F09617**) to GL cash lines (**F0911**), writes
proposals to a Fabric Warehouse for review in Power Apps, and produces a JDE write-back dataset.

```
Power Apps ──► Power Automate ──► Fabric REST "Run notebook" ──► nb_bank_recon_match (PySpark)
                                                                  │ reads  LH_BankRecon (F09617 / F0911 Delta tables)
                                                                  │ reads  WH_BankRecon recon.config / locked / rejected
                                                                  └ writes WH_BankRecon recon.match_* / unmatched_line / run_log
Power Apps  ◄── views ── WH_BankRecon ── procs ◄── Approve / Reject / Exception / Bulk approve
Power Automate ── usp_create_export_batch + vw_jde_output ──► CSV ──► SFTP ──► JDE
```

## Deployed (test) – workspace **Dynatech_MDM_Bronze**

| Item | Name | Id |
|---|---|---|
| Lakehouse | `LH_BankRecon` | 905fc2e5-41b1-4e09-a20f-6dc0abc46cfe |
| Warehouse | `WH_BankRecon` | 49e9005e-03ea-4795-9c3a-0dbce8af9a28 |
| Notebook | `nb_bank_recon_match` | b76ff424-11a0-4f6d-86b5-632bac112d76 |

Lakehouse content: `Files/bank_recon/raw/*.xlsx` (original extracts), `Files/bank_recon/parquet/*.parquet`,
tables `jde_f09617_bank_statement` (2,137 rows) and `jde_f0911_gl` (3,052 rows). Column names are the Excel
headers in snake_case (`Bank Acct-G/L` → `bank_acct_g_l`, `R ND` → `r_nd`, …); IDs stay text so leading zeros survive.

## Matching rules (SOW §3.2)

| # | Rule | Implementation |
|---|---|---|
| 2 | Exact | same GL bank account, amount equal in cents, bank **cleared date** = GL date → `EXACT` |
| 3–7 | Tolerance ±1…±5 (1:1) | window widens one day at a time; matched lines are locked before the next tier → `TOLERANCE_T1..T5` |
| 8 | 1:M | 1 bank line = sum of 2…`aggregate_max_lines` GL lines inside the window → `ONE_TO_MANY`, confidence `POTENTIAL` |
| 9 | M:1 | sum of several bank lines = 1 GL line, run on what is still unmatched → `MANY_TO_ONE`, `POTENTIAL` |
| 10/11 | Unmatched | leftovers → `recon.unmatched_line` with a reason (and the nearest same-amount gap if there is one) |

* **Reconciled lines are never processed**: F09617 `Reconciliation Code = 'R'` and F0911 `R ND = 'R'` are filtered
  out in Spark before matching (only counted, in `run_log`).
* **Lines already in a PENDING / APPROVED / EXCEPTION proposal are not re-matched** by later runs
  (`recon.vw_locked_lines`). Rejected lines become available again, but the exact rejected combination is never
  proposed again (`recon.vw_rejected_signatures`).
* Sign standardisation: bank amount = Credits − Debits; GL = Amount as posted (+ deposit, − payment).
* Bank date = **Cleared Date** (value date). Statement Date is 1–4 days later and matched much worse in profiling.
* Every proposal has a **`match_rule`** column saying why it matched, numbered as in the SOW, e.g.
  `Rule 2 - Exact match: same amount, same date`, `Rule 3 - Tolerance T+/-1 (1:1): same amount, dates 1 day apart`,
  `Rule 9 - Many-to-one (M:1, potential): 3 bank lines sum to 1 GL line, within +/-1 day`. It is in
  `vw_proposal_review`, `vw_proposal_lines` and `vw_jde_output`.
* 1:1 confidence: `HIGH` = only one candidate on both sides; `MEDIUM` = several same-amount lines in the window
  (the pairing should be checked).
* Same GL bank account is mandatory (F09617 `GL Bank Account` = F0911 `Account ID`).
* Engine asserts that no line is used twice in a run.

## JDE keys and write-back (`recon.vw_jde_output`)

One row per approved (bank line, GL line) link:

* F09617 key: Bank Statement ID, GL Bank Account, Statement Date, Line Number → **Remark = GL Document Number**
* F0911 key: Doc Type, Doc Number, Doc Company, GL Date, JE Line Number, Ledger Type, Line Ext Code →
  **Reference 3 = `<Bank Statement ID>-<Line Number>`** (cut to 8 chars, the GLR3 length)
* 1:M → several rows for the same bank line; M:1 → several rows for the same GL line.

## Warehouse objects (`recon` schema)

| Object | Purpose |
|---|---|
| `config` | Tolerance days, aggregate caps, 1:M / M:1 switches – change via `usp_set_config` |
| `run_log` | One row per run, written **last** (a failed run leaves nothing visible in the views) |
| `match_proposal` / `match_line` | Proposals + lines with full JDE keys; `status` PENDING/APPROVED/REJECTED/EXCEPTION |
| `unmatched_line` | Unmatched bank and GL lines per run |
| `audit_log` | Every approve / reject / exception / reopen / export / config change with user + UTC timestamp |
| `vw_proposal_review`, `vw_proposal_lines`, `vw_unmatched_latest` | Power Apps screens |
| `vw_jde_output` | Approved links in JDE layout |
| `usp_decide_match @match_ids, @action, @user, @comment` | APPROVE / REJECT / EXCEPTION / REOPEN, comma-separated ids = bulk approve |
| `usp_create_export_batch @user` | Stamps approved and not-yet-exported matches with a batch id and returns it |

## Power Apps / Power Automate integration

**Trigger a run**: Power Automate → HTTP with Entra ID (or the Fabric connector):

```
POST https://api.fabric.microsoft.com/v1/workspaces/290f6b06-3796-4928-9d58-f562fd0bfecd/items/b76ff424-11a0-4f6d-86b5-632bac112d76/jobs/instances?jobType=RunNotebook
{ "executionData": { "parameters": {
    "run_id":        { "value": "<guid from the flow>", "type": "string" },
    "triggered_by":  { "value": "<User().Email>",      "type": "string" },
    "bank_accounts": { "value": "00498785",            "type": "string" },
    "date_from":     { "value": "2026-07-01",          "type": "string" },
    "date_to":       { "value": "2026-09-11",          "type": "string" } } } }
```

The response `Location` header is the job instance. Poll it until `Completed` / `Failed`, then read
`recon.run_log WHERE run_id = <guid>`. Empty `bank_accounts`, `date_from` or `date_to` = no filter.

**Review**: Power Apps reads the views (SQL Server connector → Warehouse SQL endpoint) and calls
`recon.usp_decide_match`. **Output**: the flow calls `usp_create_export_batch`, selects
`vw_jde_output WHERE export_batch_id = <id>`, writes the CSV and sends it to SFTP.

## Developer workflow

```bash
python tools/prepare_test_data.py          # Excel -> typed Parquet (test_data/)
python tools/run_local_test.py --backtest  # run the engine locally -> test_data/local_run_results.xlsx
python tools/deploy_fabric.py all          # items, upload, sql, notebook, run (uses az login)
```

* `src/recon_engine.py` is the single source of the matching logic. `tools/build_notebook.py` embeds it into
  the notebook, so edit the engine there and redeploy with `deploy_fabric.py notebook`.
* For production JDE tables, change `BANK_COLUMNS` / `GL_COLUMNS` in the engine (logical → source column) and
  the `source_*` / `bank_table` / `gl_table` notebook parameters.
* `sql/01_warehouse_schema.sql` **drops and recreates the tables**. Run it only for a fresh environment.
  `02_views_and_procs.sql` and `03_add_match_rule.sql` (migration) are safe to re-run.

## Test results on the sample extracts

| | Bank | GL |
|---|---|---|
| Lines in extract | 2,137 | 3,052 |
| Already reconciled (skipped) | 1,663 | 2,712 |
| In scope | 474 | 340 |
| Matched | 129 | 125 |
| Unmatched | 345 | 215 |

125 proposals: 60 exact, 61 at ±1 day, 1 at ±2 days, 3 M:1. Most unmatched bank lines are account transfers
(type 699), wires/ACH (201) and checks (451) that have no same-amount GL line in the window.
**Backtest**: replaying the 1,663 already-reconciled bank lines as if they were open, the engine proposes a
match for 69.7% of them. The rest were probably reconciled through Payment ID or other rules that the SOW
leaves out of scope.

## Open points to confirm with Tris / JDE IT

Issues found in the client environment are tracked in [OPEN_ISSUES.md](OPEN_ISSUES.md).

1. Reference 3 format (`<stmt>-<line>`, 8 chars) and whether 1:M should put all doc numbers in a single Remark.
2. The column names of the production JDE source tables in Fabric (mirrored F09617 / F0911).
3. Whether a new run should replace still-PENDING proposals instead of keeping them locked (current behaviour).
4. Fabric Warehouse runs under snapshot isolation, so two users updating at the same moment can get a
   write-conflict error. The Power Apps or Power Automate call should retry once.
