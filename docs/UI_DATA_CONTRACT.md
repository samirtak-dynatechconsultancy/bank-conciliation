# Bank Reconciliation Workbench – UI Data Contract

> **For the UI team and for Claude Code.** This document is the complete contract between the
> *Reconcile* workbench UI (prototype: `Bank_Reconciliation_V5_Enterprise_Workbench_V5.5_8_Account_Workspaces.html`)
> and the Fabric Warehouse. It lists, screen by screen, which **view** to read, which **columns** map to which UI
> element, and which **stored procedure** each button calls. Everything needed to wire the UI is here – no other
> knowledge of the backend is required.

---

## 0. Instructions for Claude Code (read first)

When you implement or change the UI with this document:

1. **Read only from the views** listed in §3 (`dbo.vw_bank_recon_ui_*`). Never `SELECT` from `dbo.bank_recon_*` tables.
2. **Write only by calling the stored procedures** in §4 (`dbo.usp_bank_recon_*`). Never `INSERT/UPDATE/DELETE` a table.
   The procedures validate the request and write the audit trail; bypassing them breaks a contractual requirement.
3. **Always pass the signed-in user's email as `@user`** (Power Apps: `User().Email`). It is the audit trail.
4. **Use parameters, never string concatenation**, for every value that comes from the user or the UI state.
5. **Every screen is scoped to one bank account**: filter with `gl_bank_account = <selected account>` (see §2.2).
6. After any write, **refresh the data listed in §5** for that action.
7. Handle the error codes in §6 with the user-facing messages given there.
8. Do **not** invent data: if a column is `NULL` (e.g. bank account number not yet provided), show `–`.
9. Do not hard-code accounts, names, numbers or thresholds – they all come from the views.
10. Keep the prototype's look and layout; replace its hard-coded sample arrays (`data`, `exceptions`, `accountMap`)
    with the queries below.

---

## 1. Connection

| Setting | Value |
|---|---|
| Connector | **SQL Server** (Power Platform standard connector; works with Fabric Warehouse) |
| Server | `ekiivka4psxu3imi76yvmrlu64-d7l5gildyy4eddbcmdniifv4iy.datawarehouse.fabric.microsoft.com` |
| Database | *Warehouse name – provided by the data team* |
| Authentication | **Microsoft Entra ID integrated** (each user signs in as themselves) |
| Schema | `dbo` – all objects are prefixed `vw_bank_recon_` (views) and `usp_bank_recon_` (procedures) |
| Permissions | Users are in the database role `bank_recon_reviewer` (SELECT on the UI views, EXECUTE on the review procedures) |

Writes can occasionally be refused when two users update at the same moment (Fabric snapshot isolation):
**retry the procedure call once** before showing an error.

---

## 2. Concepts you need

### 2.1 Glossary

| Term | Meaning |
|---|---|
| **Bank line** | One row of the JDE bank statement (table F09617). "Account Activity" in the UI. |
| **GL line** | One row of the JDE general ledger on the bank's cash account (F0911). "General Ledger" in the UI. |
| **Match / proposal** | A set of bank line(s) + GL line(s) the matching engine proposes as belonging together. Identified by `match_id` (GUID string). |
| **match_category** | `1:1` (one bank = one GL), `1:M` (one bank = sum of several GL), `M:1` (several bank = one GL) |
| **Run** | One execution of the matching engine (a Fabric notebook, scheduled). Creates proposals and the unmatched lists. |
| **`gl_bank_account`** | JDE Account ID of the bank account (e.g. `00358555`). The key of every screen. |
| **`line_id`** | Unique text id of one bank or GL line, e.g. `B|312|00358555|2025-12-24|15200` or `G|RC|7564|00001|2025-02-19|1|AA|`. Treat as an opaque string. |

### 2.2 Account scope

The sidebar lists bank accounts (§3.1). The selected account's `gl_bank_account` is the filter for **every**
other query. Keep it in app state, e.g. `SelectedAccount`.

### 2.3 Enumerations

**`status`** (of a match)

| Value | UI label | Meaning |
|---|---|---|
| `PENDING` | Pending | Waiting for review |
| `APPROVED` | Confirmed | Approved by a reviewer (will be exported to JDE) |
| `REJECTED` | Rejected | Rejected; its lines are free again |
| `EXCEPTION` | Exception | Flagged by a reviewer for investigation |

**`confidence`**

| Value | UI label (suggested) | Meaning |
|---|---|---|
| `HIGH` | High | Only one possible partner |
| `MEDIUM` | Check pairing | Several equally valid partners – shown on the **Exceptions** tab |
| `POTENTIAL` | Potential split | A 1:M or M:1 sum – must be judged by a person |

The prototype's "100% / 98%" labels are **not** produced by the engine – use the labels above.

**`recon_state`** – JDE reconciliation flag at match time

| Value | UI hint |
|---|---|
| `BOTH_OPEN` | (no hint) |
| `GL_R_BANK_OPEN` | "G/L already reconciled in JDE" |
| `BANK_R_GL_OPEN` | "Bank line already reconciled in JDE" |

**Amounts** are `decimal(18,2)`: positive = money in, negative = money out. Format negatives in parentheses like the
prototype, e.g. `($289.00)`. **Dates** are `date` (no time) – format `MM/DD/YYYY`.

---

## 3. Screens → data (READ)

### 3.1 Sidebar – account list with badges

**View:** `dbo.vw_bank_recon_ui_accounts`

```sql
SELECT gl_bank_account, display_name, gl_account_number, sort_order,
       pending_review, exceptions_open, unmatched_bank, unmatched_gl
FROM dbo.vw_bank_recon_ui_accounts
ORDER BY ISNULL(sort_order, 999), display_name;
```

| UI element | Column |
|---|---|
| Account item text | `display_name` (client name → GL account number → account id; never NULL) |
| Value kept in state on click | `gl_bank_account` |
| "Proposed Matches" badge | `pending_review` |
| "Exceptions" badge | `exceptions_open` |
| "Unmatched Bank" badge | `unmatched_bank` |
| "Unmatched G/L" badge | `unmatched_gl` |

Prototype ids: `#accountMenu`, `#pendingNav`, `#exceptionNav`, the two unmatched `.count` badges.

### 3.2 Header, account context, Overview cards and KPIs

**View:** `dbo.vw_bank_recon_ui_overview` – exactly one row per account.

```sql
SELECT *
FROM dbo.vw_bank_recon_ui_overview
WHERE gl_bank_account = @acct;
```

| UI element (prototype) | Column | Notes |
|---|---|---|
| Title "`<name>` Reconciliation" (`#accountTitle`) | `display_name` | |
| Top right "Period …" | `period_start` – `period_end` | First / last bank statement date |
| Current account (`.ctx-name`) | `display_name` | |
| Electronic Bank Account Number (`.ctx-bank`) | `bank_account_number` | `NULL` until provided by the client → show `–` |
| G/L Account Number (`.ctx-gl`) | `gl_account_number` | e.g. `1.11310.GENERIC`; `–` if NULL |
| Card **Bank activity**: rows | `bank_lines` | status dot green when `bank_data_available = 1` |
| Card **General ledger**: rows | `gl_lines` | status dot green when `gl_data_available = 1` |
| Card **Matching engine** | `last_run_status` (`COMPLETED` / `FAILED` / NULL = never run), `last_run_at` | green = COMPLETED |
| Card **Analyst review**: "n confirmed" | `confirmed` | |
| Data freshness (optional) | `bank_loaded_at`, `gl_loaded_at` | |
| KPI Proposed matches | `proposed_total` | all proposals of the account |
| KPI Confirmed | `confirmed` | |
| KPI Rejected | `rejected` | |
| KPI Exceptions | `exceptions_open` | |
| KPI Unmatched bank | `unmatched_bank` | |
| KPI Unmatched G/L | `unmatched_gl` | |
| Close progress bar + % | `progress_pct` | 0–100 |
| Activity "Source files detected" (green) | `source_files_detected` | 1 = green (bank AND ledger rows exist), 0 = amber |
| Activity "n candidate pairs generated" | `proposed_total` | |
| Activity "n exceptions routed" | `exceptions_open` | |

Other columns available: `pending_review`, `exported`, `confirmed_unmatched`, `can_complete`, `bank_open`, `gl_open`,
`last_run_id`, `sort_order`.

### 3.3 Proposed matches (list)

**View:** `dbo.vw_bank_recon_ui_matches` – one row per match. Exceptions are excluded (they have their own tab).

```sql
SELECT match_id, status, confidence, review_group, match_rule, recon_state,
       bank_date, bank_amount, bank_reference, bank_tr_code, bank_txn_type, bank_statement_lines,
       gl_date, gl_amount, gl_alpha_name, gl_documents, gl_batches, gl_account_number, gl_business_unit,
       bank_line_count, gl_line_count,
       reason_date, reason_amount, reason_unique, reason_recon_state, note
FROM dbo.vw_bank_recon_ui_matches
WHERE gl_bank_account = @acct
  AND is_exception = 0
  AND (@status IS NULL OR status = @status)                       -- status dropdown; NULL = all
  AND (@confidence IS NULL OR confidence = @confidence)           -- confidence dropdown; NULL = all
  AND (@search IS NULL OR search_text LIKE '%' + LOWER(@search) + '%')   -- search box
ORDER BY bank_date DESC, bank_amount DESC
OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;              -- e.g. 0 / 50
```

Total for the pager: same `WHERE`, `SELECT COUNT(*)`.

| UI column (card) | Field | Column |
|---|---|---|
| **Account Activity** | Date | `bank_date` |
| | Amount | `bank_amount` |
| | Reference | `bank_reference` |
| | Description | `bank_tr_code` (CK = payment, CR = receipt, JE = adjustment) |
| | Transaction Type | `bank_txn_type` (JDE external transaction type code) |
| | Source Row | `bank_statement_lines` (`statement/line`; several joined with `|`) |
| **General Ledger** | Date | `gl_date` |
| | Amount | `gl_amount` |
| | Name - Alpha | `gl_alpha_name` |
| | Document | `gl_documents` (`RC 7564`; several joined with `|`) |
| | Batch | `gl_batches` |
| | Account / BU | `gl_account_number` / `gl_business_unit` |
| **Result** | Pill | `status` + `confidence` (§2.3) |
| | Ticks "Date ✓ / Amount ✓ / Unique ✓" | `reason_date`, `reason_amount`, `reason_unique` |
| | Extra hint | `reason_recon_state` (only when not NULL) |
| Grouping (optional) | | `review_group` = `Direct` or `Potential (split payment)` |

Rows with `bank_line_count > 1` or `gl_line_count > 1` are split payments – show "n lines" and let **Details**
list them (§3.4). Disable the checkbox for rows whose `status` is not `PENDING`.

### 3.4 Match detail drawer ("Details" / "Info": why proposed)

**Why proposed** – from the list row (§3.3) or:
```sql
SELECT match_rule, confidence, recon_state, reason_date, reason_amount, reason_unique, reason_recon_state, note,
       status, decided_by, decided_at, decision_comment
FROM dbo.vw_bank_recon_ui_matches
WHERE match_id = @match_id;
```
Show `match_rule` as the headline (e.g. *"Rule 2 - Exact match: same amount, same date"*), then the ticks,
`reason_recon_state` and `note`.

**All lines of the match** (bank box and G/L box):
```sql
SELECT side, txn_date, amount, description, tr_code, external_txn_type, bank_statement_id, line_number,
       doc_type, doc_number, doc_company, gl_alpha_name, gl_remark, batch_number, account_number, business_unit,
       is_reconciled
FROM dbo.vw_bank_recon_ui_match_lines
WHERE match_id = @match_id
ORDER BY side, txn_date;
```
`side = 'BANK'` → "ACCOUNT ACTIVITY" box, `side = 'GL'` → "GENERAL LEDGER" box. `is_reconciled = 1` → small
"already reconciled in JDE" tag.

### 3.5 Exceptions – queue (left panel)

**View:** `dbo.vw_bank_recon_ui_exceptions`

```sql
SELECT match_id, exception_label, status, match_rule,
       bank_date, bank_amount, bank_reference, bank_statement_lines,
       gl_date, gl_documents, gl_alpha_name, candidate_count, note
FROM dbo.vw_bank_recon_ui_exceptions
WHERE gl_bank_account = @acct
ORDER BY bank_date DESC;
```

| UI element | Column |
|---|---|
| Item title | `exception_label` (`Multiple candidates` / `Flagged by reviewer`) |
| Date · Amount | `bank_date` · `bank_amount` |
| Sub-text | `bank_reference` |
| Pill "n candidates" | `candidate_count` (0 for reviewer-flagged items) |
| Right panel "BANK TRANSACTION" box | `bank_date`, `bank_amount`, `bank_reference`, `bank_statement_lines` |

### 3.6 Exceptions – possible matches (right panel, after clicking an item)

**View:** `dbo.vw_bank_recon_ui_exception_candidates`

```sql
SELECT line_id, side, is_proposed, used_in_other_match, gap_days,
       txn_date, amount, doc_type, doc_number, doc_company, gl_alpha_name, gl_remark,
       batch_number, account_number, bank_statement_id, line_number, description
FROM dbo.vw_bank_recon_ui_exception_candidates
WHERE match_id = @match_id
ORDER BY is_proposed DESC, gap_days, txn_date;
```

| UI element | Column |
|---|---|
| One radio option per row | `line_id` (value) |
| Option text | `side = 'GL'`: "Document `doc_type doc_number` · G/L Date `txn_date` · `gl_alpha_name` · Batch `batch_number`"; `side = 'BANK'`: "Statement `bank_statement_id`/`line_number` · `txn_date`" |
| Pre-selected | `is_proposed = 1` (the engine's choice) |
| Disabled | `used_in_other_match = 1` (line already in another open/approved match) |
| Amount | `amount` |

If the query returns no rows (reviewer-flagged item), show "No alternative candidates" and only the
"Leave unmatched" / "Reopen" actions.

### 3.7 Unmatched bank transactions

**View:** `dbo.vw_bank_recon_ui_unmatched_bank`

```sql
SELECT line_id, post_date, amount, reference, tr_code, external_txn_type,
       bank_statement_id, line_number, reason, nearest_same_amount_gap_days, status, decided_by, decided_at, comment
FROM dbo.vw_bank_recon_ui_unmatched_bank
WHERE gl_bank_account = @acct
ORDER BY post_date DESC
OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
```

| UI column | Column |
|---|---|
| Post Date | `post_date` |
| Amount | `amount` |
| Reference | `reference` |
| Description | `tr_code` (+ `external_txn_type` if useful) |
| Bank Statement ID | `bank_statement_id` |
| Line Number | `line_number` |
| Status pill | `status` (`Unmatched` / `Confirmed unmatched`) |
| Tooltip / extra column | `reason` (+ `nearest_same_amount_gap_days`) |

### 3.8 Unmatched G/L transactions

**View:** `dbo.vw_bank_recon_ui_unmatched_gl`

```sql
SELECT line_id, gl_date, amount, gl_alpha_name, gl_remark, doc_type, doc_number, doc_company,
       batch_number, account_number, business_unit, reason, nearest_same_amount_gap_days, status
FROM dbo.vw_bank_recon_ui_unmatched_gl
WHERE gl_bank_account = @acct
ORDER BY gl_date DESC
OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
```

| UI column | Column |
|---|---|
| G/L Date | `gl_date` |
| Amount | `amount` |
| Name - Remark Explanation | `gl_remark` (fall back to `gl_alpha_name`) |
| Document | `doc_number` |
| Document Type | `doc_type` |
| Status pill | `status` |
| Tooltip / extra column | `reason` |

### 3.9 Summary & sign-off

```sql
SELECT bank_lines, gl_lines, proposed_total, confirmed, rejected, exceptions_open, unmatched_bank, unmatched_gl,
       source_files_detected, last_run_status, pending_review, can_complete, period_end
FROM dbo.vw_bank_recon_ui_overview
WHERE gl_bank_account = @acct;

SELECT signed_by, signed_at, period_end, proposals, confirmed, rejected, unmatched_bank, unmatched_gl, comment
FROM dbo.vw_bank_recon_ui_signoff
WHERE gl_bank_account = @acct
ORDER BY signed_at DESC;
```

| UI element | Column / rule |
|---|---|
| Control totals | `bank_lines`, `gl_lines`, `proposed_total`, `confirmed`, `exceptions_open` |
| ✓ Source files available | `source_files_detected = 1` |
| ✓ Matching run complete | `last_run_status = 'COMPLETED'` |
| ✓ / ! Analyst review | ✓ when `pending_review = 0` |
| ✓ / ! Exceptions | ✓ when `exceptions_open = 0` |
| "Complete reconciliation" button | enabled only when `can_complete = 1` **and** no sign-off row exists for `period_end` |
| Previous sign-offs | second query |

### 3.10 Audit history

```sql
SELECT TOP (@top) event_at, event_by, event_type, event_text, match_id
FROM dbo.vw_bank_recon_ui_audit
WHERE gl_bank_account = @acct
ORDER BY event_at DESC;
```
`event_type` = `RUN`, `APPROVE`, `REJECT`, `EXCEPTION`, `REOPEN`, `RESOLVE`, `LEAVE_UNMATCHED`, `UNDO_UNMATCHED`,
`SIGNOFF`, `EXPORT`, `ACCOUNT`, `CONFIG`. Show `event_text` as the line and `event_by · event_at` as sub-text.

---

## 4. Buttons → procedures (WRITE)

All procedures: parameters are `varchar` unless noted; `@user` = signed-in user's email (required).

### 4.1 Confirm / Reject (single, selected, "Confirm all displayed")

```sql
EXEC dbo.usp_bank_recon_decide_match
     @match_ids = @match_ids,     -- one match_id, or several separated by commas
     @action    = @action,        -- 'APPROVE' | 'REJECT' | 'EXCEPTION' | 'REOPEN'
     @user      = @user,
     @comment   = @comment;       -- optional
-- returns one row: updated_count (int)
```

| Button | `@action` |
|---|---|
| Confirm selected / Confirm all displayed | `APPROVE` (pass the selected / displayed `match_id`s, comma-separated) |
| Reject selected | `REJECT` |
| Flag for investigation (optional) | `EXCEPTION` |
| Undo a decision (optional) | `REOPEN` |

Matches already exported are silently skipped (`updated_count` tells how many changed) – show
"n of m updated" when they differ.

### 4.2 Exceptions – "Match selected candidate"

```sql
EXEC dbo.usp_bank_recon_resolve_exception
     @match_id = @match_id,       -- the exception
     @line_id  = @line_id,        -- the selected radio option (line_id from §3.6)
     @user     = @user,
     @comment  = @comment;        -- optional
```
Swaps the chosen line into the match (if different) and **approves** it.

### 4.3 Exceptions – "Leave unmatched"

```sql
EXEC dbo.usp_bank_recon_decide_match
     @match_ids = @match_id, @action = 'REJECT', @user = @user,
     @comment = 'Left unmatched from exception screen';
```

### 4.4 Unmatched lists – "Confirm as unmatched" / undo

```sql
EXEC dbo.usp_bank_recon_confirm_unmatched
     @side     = @side,           -- 'BANK' (§3.7) or 'GL' (§3.8)
     @line_ids = @line_ids,       -- one line_id, or several separated by commas
     @action   = @action,         -- 'CONFIRM' | 'UNDO'
     @user     = @user,
     @comment  = @comment;        -- optional, e.g. 'Bank fee, no GL entry expected'
-- returns one row: lines_updated, lines_not_found_or_already_confirmed (or ..._not_confirmed for UNDO)
```

### 4.5 Summary – "Complete reconciliation"

```sql
EXEC dbo.usp_bank_recon_complete
     @gl_bank_account = @acct,
     @period_end      = @period_end,   -- date, from §3.9
     @user            = @user,
     @comment         = @comment;      -- optional
```

### 4.6 Admin only (separate screen / role, not for reviewers)

```sql
EXEC dbo.usp_bank_recon_set_account @gl_bank_account = @acct, @display_name = @name,
     @bank_account_number = @bank_no, @sort_order = @order, @is_active = @active, @user = @user;   -- NULL = keep
EXEC dbo.usp_bank_recon_set_config  @param_name = @name, @param_value = @value, @user = @user;
```
`usp_bank_recon_create_export_batch` is called by the Power Automate export flow, **not** by the UI.

---

## 5. What to refresh after each action

| Action | Refresh |
|---|---|
| Confirm / Reject / Flag / Reopen | §3.3 list, §3.2 overview, §3.1 badges, §3.10 audit |
| Match selected candidate / Leave unmatched | §3.5 queue, §3.6 candidates, §3.3 list, §3.2, §3.1, §3.10 |
| Confirm / undo unmatched | §3.7 or §3.8 list, §3.2, §3.10 |
| Complete reconciliation | §3.9, §3.10 |
| Account selected in the sidebar | everything except §3.1 |

New proposals only appear after the next matching **run** (scheduled notebook), not after UI actions.

---

## 6. Errors → user messages

Procedures raise SQL errors with these numbers. Map them to friendly messages:

| Code | Message to show |
|---|---|
| 50001 | "Unknown action." (programming error) |
| 50002 | "Your user could not be identified. Please sign in again." |
| 50003 / 50004 | "Unknown setting." / "Date tolerance must be a whole number from 0 to 5." |
| 50010 | "This match no longer exists. Refresh the page." |
| 50011 | "This match was already decided. Refresh the page." |
| 50012 | "The selected line is not a candidate for this match." |
| 50013 | "The selected line is already used in another match." |
| 50020 / 50021 | "Invalid side." / "Invalid action." (programming errors) |
| 50030 | "Unknown account." |
| 50031 | "Complete all pending reviews and exceptions before signing off." |
| 50032 | "This account is already signed off for this period." |
| 50040 | "Unknown account." |
| other | "Something went wrong. Please try again." (retry once first – §1) |

---

## 7. Empty and edge states

| Situation | Show |
|---|---|
| `last_run_status` is NULL | "Matching has not run yet" – all counts 0 |
| `last_run_status = 'FAILED'` | Red "Matching run failed" card; data shown is from the last **completed** run |
| No proposals for the account | "No proposed matches" in §3.3 |
| `bank_account_number` / `gl_account_number` NULL | `–` |
| `display_name` equals the account id | normal – names are added later by an admin |
| Row with `status <> 'PENDING'` | checkbox disabled; pill shows Confirmed / Rejected / Exception |
| `exported_at` not NULL | read-only badge "Sent to JDE"; no actions |

---

## 8. Acceptance checklist

- [ ] Sidebar lists every account from §3.1; clicking one updates all screens.
- [ ] Overview numbers equal the §3.2 query for that account.
- [ ] Proposed list paging, search, status and confidence filters work; exceptions are not in this list.
- [ ] Details drawer shows `match_rule`, the reason ticks and all lines of the match.
- [ ] Confirm / Reject (single and multi-select) change `status` and the counts after refresh; a new row appears in Audit.
- [ ] Exceptions: clicking an item shows its candidates; choosing one approves the match; disabled options cannot be chosen.
- [ ] Unmatched lists show `reason`; "Confirm as unmatched" changes the status to "Confirmed unmatched"; undo works.
- [ ] "Complete reconciliation" is disabled until `can_complete = 1`; sign-off appears in history and audit.
- [ ] Every procedure call passes the signed-in user's email as `@user`.
- [ ] The app never writes to a `dbo.bank_recon_*` table directly.
