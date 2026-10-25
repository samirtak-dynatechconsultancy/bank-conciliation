# Bank Reconciliation – stored procedures (client warehouse, `dbo`)

All UI actions go through these procedures. Each one validates the request, changes the data and writes
`dbo.bank_recon_audit_log` in one transaction. **Always pass the logged-in user's email as `@user`** – it is
what the audit trail records. Never update the tables directly.

| UI action | Procedure | Audit `action` |
|---|---|---|
| Confirm / reject / flag / reopen (single or bulk) | `usp_bank_recon_decide_match` | `APPROVE`, `REJECT`, `EXCEPTION`, `REOPEN` |
| Pick a different candidate (exception screen) | `usp_bank_recon_resolve_exception` | `RESOLVE` |
| Confirm as unmatched / undo | `usp_bank_recon_confirm_unmatched` | `LEAVE_UNMATCHED`, `UNDO_UNMATCHED` |
| Complete reconciliation | `usp_bank_recon_complete` | `SIGNOFF` |
| Export batch for JDE (Power Automate) | `usp_bank_recon_create_export_batch` | `EXPORT` |
| Change a setting | `usp_bank_recon_set_config` | `CONFIG` |
| Change account details | `usp_bank_recon_set_account` | `ACCOUNT` |

---

## 1. `usp_bank_recon_decide_match` – confirm / reject / flag / reopen

| Parameter | Required | Value |
|---|---|---|
| `@match_ids` | yes | One `match_id`, or several separated by commas (= bulk) |
| `@action` | yes | `APPROVE`, `REJECT`, `EXCEPTION` or `REOPEN` |
| `@user` | yes | Logged-in user's email |
| `@comment` | no | Free text |

**Get the IDs:** `SELECT match_id, match_rule, bank_amount, status FROM dbo.vw_bank_recon_ui_matches WHERE status = 'PENDING';`

```sql
-- single
EXEC dbo.usp_bank_recon_decide_match @match_ids = '8206dca6-f297-4e12-8ebe-35c4d88114d5',
     @action = 'APPROVE', @user = 'jane@trispharma.com', @comment = 'Deposit slip checked';

-- bulk ("Confirm selected")
EXEC dbo.usp_bank_recon_decide_match @match_ids = 'id1,id2,id3', @action = 'APPROVE', @user = 'jane@trispharma.com';
```

**Returns:** `updated_count` – how many matches changed.
**Rules:** matches already exported are skipped (frozen); a match already in the requested status is skipped.
`REJECT` frees the lines and that exact combination is never proposed again. `EXCEPTION` sends it to the
exception queue (lines stay locked). `REOPEN` puts it back to `PENDING` (also clears who/when).
**Check:** `SELECT status, decided_by, decided_at FROM dbo.bank_recon_match_proposal WHERE match_id = '...';`
**Undo:** call again with `@action = 'REOPEN'`.

---

## 2. `usp_bank_recon_resolve_exception` – "Match selected candidate"

For a MEDIUM match (several equally valid lines): replace the proposed line with the one the reviewer picked,
and approve the match.

| Parameter | Required | Value |
|---|---|---|
| `@match_id` | yes | The exception's `match_id` |
| `@line_id` | yes | The chosen candidate's `line_id` (may also be the already proposed one = "keep it") |
| `@user` | yes | Email |
| `@comment` | no | Free text |

**Get the IDs:**
```sql
SELECT match_id, exception_label, bank_amount, gl_documents FROM dbo.vw_bank_recon_ui_exceptions;
SELECT line_id, side, is_proposed, used_in_other_match, txn_date, doc_number, gl_alpha_name
FROM dbo.vw_bank_recon_ui_exception_candidates WHERE match_id = '...';
```
```sql
EXEC dbo.usp_bank_recon_resolve_exception @match_id = '...',
     @line_id = 'G|RC|12587|00004|2026-08-04|1|AA|', @user = 'jane@trispharma.com';
```
**Rules:** only `PENDING` / `EXCEPTION` matches; the line must be one of that match's candidates; refused if the line
is already in another open or approved match (`used_in_other_match = 1`). The match becomes `APPROVED`, the note
records the old line.
**Check:** `SELECT side, line_id FROM dbo.bank_recon_match_line WHERE match_id = '...';`
**Undo:** `usp_bank_recon_decide_match … @action = 'REOPEN'` (status back to PENDING; the chosen line stays in the match).

---

## 3. `usp_bank_recon_confirm_unmatched` – "Confirm as unmatched" / undo

| Parameter | Required | Value |
|---|---|---|
| `@side` | yes | `BANK` or `GL` |
| `@line_ids` | yes | One `line_id`, or several separated by commas |
| `@action` | yes | `CONFIRM` or `UNDO` |
| `@user` | yes | Email |
| `@comment` | no | Reason, e.g. "Bank fee, no GL entry expected" |

**Get the IDs** (copy `line_id` exactly):
```sql
SELECT TOP 20 line_id, post_date, amount, reference, reason, status
FROM dbo.vw_bank_recon_ui_unmatched_bank WHERE gl_bank_account = '00358555';
-- GL side: dbo.vw_bank_recon_ui_unmatched_gl
```
```sql
EXEC dbo.usp_bank_recon_confirm_unmatched @side = 'BANK',
     @line_ids = 'B|406|00358555|2026-01-14|8300', @action = 'CONFIRM',
     @user = 'jane@trispharma.com', @comment = 'Bank fee, no GL entry expected';
```
**Returns:** `lines_updated` and `lines_not_found_or_already_confirmed`.
**Rules:** only lines that are unmatched in the **latest** run; a line already confirmed is skipped. The decision is
a note only – the next run can still match the line if a partner appears.
**Check:** `SELECT * FROM dbo.bank_recon_line_decision ORDER BY decided_at DESC;` and `status` in the unmatched view
shows `Confirmed unmatched`.
**Undo:** same call with `@action = 'UNDO'`.

---

## 4. `usp_bank_recon_complete` – "Complete reconciliation" (sign-off)

| Parameter | Required | Value |
|---|---|---|
| `@gl_bank_account` | yes | JDE Account ID, e.g. `00358555` |
| `@period_end` | yes | Period being signed off, e.g. `2026-09-30` (UI: "Period ending") |
| `@user` | yes | Email |
| `@comment` | no | Free text |

**Check first if allowed:**
```sql
SELECT gl_bank_account, pending_review, exceptions_open, can_complete, period_end
FROM dbo.vw_bank_recon_ui_overview WHERE gl_bank_account = '00358555';
```
```sql
EXEC dbo.usp_bank_recon_complete @gl_bank_account = '00358555', @period_end = '2026-09-30',
     @user = 'jane@trispharma.com', @comment = 'September close';
```
**Rules:** refused while `pending_review > 0` or `exceptions_open > 0` (button disabled when `can_complete = 0`);
one sign-off per account and period. Stores the control totals at that moment.
**Check:** `SELECT * FROM dbo.vw_bank_recon_ui_signoff;`
**Undo:** none by design (a sign-off is a control record). Ask an admin if it was made in error.

---

## 5. `usp_bank_recon_create_export_batch` – export to JDE (Power Automate)

| Parameter | Required | Value |
|---|---|---|
| `@user` | yes | The flow's identity, e.g. `powerautomate` or the user who clicked "Export" |

```sql
EXEC dbo.usp_bank_recon_create_export_batch @user = 'powerautomate';
-- returns: export_batch_id, match_count
SELECT * FROM dbo.vw_bank_recon_jde_output WHERE export_batch_id = '<returned id>';   -- rows for the CSV
```
**Rules:** takes every `APPROVED` match not yet exported, stamps it with the batch id; exported matches can no
longer be changed. Running it again picks up only newly approved matches (each match is exported once).
**Flow:** call procedure → read the view with the returned id → write CSV → send to SFTP.
**Undo:** none by design.

---

## 6. `usp_bank_recon_set_config` – change a matching setting

| Parameter | Required | Value |
|---|---|---|
| `@param_name` | yes | One of the names in `dbo.bank_recon_config` |
| `@param_value` | yes | New value (text) |
| `@user` | yes | Email |

```sql
SELECT param_name, param_value, description FROM dbo.bank_recon_config;
EXEC dbo.usp_bank_recon_set_config @param_name = 'max_tolerance_days', @param_value = '3', @user = 'admin@...';
```
**Rules:** unknown names are refused; tolerance days must be a whole number 0–5. Takes effect from the **next** run.
**Undo:** set the old value again (the audit log keeps both).

---

## 7. `usp_bank_recon_set_account` – account details from the client

| Parameter | Required | Value |
|---|---|---|
| `@gl_bank_account` | yes | JDE Account ID (any account that appears in the results; the row is created if missing) |
| `@display_name` | no | Name shown in the sidebar |
| `@bank_account_number` | no | Electronic bank account number |
| `@sort_order` | no | Sidebar order |
| `@is_active` | no | `0` hides the account in the UI |
| `@user` | yes | Email |

Only the parameters you pass are changed (`NULL` = keep).
```sql
SELECT gl_bank_account, gl_account_number, display_name, bank_account_number, sort_order, is_active
FROM dbo.bank_recon_account;
EXEC dbo.usp_bank_recon_set_account @gl_bank_account = '00358555',
     @display_name = '<from client>', @bank_account_number = '<from client>', @sort_order = 1, @user = 'admin@...';
```
**Undo:** call again with the previous values (shown in the audit log `old_status`).

---

## Errors you may see

| Code | Meaning |
|---|---|
| 50001 | `@action` must be APPROVE / REJECT / EXCEPTION / REOPEN |
| 50002 | `@user` missing |
| 50003 / 50004 | Unknown setting / tolerance not 0–5 |
| 50010 / 50011 | Unknown match / match is not PENDING or EXCEPTION |
| 50012 / 50013 | Line is not a candidate of this match / line already used in another match |
| 50020 / 50021 | `@side` must be BANK or GL / `@action` must be CONFIRM or UNDO |
| 50030 / 50031 / 50032 | Unknown account / pending items or open exceptions / already signed off |
| 50040 | Unknown account (it does not appear in any matching result) |

Fabric Warehouse can refuse a write if two users update at the same moment – retry once.
