/* =====================================================================================
   Bank Reconciliation - CLIENT checks (Step 10). Read-only except check 9 (approve test).
   Run each block on its own in the warehouse SQL editor. "EXPECT: 0 rows" = must be empty.
   ===================================================================================== */

/* 1. Run history - latest run should be COMPLETED, error_message empty */
SELECT run_id, triggered_by, status, started_at, finished_at,
       bank_total, bank_reconciled_skipped, bank_locked_skipped, bank_in_scope, bank_matched, bank_unmatched,
       gl_total,   gl_reconciled_skipped,   gl_locked_skipped,   gl_in_scope,   gl_matched,   gl_unmatched,
       proposals, error_message
FROM dbo.bank_recon_run_log
ORDER BY started_at DESC;

/* 2. No line in more than one proposal (all completed runs). EXPECT: 0 rows */
SELECT l.side, l.line_id, COUNT(*) AS times_used
FROM dbo.bank_recon_match_line l
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = l.run_id
GROUP BY l.side, l.line_id
HAVING COUNT(*) > 1;

/* 3. Every proposal follows the rules. EXPECT: 0 rows
      bank total = GL total, one account, gap <= 5 days, right number of lines per category */
SELECT p.match_id, p.match_type, p.bank_amount, p.gl_amount, x.bank_sum, x.gl_sum,
       x.accounts, x.max_gap, x.bank_n, x.gl_n
FROM dbo.bank_recon_match_proposal p
JOIN (SELECT match_id,
             SUM(CASE WHEN side = 'BANK' THEN amount ELSE 0 END) AS bank_sum,
             SUM(CASE WHEN side = 'GL'   THEN amount ELSE 0 END) AS gl_sum,
             SUM(CASE WHEN side = 'BANK' THEN 1 ELSE 0 END)      AS bank_n,
             SUM(CASE WHEN side = 'GL'   THEN 1 ELSE 0 END)      AS gl_n,
             COUNT(DISTINCT gl_bank_account)                     AS accounts,
             DATEDIFF(day, MIN(txn_date), MAX(txn_date))         AS max_gap
      FROM dbo.bank_recon_match_line GROUP BY match_id) x ON x.match_id = p.match_id
WHERE x.bank_sum <> x.gl_sum OR p.bank_amount <> p.gl_amount
   OR x.accounts <> 1 OR x.max_gap > 5
   OR (p.match_category = '1:1' AND (x.bank_n <> 1 OR x.gl_n <> 1))
   OR (p.match_category = '1:M' AND (x.bank_n <> 1 OR x.gl_n < 2))
   OR (p.match_category = 'M:1' AND (x.bank_n < 2 OR x.gl_n <> 1));

/* 4. recon_state agrees with the lines' is_reconciled flags; never both sides 'R'. EXPECT: 0 rows */
SELECT p.match_id, p.recon_state, x.bank_r, x.gl_r
FROM dbo.bank_recon_match_proposal p
JOIN (SELECT match_id,
             MAX(CASE WHEN side = 'BANK' AND is_reconciled = 1 THEN 1 ELSE 0 END) AS bank_r,
             MAX(CASE WHEN side = 'GL'   AND is_reconciled = 1 THEN 1 ELSE 0 END) AS gl_r
      FROM dbo.bank_recon_match_line GROUP BY match_id) x ON x.match_id = p.match_id
WHERE (x.bank_r = 1 AND x.gl_r = 1)
   OR (p.recon_state = 'BOTH_OPEN'      AND (x.bank_r = 1 OR x.gl_r = 1))
   OR (p.recon_state = 'GL_R_BANK_OPEN' AND NOT (x.gl_r = 1 AND x.bank_r = 0))
   OR (p.recon_state = 'BANK_R_GL_OPEN' AND NOT (x.bank_r = 1 AND x.gl_r = 0))
   OR (p.match_category <> '1:1' AND p.recon_state <> 'BOTH_OPEN');

/* 5. A line is either matched or unmatched in a run - never both. EXPECT: 0 rows */
SELECT u.run_id, u.side, u.line_id
FROM dbo.bank_recon_unmatched_line u
JOIN dbo.bank_recon_match_line l ON l.run_id = u.run_id AND l.side = u.side AND l.line_id = u.line_id;

/* 6. What the run produced - by rule, state and confidence (compare with the Step 7 printout) */
SELECT match_rule, recon_state, confidence, COUNT(*) AS proposals, SUM(bank_amount) AS bank_amount
FROM dbo.vw_bank_recon_proposal_review
GROUP BY match_rule, recon_state, confidence
ORDER BY match_rule, recon_state, confidence;

/* 7. Unmatched lines by reason */
SELECT side, reason, COUNT(*) AS lines, SUM(amount) AS amount
FROM dbo.vw_bank_recon_unmatched_latest
GROUP BY side, reason
ORDER BY side, lines DESC;

/* 8. Lines the next run will skip (should equal the number of matched lines) */
SELECT COUNT(*) AS locked_lines FROM dbo.vw_bank_recon_locked_lines;

/* 9. Approve / audit test on ONE proposal, then put it back to PENDING.
      Run 9a, copy one match_id into 9b and 9d, then run 9b, 9c, 9d one by one. */
-- 9a. pick one
SELECT TOP 1 match_id, match_rule, bank_amount FROM dbo.vw_bank_recon_proposal_review
WHERE status = 'PENDING' AND confidence = 'HIGH';
-- 9b. approve it (replace <match_id>)
EXEC dbo.usp_bank_recon_decide_match @match_ids = '<match_id>', @action = 'APPROVE',
     @user = 'test@dynatech', @comment = 'Step 10 test';
-- 9c. it is now APPROVED, in the JDE output, and in the audit log
SELECT status, decided_by, decided_at FROM dbo.bank_recon_match_proposal WHERE match_id = '<match_id>';
SELECT * FROM dbo.vw_bank_recon_jde_output WHERE match_id = '<match_id>';
SELECT * FROM dbo.bank_recon_audit_log WHERE match_id = '<match_id>' ORDER BY action_at;
-- 9d. put it back to PENDING (also audited)
EXEC dbo.usp_bank_recon_decide_match @match_ids = '<match_id>', @action = 'REOPEN',
     @user = 'test@dynatech', @comment = 'Step 10 test - undo';
