/* =====================================================================================
   Bank Reconciliation - verification queries
   Run in WH_BankRecon (Fabric: open the warehouse -> New SQL query). Read-only.
   Each check says what result to expect. Checks 2 and 8 read the source tables in
   LH_BankRecon through a cross-database query (same workspace).
   ===================================================================================== */

/* 1. Run history - every run should be COMPLETED; counts explain where every line went:
      bank_total = bank_reconciled_skipped + bank_locked_skipped + bank_in_scope (+ lines outside the account/date filter)
      bank_in_scope = bank_matched + bank_unmatched                                                                 */
SELECT run_id, triggered_by, status, started_at, finished_at,
       bank_total, bank_reconciled_skipped, bank_locked_skipped, bank_in_scope, bank_matched, bank_unmatched,
       gl_total,   gl_reconciled_skipped,   gl_locked_skipped,   gl_in_scope,   gl_matched,   gl_unmatched,
       proposals, error_message
FROM recon.run_log
ORDER BY started_at;

/* 2. Reconciled lines are never processed. EXPECT: 0 rows */
SELECT 'BANK' AS side, m.match_id, m.line_id
FROM recon.match_line m
JOIN LH_BankRecon.dbo.jde_f09617_bank_statement s
  ON  s.bank_statement_id = m.bank_statement_id
  AND s.bank_acct_g_l     = m.gl_bank_account
  AND s.statement_date    = m.statement_date
  AND s.line_number       = m.line_number
WHERE m.side = 'BANK' AND UPPER(LTRIM(RTRIM(ISNULL(s.reconciliation_code, '')))) = 'R'
UNION ALL
SELECT 'GL', m.match_id, m.line_id
FROM recon.match_line m
JOIN LH_BankRecon.dbo.jde_f0911_gl g
  ON  g.do_ty           = m.doc_type
  AND g.document_number = m.doc_number
  AND g.doc_co          = m.doc_company
  AND g.g_l_date        = m.gl_date
  AND g.je_line_number  = m.je_line_number
  AND g.lt              = m.ledger_type
  AND ISNULL(g.line_extension, '') = m.line_ext_code
WHERE m.side = 'GL' AND UPPER(LTRIM(RTRIM(ISNULL(g.r_nd, '')))) = 'R';

/* 3. No line is in more than one proposal (across all completed runs). EXPECT: 0 rows */
SELECT l.side, l.line_id, COUNT(*) AS times_used
FROM recon.match_line l
JOIN recon.vw_completed_runs r ON r.run_id = l.run_id
GROUP BY l.side, l.line_id
HAVING COUNT(*) > 1;

/* 4. Every proposal follows the rules. EXPECT: 0 rows
      - bank total = GL total (to the cent)
      - all lines on the same GL bank account
      - date gap within the tier it was found at, and never above 5 days
      - 1:1 has exactly 1 + 1 lines, 1:M has 1 bank + 2..N GL, M:1 has 2..N bank + 1 GL           */
SELECT p.match_id, p.match_type, p.bank_amount, p.gl_amount,
       x.bank_sum, x.gl_sum, x.accounts, x.max_gap, p.tolerance_days, x.bank_n, x.gl_n
FROM recon.match_proposal p
JOIN (
    SELECT b.match_id,
           SUM(CASE WHEN b.side = 'BANK' THEN b.amount ELSE 0 END) AS bank_sum,
           SUM(CASE WHEN b.side = 'GL'   THEN b.amount ELSE 0 END) AS gl_sum,
           SUM(CASE WHEN b.side = 'BANK' THEN 1 ELSE 0 END)        AS bank_n,
           SUM(CASE WHEN b.side = 'GL'   THEN 1 ELSE 0 END)        AS gl_n,
           COUNT(DISTINCT b.gl_bank_account)                       AS accounts,
           DATEDIFF(day, MIN(b.txn_date), MAX(b.txn_date))         AS max_gap
    FROM recon.match_line b
    GROUP BY b.match_id
) x ON x.match_id = p.match_id
WHERE x.bank_sum <> x.gl_sum
   OR x.accounts <> 1
   OR x.max_gap > 5
   OR p.max_date_gap_days > p.tolerance_days
   OR (p.match_category = '1:1' AND (x.bank_n <> 1 OR x.gl_n <> 1))
   OR (p.match_category = '1:M' AND (x.bank_n <> 1 OR x.gl_n < 2))
   OR (p.match_category = 'M:1' AND (x.bank_n < 2 OR x.gl_n <> 1));

/* 5. Proposal mix - how many of each rule fired */
SELECT match_rule, confidence, status, COUNT(*) AS proposals, SUM(bank_amount) AS bank_amount
FROM recon.vw_proposal_review
GROUP BY match_rule, confidence, status
ORDER BY match_rule, confidence, status;

/* 6. Eyeball the matches: bank line next to its GL line(s) */
SELECT p.match_rule, p.confidence, p.status, l.side, l.gl_bank_account, l.txn_date, l.amount,
       l.bank_statement_id, l.line_number, l.tr_code,
       l.doc_type, l.doc_number, l.doc_company, l.je_line_number, l.description
FROM recon.match_proposal p
JOIN recon.match_line l ON l.match_id = p.match_id
ORDER BY p.match_category DESC, p.match_id, l.side;

/* 7. Unmatched lines and why */
SELECT side, reason, COUNT(*) AS lines, SUM(amount) AS amount
FROM recon.vw_unmatched_latest
GROUP BY side, reason
ORDER BY side, lines DESC;

/* 8. Did the engine miss an easy 1:1? Unmatched bank vs unmatched GL with the same account +
      amount within 5 days. EXPECT: 0 rows (a hit means a missed match or a rejected pair) */
SELECT b.line_id AS bank_line, g.line_id AS gl_line, b.gl_bank_account, b.amount,
       b.txn_date AS bank_date, g.txn_date AS gl_date
FROM recon.vw_unmatched_latest b
JOIN recon.vw_unmatched_latest g
  ON  g.side = 'GL' AND b.side = 'BANK'
  AND g.gl_bank_account = b.gl_bank_account
  AND g.amount = b.amount
  AND ABS(DATEDIFF(day, b.txn_date, g.txn_date)) <= 5;

/* 9. Audit trail - who did what, when */
SELECT a.action_at, a.action_by, a.action, a.old_status, a.new_status, a.comment,
       p.match_type, p.bank_amount
FROM recon.audit_log a
LEFT JOIN recon.match_proposal p ON p.match_id = a.match_id
ORDER BY a.action_at DESC;

/* 10. JDE output for approved matches (what Power Automate will write to the CSV) */
SELECT * FROM recon.vw_jde_output ORDER BY approved_at DESC;

/* 11. Current configuration */
SELECT * FROM recon.config ORDER BY param_name;
