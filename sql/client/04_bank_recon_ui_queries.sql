/* =====================================================================================
   Bank Reconciliation - UI queries, screen by screen, for ONE bank account.
   Read with SELECT on the views, write with EXEC on the procedures. Nothing here changes
   data except the EXEC examples in sections 5, 6 and 7.

   @acct = the JDE Account ID of the account selected in the sidebar (e.g. '00358555').
   In Power Apps: Filter(<view>, gl_bank_account = SelectedAccount) does the same as WHERE.
   ===================================================================================== */
DECLARE @acct varchar(20) = '00358555';
DECLARE @user varchar(200) = 'jane@trispharma.com';   -- in the app: User().Email


/* ---------- 0. Sidebar: account list with the badge counts ---------- */
SELECT gl_bank_account, display_name, gl_account_number, sort_order,
       pending_review, exceptions_open, unmatched_bank, unmatched_gl
FROM dbo.vw_bank_recon_ui_accounts
ORDER BY ISNULL(sort_order, 999), display_name;


/* ---------- 1. Dashboard header + cards + KPIs (one row) ---------- */
SELECT
    -- top right: bank start and end date
    period_start                       AS bank_start_date,
    period_end                         AS bank_end_date,
    -- account context
    display_name                       AS current_account,          -- client name, else GL account number
    bank_account_number                AS electronic_bank_account_number,   -- NULL until the client provides it
    gl_account_number                  AS gl_account_number,
    -- cards
    bank_lines                         AS bank_activity_total_rows,
    gl_lines                           AS general_ledger_total_rows,
    last_run_status                    AS matching_engine_status,   -- COMPLETED / FAILED / NULL (never run)
    last_run_at                        AS matching_engine_last_run,
    confirmed                          AS analyst_review_confirmed,
    bank_loaded_at, gl_loaded_at,                                   -- freshness of the JDE data
    source_files_detected,                                          -- 1 = green (bank AND ledger rows exist)
    -- KPIs
    proposed_total                     AS proposed_matches,
    pending_review                     AS proposed_pending,
    confirmed                          AS approved,
    rejected,
    exceptions_open                    AS exceptions,
    unmatched_bank,
    unmatched_gl,
    progress_pct, can_complete
FROM dbo.vw_bank_recon_ui_overview
WHERE gl_bank_account = @acct;


/* ---------- 2. Proposed matches list (side by side), excluding exceptions ----------
   Status filter in the UI: PENDING / APPROVED / REJECTED. Paging: OFFSET / FETCH.        */
SELECT match_id, status, confidence, review_group, match_rule,
       -- Account activity (bank) side
       bank_date, bank_amount, bank_reference          AS reference,
       bank_tr_code                                    AS description,        -- CK / CR / JE
       bank_txn_type                                   AS transaction_type,   -- External Transaction Type code
       bank_statement_lines                            AS source_row,         -- 'statement/line'
       -- General ledger side
       gl_date, gl_amount, gl_alpha_name                AS name,
       gl_documents                                    AS document,
       gl_batches                                      AS batch,
       CONCAT(gl_account_number, ' / ', gl_business_unit) AS account_bu,
       bank_line_count, gl_line_count
FROM dbo.vw_bank_recon_ui_matches
WHERE gl_bank_account = @acct
  AND is_exception = 0
  AND status = 'PENDING'                                -- or 'APPROVED' / 'REJECTED' / remove for all
  -- AND search_text LIKE '%' + LOWER(@search) + '%'   -- search box
ORDER BY bank_date DESC, bank_amount DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;                 -- page 1 of 50 rows


/* ---------- 3. "Info" on a match: why proposed + all its lines ---------- */
DECLARE @match_id varchar(36) = '<match_id from section 2>';

SELECT match_rule, confidence, recon_state,
       reason_date,          -- 'Same date' / 'Dates 1 day apart'
       reason_amount,        -- 'Exact amount'
       reason_unique,        -- 'Unique candidate' / 'Several candidates' / 'n lines combined'
       reason_recon_state,   -- set when JDE already shows 'R' on one side
       note
FROM dbo.vw_bank_recon_ui_matches
WHERE match_id = @match_id;

SELECT side, txn_date, amount, description, tr_code, external_txn_type,
       bank_statement_id, line_number,                                   -- bank rows
       doc_type, doc_number, doc_company, gl_alpha_name, gl_remark,
       batch_number, account_number, business_unit,                      -- GL rows
       is_reconciled
FROM dbo.vw_bank_recon_ui_match_lines
WHERE match_id = @match_id
ORDER BY side, txn_date;


/* ---------- 4. Confirm / Reject selected rows (comma-separated match_ids) ---------- */
-- EXEC dbo.usp_bank_recon_decide_match @match_ids = '<id1>,<id2>', @action = 'APPROVE', @user = @user;
-- EXEC dbo.usp_bank_recon_decide_match @match_ids = '<id1>,<id2>', @action = 'REJECT',  @user = @user;
-- "Confirm all displayed": pass all match_ids currently shown on the page.
-- Afterwards re-run section 2 (status changed) and section 1 (counts changed).


/* ---------- 5. Exceptions: queue (left panel) ---------- */
SELECT match_id, exception_label,          -- 'Multiple candidates' / 'Flagged by reviewer'
       bank_date, bank_amount, bank_reference, bank_statement_lines,
       gl_date, gl_documents, gl_alpha_name, candidate_count, note
FROM dbo.vw_bank_recon_ui_exceptions
WHERE gl_bank_account = @acct
ORDER BY bank_date DESC;

/* ---------- 5b. Exceptions: click a record -> the possible matches (right panel) ---------- */
DECLARE @ex_match_id varchar(36) = '<match_id from 5>';
SELECT line_id, side, is_proposed, used_in_other_match,     -- used_in_other_match = 1 -> disable the radio button
       txn_date, amount, doc_type, doc_number, doc_company, gl_alpha_name, gl_remark,
       batch_number, account_number, bank_statement_id, line_number, gap_days
FROM dbo.vw_bank_recon_ui_exception_candidates
WHERE match_id = @ex_match_id
ORDER BY is_proposed DESC, gap_days, txn_date;

/* ---------- 5c. Exceptions: buttons ---------- */
-- "Match selected candidate"  (swaps in that line and approves the match)
-- EXEC dbo.usp_bank_recon_resolve_exception @match_id = @ex_match_id, @line_id = '<line_id from 5b>', @user = @user;
-- "Leave unmatched"           (rejects the proposal - the lines become unmatched in the next run)
-- EXEC dbo.usp_bank_recon_decide_match @match_ids = @ex_match_id, @action = 'REJECT', @user = @user,
--      @comment = 'Left unmatched from exception screen';


/* ---------- 6. Unmatched bank records ---------- */
SELECT line_id, post_date, amount, reference, tr_code AS description, external_txn_type AS transaction_type,
       bank_statement_id, line_number, reason, nearest_same_amount_gap_days, status
FROM dbo.vw_bank_recon_ui_unmatched_bank
WHERE gl_bank_account = @acct
ORDER BY post_date DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;
-- "Confirm as unmatched":
-- EXEC dbo.usp_bank_recon_confirm_unmatched @side = 'BANK', @line_ids = '<line_id>,<line_id>', @action = 'CONFIRM', @user = @user;


/* ---------- 7. Unmatched G/L records ---------- */
SELECT line_id, gl_date, amount, gl_alpha_name AS name, gl_remark AS remark_explanation,
       doc_type AS document_type, doc_number AS document, batch_number AS batch,
       account_number, business_unit, reason, nearest_same_amount_gap_days, status
FROM dbo.vw_bank_recon_ui_unmatched_gl
WHERE gl_bank_account = @acct
ORDER BY gl_date DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;
-- "Confirm as unmatched":
-- EXEC dbo.usp_bank_recon_confirm_unmatched @side = 'GL', @line_ids = '<line_id>', @action = 'CONFIRM', @user = @user;


/* ---------- 8. Summary & sign-off ---------- */
SELECT bank_lines, gl_lines, proposed_total, confirmed, rejected, exceptions_open,
       unmatched_bank, unmatched_gl, source_files_detected, last_run_status, can_complete, period_end
FROM dbo.vw_bank_recon_ui_overview WHERE gl_bank_account = @acct;
-- "Complete reconciliation" (button enabled only when can_complete = 1):
-- EXEC dbo.usp_bank_recon_complete @gl_bank_account = @acct, @period_end = '<period_end>', @user = @user;


/* ---------- 9. Audit history ---------- */
SELECT TOP 100 event_at, event_by, event_type, event_text
FROM dbo.vw_bank_recon_ui_audit
WHERE gl_bank_account = @acct
ORDER BY event_at DESC;
