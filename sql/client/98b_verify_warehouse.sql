/* =====================================================================================
   FUNCTIONAL VERIFICATION - PART B: run on the WAREHOUSE (dbo.bank_recon_*)
   Use the SAME settings as PART A (98a_verify_lakehouse.sql) to compare both sides.

     B0  totals per account from the latest run   -> compare with PART A, A0
     B1  the matches for your filter: header + every bank / GL line in it
     B2  look up ONE line by its line_id (copied from PART A): matched? unmatched? candidate? decided?
     B3  everything about ONE match (header, lines, alternatives, audit history)
     B4  unmatched lines for your filter, with the reason

   HOW TO USE: change the values in the SETTINGS block, then run the whole script.
   Leave a value NULL to not filter on it. Read-only - nothing is changed.
   ===================================================================================== */

/* ============================== SETTINGS ============================== */
DECLARE @acct        varchar(20)   = '00358555';   -- JDE Account ID, NULL = all
DECLARE @amount      decimal(18,2) = 1646.40;      -- NULL = all
DECLARE @abs_amount  bit           = 1;            -- 1 = ignore the sign of @amount
DECLARE @date_from   date          = NULL;         -- bank cleared date / GL date from
DECLARE @date_to     date          = NULL;         -- ... to
DECLARE @status      varchar(20)   = NULL;         -- PENDING / APPROVED / REJECTED / EXCEPTION, NULL = all
DECLARE @category    varchar(5)    = NULL;         -- '1:1' / '1:M' / 'M:1', NULL = all
DECLARE @line_id     varchar(200)  = NULL;         -- for B2, copied from PART A (A1 / A2 / A3)
DECLARE @match_id    varchar(36)   = NULL;         -- for B3, copied from B1
/* ===================================================================== */


/* ---------- B0. Totals per account from the latest completed run (compare with A0) ---------- */
SELECT gl_bank_account, display_name, last_run_status, last_run_at,
       bank_lines, gl_lines, bank_open, gl_open, period_start, period_end,
       proposed_total, pending_review, confirmed, rejected, exceptions_open, unmatched_bank, unmatched_gl
FROM dbo.vw_bank_recon_ui_overview
WHERE (@acct IS NULL OR gl_bank_account = @acct)
ORDER BY gl_bank_account;
/* Note: bank_open / gl_open here exclude zero amounts, GL older than (first bank date - 5 days)
   and lines locked by earlier runs, so they can be slightly lower than A0. bank_lines / gl_lines must equal A0. */


/* ---------- B1. Matches for the filter: one row per line, grouped by match ---------- */
SELECT p.match_id, p.match_rule, p.match_category, p.confidence, p.recon_state, p.status,
       p.bank_amount AS match_bank_total, p.gl_amount AS match_gl_total, p.max_date_gap_days,
       l.side, l.line_id, l.txn_date, l.amount, l.is_reconciled,
       l.bank_statement_id, l.line_number, l.tr_code,
       l.doc_type, l.doc_number, l.doc_company, l.je_line_number,
       l.description, p.decided_by, p.decided_at
FROM dbo.bank_recon_match_proposal p
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
JOIN dbo.bank_recon_match_line l        ON l.match_id = p.match_id
WHERE (@acct IS NULL OR p.gl_bank_account = @acct)
  AND (@status   IS NULL OR p.status = @status)
  AND (@category IS NULL OR p.match_category = @category)
  -- keep the whole match if ANY of its lines fits the amount / date filter
  AND p.match_id IN (
        SELECT x.match_id FROM dbo.bank_recon_match_line x
        WHERE (@amount IS NULL OR (@abs_amount = 1 AND ABS(x.amount) = ABS(@amount)) OR (@abs_amount = 0 AND x.amount = @amount)
                               OR (@abs_amount = 1 AND ABS(p.bank_amount) = ABS(@amount)) OR (@abs_amount = 0 AND p.bank_amount = @amount))
          AND (@date_from IS NULL OR x.txn_date >= @date_from)
          AND (@date_to   IS NULL OR x.txn_date <= @date_to))
ORDER BY p.match_id, l.side, l.txn_date;


/* ---------- B2. One line, everywhere it appears (paste a line_id from PART A) ---------- */
SELECT 'In a match' AS found_in, l.match_id, p.status AS detail, p.match_rule AS info, p.recon_state AS extra, l.txn_date, l.amount
FROM dbo.bank_recon_match_line l
JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
WHERE l.line_id = @line_id
UNION ALL
SELECT 'Unmatched (latest run)', NULL, u.side, u.reason, CAST(u.nearest_same_amount_gap_days AS varchar(10)), u.txn_date, u.amount
FROM dbo.vw_bank_recon_unmatched_latest u
WHERE u.line_id = @line_id
UNION ALL
SELECT 'Alternative candidate', c.match_id, CASE WHEN c.is_proposed = 1 THEN 'proposed line' ELSE 'alternative' END,
       CONCAT('gap ', c.gap_days, ' day(s)'), NULL, c.txn_date, c.amount
FROM dbo.bank_recon_match_candidate c
WHERE c.line_id = @line_id
UNION ALL
SELECT 'Reviewer decision', NULL, d.decision, d.comment, CONCAT(d.decided_by, ' / ', CONVERT(varchar(19), d.decided_at, 120)), NULL, NULL
FROM dbo.bank_recon_line_decision d
WHERE d.line_id = @line_id AND d.is_active = 1;
/* No rows at all = the engine did not see the line: it is reconciled ('R') in JDE with no open partner,
   has amount 0, is a GL line older than the bank data, is not ledger AA, or is on a non-bank account. */


/* ---------- B3. Everything about one match (paste a match_id from B1) ---------- */
SELECT match_id, match_rule, match_category, confidence, recon_state, status, tolerance_days, max_date_gap_days,
       bank_amount, gl_amount, bank_line_count, gl_line_count, note,
       decided_by, decided_at, decision_comment, export_batch_id, exported_at, created_at
FROM dbo.bank_recon_match_proposal WHERE match_id = @match_id;

SELECT side, line_id, txn_date, amount, is_reconciled, bank_statement_id, line_number, tr_code,
       doc_type, doc_number, doc_company, je_line_number, gl_alpha_name, gl_remark, batch_number, description
FROM dbo.bank_recon_match_line WHERE match_id = @match_id ORDER BY side, txn_date;

SELECT side, line_id, is_proposed, gap_days, txn_date, amount, doc_type, doc_number, bank_statement_id, line_number
FROM dbo.bank_recon_match_candidate WHERE match_id = @match_id ORDER BY is_proposed DESC, gap_days;

SELECT action_at, action_by, action, old_status, new_status, comment
FROM dbo.bank_recon_audit_log WHERE match_id = @match_id ORDER BY action_at;


/* ---------- B4. Unmatched lines for the filter (latest run) ---------- */
SELECT u.side, u.line_id, u.txn_date, u.amount, u.reason, u.nearest_same_amount_gap_days,
       u.bank_statement_id, u.line_number, u.doc_type, u.doc_number, u.description,
       CASE WHEN d.line_id IS NULL THEN 'Unmatched' ELSE 'Confirmed unmatched' END AS review_status
FROM dbo.vw_bank_recon_unmatched_latest u
LEFT JOIN dbo.bank_recon_line_decision d ON d.line_id = u.line_id AND d.side = u.side AND d.is_active = 1
WHERE (@acct IS NULL OR u.gl_bank_account = @acct)
  AND (@amount IS NULL OR (@abs_amount = 1 AND ABS(u.amount) = ABS(@amount)) OR (@abs_amount = 0 AND u.amount = @amount))
  AND (@date_from IS NULL OR u.txn_date >= @date_from)
  AND (@date_to   IS NULL OR u.txn_date <= @date_to)
ORDER BY u.side, u.txn_date;
