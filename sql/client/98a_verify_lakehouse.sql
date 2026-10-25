/* =====================================================================================
   FUNCTIONAL VERIFICATION - PART A: run on the LAKEHOUSE SQL analytics endpoint
   (the lakehouse holding proddta.auto_bank_statement_detail_f09617 / proddta.account_ledger_f0911)

   What it shows, straight from the JDE source data:
     A0  totals per bank account          -> compare with PART B, query B0
     A1  the bank lines you filter on     (raw JDE values + the values the engine uses)
     A2  the GL lines you filter on       (raw JDE values + the values the engine uses)
     A3  every possible bank<->GL pair and which matching rule would apply
   Every line gets the same `line_id` the matching engine uses -> copy it into PART B (B2).

   HOW TO USE: change the values in the SETTINGS block, then run the whole script.
   Leave a value NULL to not filter on it. Read-only - nothing is changed.
   ===================================================================================== */

/* ============================== SETTINGS ============================== */
DECLARE @acct              varchar(20)   = '00358555';  -- JDE Account ID (G_L Bank Account / Account ID), NULL = all
DECLARE @amount            decimal(18,2) = 1646.40;     -- amount in currency (e.g. 1646.40 or -1646.40), NULL = all
DECLARE @abs_amount        bit           = 1;           -- 1 = ignore the sign of @amount (match 1646.40 and -1646.40)
DECLARE @date_from         date          = NULL;        -- bank cleared date / GL date from, NULL = no limit
DECLARE @date_to           date          = NULL;        -- ... to
DECLARE @bank_statement_id bigint        = NULL;        -- one bank statement, NULL = all
DECLARE @bank_line_number  bigint        = NULL;        -- its line number AS STORED (x100, e.g. 15200)
DECLARE @doc_type          varchar(4)    = NULL;        -- e.g. 'RC', NULL = all
DECLARE @doc_number        bigint        = NULL;        -- e.g. 7564, NULL = all
DECLARE @tolerance_days    int           = 5;           -- the engine's maximum date window
/* ===================================================================== */


/* ---------- A0. Totals per bank account (compare with PART B query B0) ---------- */
WITH bank AS (
    SELECT LTRIM(RTRIM([G_L Bank Account])) AS acct,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciliation Code], '')))) = 'R' THEN 1 ELSE 0 END AS is_r,
           [Statement Date] AS stmt_date
    FROM proddta.auto_bank_statement_detail_f09617
),
gl AS (
    SELECT LTRIM(RTRIM([Account ID])) AS acct,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciled Code], '')))) = 'R' THEN 1 ELSE 0 END AS is_r
    FROM proddta.account_ledger_f0911
    WHERE LTRIM(RTRIM([Ledger Types])) = 'AA'
      AND LTRIM(RTRIM([Account ID])) IN (SELECT DISTINCT LTRIM(RTRIM([G_L Bank Account]))
                                         FROM proddta.auto_bank_statement_detail_f09617)
)
SELECT a.acct AS gl_bank_account,
       a.bank_lines, a.bank_reconciled, a.bank_lines - a.bank_reconciled AS bank_open,
       a.period_start, a.period_end,
       ISNULL(g.gl_lines, 0) AS gl_lines, ISNULL(g.gl_reconciled, 0) AS gl_reconciled,
       ISNULL(g.gl_lines, 0) - ISNULL(g.gl_reconciled, 0) AS gl_open
FROM (SELECT acct, COUNT(*) AS bank_lines, SUM(is_r) AS bank_reconciled,
             MIN(stmt_date) AS period_start, MAX(stmt_date) AS period_end
      FROM bank GROUP BY acct) a
LEFT JOIN (SELECT acct, COUNT(*) AS gl_lines, SUM(is_r) AS gl_reconciled FROM gl GROUP BY acct) g
       ON g.acct = a.acct
WHERE (@acct IS NULL OR a.acct = @acct)
ORDER BY a.acct;


/* ---------- A1. Bank lines (F09617) ---------- */
SELECT
    CONCAT('B|', CAST(CAST(b.[Bank Statement ID] AS bigint) AS varchar(20)), '|', LTRIM(RTRIM(b.[G_L Bank Account])), '|',
           CONVERT(varchar(10), b.[Statement Date], 23), '|', CAST(CAST(b.[Line Number _ General] AS bigint) AS varchar(20)))
                                                                      AS line_id,          -- same id as in the warehouse
    LTRIM(RTRIM(b.[G_L Bank Account]))                                AS gl_bank_account,
    CAST(b.[Bank Statement ID] AS bigint)                             AS bank_statement_id,
    b.[Statement Date]                                                AS statement_date,
    CAST(b.[Line Number _ General] AS bigint)                         AS line_number_stored,
    b.[Date _ Cleared_Value]                                          AS cleared_date,     -- date the engine compares
    LTRIM(RTRIM(b.[Bank Statement Transaction Code]))                 AS tr_code,
    b.[Debits Entered]                                                AS debits_raw_cents,
    b.[Credits Entered]                                               AS credits_raw_cents,
    CAST(ROUND((ISNULL(b.[Credits Entered],0) - ISNULL(b.[Debits Entered],0)) / 100.0, 2) AS decimal(18,2))
                                                                      AS amount,           -- amount the engine compares
    b.[Reconciliation Code]                                           AS reconciliation_code,
    LTRIM(RTRIM(b.[Misc Information]))                                AS misc_information
FROM proddta.auto_bank_statement_detail_f09617 b
WHERE (@acct IS NULL OR LTRIM(RTRIM(b.[G_L Bank Account])) = @acct)
  AND (@amount IS NULL OR
       (@abs_amount = 1 AND ABS(ROUND((ISNULL(b.[Credits Entered],0) - ISNULL(b.[Debits Entered],0)) / 100.0, 2)) = ABS(@amount)) OR
       (@abs_amount = 0 AND ROUND((ISNULL(b.[Credits Entered],0) - ISNULL(b.[Debits Entered],0)) / 100.0, 2) = @amount))
  AND (@date_from IS NULL OR b.[Date _ Cleared_Value] >= @date_from)
  AND (@date_to   IS NULL OR b.[Date _ Cleared_Value] <= @date_to)
  AND (@bank_statement_id IS NULL OR CAST(b.[Bank Statement ID] AS bigint) = @bank_statement_id)
  AND (@bank_line_number  IS NULL OR CAST(b.[Line Number _ General] AS bigint) = @bank_line_number)
ORDER BY b.[Date _ Cleared_Value], line_id;


/* ---------- A2. GL lines (F0911, bank accounts, ledger AA) ---------- */
SELECT
    CONCAT('G|', LTRIM(RTRIM(g.[Document Type])), '|', CAST(CAST(g.[Document _Voucher Invoice etc] AS bigint) AS varchar(20)), '|',
           LTRIM(RTRIM(g.[Document Company])), '|',
           CONVERT(varchar(10), CAST(g.[Date For G_L _and Voucher Julian] AS date), 23), '|',
           CAST(CAST(g.[Journal Entry Line Number] AS bigint) AS varchar(20)), '|',
           LTRIM(RTRIM(g.[Ledger Types])), '|', ISNULL(LTRIM(RTRIM(CAST(g.[Line Extension Code] AS varchar(10)))), ''))
                                                                      AS line_id,          -- same id as in the warehouse
    LTRIM(RTRIM(g.[Account ID]))                                      AS gl_bank_account,
    LTRIM(RTRIM(g.[Document Type]))                                   AS doc_type,
    CAST(g.[Document _Voucher Invoice etc] AS bigint)                 AS doc_number,
    LTRIM(RTRIM(g.[Document Company]))                                AS doc_company,
    CAST(g.[Date For G_L _and Voucher Julian] AS date)                AS gl_date,          -- date the engine compares
    g.[Journal Entry Line Number]                                     AS je_line_number,
    CAST(ROUND(g.[Amount], 2) AS decimal(18,2))                       AS amount,           -- amount the engine compares
    g.[Reconciled Code]                                               AS reconciled_code,
    LTRIM(RTRIM(g.[Name Alpha Explanation]))                          AS name_alpha,
    LTRIM(RTRIM(g.[Name Remark Explanation]))                         AS name_remark,
    g.[Batch Number]                                                  AS batch_number
FROM proddta.account_ledger_f0911 g
WHERE LTRIM(RTRIM(g.[Ledger Types])) = 'AA'
  AND (@acct IS NULL OR LTRIM(RTRIM(g.[Account ID])) = @acct)
  AND (@amount IS NULL OR
       (@abs_amount = 1 AND ABS(ROUND(g.[Amount], 2)) = ABS(@amount)) OR
       (@abs_amount = 0 AND ROUND(g.[Amount], 2) = @amount))
  AND (@date_from IS NULL OR CAST(g.[Date For G_L _and Voucher Julian] AS date) >= @date_from)
  AND (@date_to   IS NULL OR CAST(g.[Date For G_L _and Voucher Julian] AS date) <= @date_to)
  AND (@doc_type   IS NULL OR LTRIM(RTRIM(g.[Document Type])) = @doc_type)
  AND (@doc_number IS NULL OR CAST(g.[Document _Voucher Invoice etc] AS bigint) = @doc_number)
ORDER BY gl_date, line_id;


/* ---------- A3. Possible 1:1 pairs and the rule that would apply ----------
   Same account + same amount (to the cent). Shows ALL same-amount pairs, closest dates first, and says what
   the engine does with each. NOTE: the engine additionally uses each line only ONCE (closest date wins) and
   skips an 'R' line that already pairs with another 'R' line - compare the "candidate" rows with PART B.     */
WITH b AS (
    SELECT CONCAT('B|', CAST(CAST([Bank Statement ID] AS bigint) AS varchar(20)), '|', LTRIM(RTRIM([G_L Bank Account])), '|',
                  CONVERT(varchar(10), [Statement Date], 23), '|', CAST(CAST([Line Number _ General] AS bigint) AS varchar(20))) AS bank_line_id,
           LTRIM(RTRIM([G_L Bank Account])) AS acct,
           [Date _ Cleared_Value] AS bank_date,
           CAST(ROUND((ISNULL([Credits Entered],0) - ISNULL([Debits Entered],0)) / 100.0, 2) AS decimal(18,2)) AS amount,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciliation Code], '')))) = 'R' THEN 1 ELSE 0 END AS bank_r
    FROM proddta.auto_bank_statement_detail_f09617
    WHERE (@acct IS NULL OR LTRIM(RTRIM([G_L Bank Account])) = @acct)
      AND (@bank_statement_id IS NULL OR CAST([Bank Statement ID] AS bigint) = @bank_statement_id)
      AND (@bank_line_number  IS NULL OR CAST([Line Number _ General] AS bigint) = @bank_line_number)
),
g AS (
    SELECT CONCAT('G|', LTRIM(RTRIM([Document Type])), '|', CAST(CAST([Document _Voucher Invoice etc] AS bigint) AS varchar(20)), '|',
                  LTRIM(RTRIM([Document Company])), '|', CONVERT(varchar(10), CAST([Date For G_L _and Voucher Julian] AS date), 23), '|',
                  CAST(CAST([Journal Entry Line Number] AS bigint) AS varchar(20)), '|', LTRIM(RTRIM([Ledger Types])), '|',
                  ISNULL(LTRIM(RTRIM(CAST([Line Extension Code] AS varchar(10)))), '')) AS gl_line_id,
           LTRIM(RTRIM([Account ID])) AS acct,
           CAST([Date For G_L _and Voucher Julian] AS date) AS gl_date,
           CAST(ROUND([Amount], 2) AS decimal(18,2)) AS amount,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL([Reconciled Code], '')))) = 'R' THEN 1 ELSE 0 END AS gl_r
    FROM proddta.account_ledger_f0911
    WHERE LTRIM(RTRIM([Ledger Types])) = 'AA'
      AND (@acct IS NULL OR LTRIM(RTRIM([Account ID])) = @acct)
      AND (@doc_type   IS NULL OR LTRIM(RTRIM([Document Type])) = @doc_type)
      AND (@doc_number IS NULL OR CAST([Document _Voucher Invoice etc] AS bigint) = @doc_number)
)
SELECT b.bank_line_id, b.bank_date, b.bank_r,
       g.gl_line_id,   g.gl_date,   g.gl_r,
       b.amount,
       DATEDIFF(day, b.bank_date, g.gl_date) AS days_apart,      -- + = GL after bank (T+n), - = GL before (T-n)
       CASE WHEN b.bank_r = 1 AND g.gl_r = 1                     THEN 'Skipped - both already reconciled (R) in JDE'
            WHEN ABS(DATEDIFF(day, b.bank_date, g.gl_date)) > @tolerance_days
                                                                 THEN CONCAT('Not a candidate - more than ', @tolerance_days, ' days apart')
            WHEN DATEDIFF(day, b.bank_date, g.gl_date) = 0       THEN 'Candidate - Rule 2 Exact match'
            ELSE CONCAT('Candidate - Rule ', ABS(DATEDIFF(day, b.bank_date, g.gl_date)) + 2,
                        ' Tolerance +/-', ABS(DATEDIFF(day, b.bank_date, g.gl_date)), ' day(s)')
       END AS engine_rule,
       CASE WHEN b.bank_r = 0 AND g.gl_r = 0 THEN 'BOTH_OPEN'
            WHEN b.bank_r = 1 AND g.gl_r = 0 THEN 'BANK_R_GL_OPEN'
            WHEN b.bank_r = 0 AND g.gl_r = 1 THEN 'GL_R_BANK_OPEN'
            ELSE 'BOTH_R' END AS expected_recon_state
FROM b
JOIN g ON g.acct = b.acct AND g.amount = b.amount
WHERE b.amount <> 0
  AND (@amount IS NULL OR (@abs_amount = 1 AND ABS(b.amount) = ABS(@amount)) OR (@abs_amount = 0 AND b.amount = @amount))
  AND (@date_from IS NULL OR b.bank_date >= @date_from)
  AND (@date_to   IS NULL OR b.bank_date <= @date_to)
ORDER BY ABS(DATEDIFF(day, b.bank_date, g.gl_date)), b.bank_line_id, g.gl_line_id;
