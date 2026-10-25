/* =====================================================================================
   FUNCTIONAL VERIFICATION - match by match
     STEP 1 (warehouse)  the proposals
     STEP 2 (warehouse)  the bank / GL lines inside them (match_line)
     STEP 3 (warehouse)  generates, per match, the ready-to-run LAKEHOUSE queries for its bank and GL lines
     STEP 4 (lakehouse)  paste the generated query and compare with the warehouse
   Works for 1:1, 1:M and M:1. Read-only.
   Change the SETTINGS, then run STEP 1, 2 and 3 in the WAREHOUSE.
   ===================================================================================== */

/* ============================== SETTINGS (warehouse) ============================== */
DECLARE @acct      varchar(20)  = '00358555';   -- JDE Account ID, NULL = all accounts
DECLARE @category  varchar(5)   = NULL;         -- '1:1' / '1:M' / 'M:1', NULL = all
DECLARE @status    varchar(20)  = NULL;         -- PENDING / APPROVED / REJECTED / EXCEPTION, NULL = all
DECLARE @rule      varchar(100) = NULL;         -- part of the rule text, e.g. 'Exact', 'T+/-1', 'Many-to-one'; NULL = all
DECLARE @match_id  varchar(36)  = NULL;         -- one match only (copy from STEP 1), NULL = all that fit the filter
DECLARE @top       int          = 20;           -- how many matches to show
/* ================================================================================== */


/* ---------- STEP 1. Proposals ---------- */
SELECT TOP (@top)
       p.match_id, p.gl_bank_account, p.match_category, p.match_rule, p.confidence, p.recon_state, p.status,
       p.bank_line_count, p.gl_line_count, p.bank_amount, p.gl_amount, p.max_date_gap_days, p.note
FROM dbo.bank_recon_match_proposal p
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
WHERE (@acct     IS NULL OR p.gl_bank_account = @acct)
  AND (@category IS NULL OR p.match_category  = @category)
  AND (@status   IS NULL OR p.status          = @status)
  AND (@rule     IS NULL OR p.match_rule LIKE '%' + @rule + '%')
  AND (@match_id IS NULL OR p.match_id        = @match_id)
ORDER BY p.match_category DESC, ABS(p.bank_amount) DESC;


/* ---------- STEP 2. The lines inside those proposals (one row per bank / GL line) ---------- */
SELECT p.match_id, p.match_category, p.match_rule, l.side,
       l.gl_bank_account, l.txn_date, l.amount, l.is_reconciled,
       -- F09617 key (bank rows)
       l.bank_statement_id, l.statement_date, l.line_number, l.tr_code,
       -- F0911 key (GL rows)
       l.doc_type, l.doc_number, l.doc_company, l.gl_date, l.je_line_number, l.ledger_type,
       l.description, l.line_id
FROM dbo.bank_recon_match_proposal p
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
JOIN dbo.bank_recon_match_line l        ON l.match_id = p.match_id
WHERE p.match_id IN (SELECT TOP (@top) p2.match_id
                     FROM dbo.bank_recon_match_proposal p2
                     JOIN dbo.vw_bank_recon_completed_runs r2 ON r2.run_id = p2.run_id
                     WHERE (@acct     IS NULL OR p2.gl_bank_account = @acct)
                       AND (@category IS NULL OR p2.match_category  = @category)
                       AND (@status   IS NULL OR p2.status          = @status)
                       AND (@rule     IS NULL OR p2.match_rule LIKE '%' + @rule + '%')
                       AND (@match_id IS NULL OR p2.match_id        = @match_id)
                     ORDER BY p2.match_category DESC, ABS(p2.bank_amount) DESC)
ORDER BY p.match_category DESC, ABS(p.bank_amount) DESC, p.match_id, l.side, l.txn_date;


/* ---------- STEP 3. Generate the lakehouse queries for each match ----------
   Copy the text in lakehouse_bank_query / lakehouse_gl_query and run it on the LAKEHOUSE SQL endpoint.
   Each returns the source rows of that match plus a running total (bank_total / gl_total).            */
SELECT TOP (@top)
       p.match_id, p.match_category, p.match_rule,
       p.bank_amount AS expected_bank_total, p.gl_amount AS expected_gl_total,
       CONCAT(
         'SELECT ''BANK'' AS side, [G_L Bank Account], [Bank Statement ID], [Statement Date], [Line Number _ General], ',
         '[Date _ Cleared_Value] AS cleared_date, [Bank Statement Transaction Code], [Debits Entered], [Credits Entered], ',
         'CAST(ROUND((ISNULL([Credits Entered],0) - ISNULL([Debits Entered],0)) / 100.0, 2) AS decimal(18,2)) AS amount, ',
         'SUM(CAST(ROUND((ISNULL([Credits Entered],0) - ISNULL([Debits Entered],0)) / 100.0, 2) AS decimal(18,2))) OVER () AS bank_total, ',
         '[Reconciliation Code], [Misc Information] ',
         'FROM proddta.auto_bank_statement_detail_f09617 WHERE ', bk.conds, ';')                      AS lakehouse_bank_query,
       CONCAT(
         'SELECT ''GL'' AS side, [Account ID], [Document Type], [Document _Voucher Invoice etc], [Document Company], ',
         '[Date For G_L _and Voucher Julian] AS gl_date, [Journal Entry Line Number], [Ledger Types], ',
         'CAST(ROUND([Amount], 2) AS decimal(18,2)) AS amount, ',
         'SUM(CAST(ROUND([Amount], 2) AS decimal(18,2))) OVER () AS gl_total, ',
         '[Reconciled Code], [Name Alpha Explanation], [Name Remark Explanation] ',
         'FROM proddta.account_ledger_f0911 WHERE ', gk.conds, ';')                                   AS lakehouse_gl_query
FROM dbo.bank_recon_match_proposal p
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
CROSS APPLY (
    SELECT STRING_AGG(CAST(CONCAT(
             '(LTRIM(RTRIM([G_L Bank Account])) = ''', l.gl_bank_account,
             ''' AND CAST([Bank Statement ID] AS bigint) = ', l.bank_statement_id,
             ' AND [Statement Date] = ''', CONVERT(varchar(10), l.statement_date, 23),
             ''' AND CAST([Line Number _ General] AS bigint) = ', l.line_number, ')') AS varchar(max)), ' OR ') AS conds
    FROM dbo.bank_recon_match_line l
    WHERE l.match_id = p.match_id AND l.side = 'BANK'
) bk
CROSS APPLY (
    SELECT STRING_AGG(CAST(CONCAT(
             '(LTRIM(RTRIM([Account ID])) = ''', l.gl_bank_account,
             ''' AND LTRIM(RTRIM([Document Type])) = ''', l.doc_type,
             ''' AND CAST([Document _Voucher Invoice etc] AS bigint) = ', l.doc_number,
             ' AND LTRIM(RTRIM([Document Company])) = ''', l.doc_company,
             ''' AND CAST([Date For G_L _and Voucher Julian] AS date) = ''', CONVERT(varchar(10), l.gl_date, 23),
             ''' AND CAST([Journal Entry Line Number] AS bigint) = ', l.je_line_number,
             ' AND LTRIM(RTRIM([Ledger Types])) = ''', l.ledger_type, ''')') AS varchar(max)), ' OR ') AS conds
    FROM dbo.bank_recon_match_line l
    WHERE l.match_id = p.match_id AND l.side = 'GL'
) gk
WHERE (@acct     IS NULL OR p.gl_bank_account = @acct)
  AND (@category IS NULL OR p.match_category  = @category)
  AND (@status   IS NULL OR p.status          = @status)
  AND (@rule     IS NULL OR p.match_rule LIKE '%' + @rule + '%')
  AND (@match_id IS NULL OR p.match_id        = @match_id)
ORDER BY p.match_category DESC, ABS(p.bank_amount) DESC;


/* ---------- STEP 4. In the LAKEHOUSE: paste the generated query and check ----------
   For the match you are verifying:
     [ ] number of rows        = bank_line_count / gl_line_count from STEP 1
     [ ] bank_total            = expected_bank_total   (all rows show the same total)
     [ ] gl_total              = expected_gl_total
     [ ] bank_total            = gl_total              (every match balances to the cent)
     [ ] dates: cleared_date vs gl_date within the rule's window (Exact = same day, T+/-n = n days)
     [ ] Reconciliation Code / Reconciled Code agree with recon_state:
           BOTH_OPEN      -> both blank
           GL_R_BANK_OPEN -> GL 'R', bank blank
           BANK_R_GL_OPEN -> bank 'R', GL blank
     [ ] 1:M -> 1 bank row, 2-5 GL rows;  M:1 -> 2-5 bank rows, 1 GL row;  each part >= 1% of the single side
*/
