/* =====================================================================================
   Bank Reconciliation - CLIENT objects for the Reconcile workbench UI (schema dbo)
   Run AFTER 01_bank_recon_tables.sql and 02_bank_recon_views_procs.sql. Safe to re-run.

   UI screen                    -> object
   ---------------------------------------------------------------------------------
   Sidebar (accounts + counts)  -> dbo.vw_bank_recon_ui_accounts   (accounts come from the data; account table optional)
   Overview / KPIs / progress   -> dbo.vw_bank_recon_ui_overview
   Proposed matches (list)      -> dbo.vw_bank_recon_ui_matches
   Match detail drawer          -> dbo.vw_bank_recon_ui_match_lines
   Exceptions (queue)           -> dbo.vw_bank_recon_ui_exceptions
   Exceptions (G/L candidates)  -> dbo.vw_bank_recon_ui_exception_candidates
   Unmatched bank / G/L         -> dbo.vw_bank_recon_ui_unmatched_bank / _gl
   Summary & sign-off           -> dbo.vw_bank_recon_ui_overview + dbo.vw_bank_recon_ui_signoff
   Audit history                -> dbo.vw_bank_recon_ui_audit
   Confirm / reject (bulk)      -> dbo.usp_bank_recon_decide_match            (file 02)
   Match selected candidate     -> dbo.usp_bank_recon_resolve_exception
   Leave / confirm unmatched    -> dbo.usp_bank_recon_confirm_unmatched
   Complete reconciliation      -> dbo.usp_bank_recon_complete
   Account names from client    -> dbo.usp_bank_recon_set_account
   ===================================================================================== */

/* ---------- Account master: what the sidebar shows ----------
   NO hard-coded rows. The notebook (Step 9) adds every bank account it finds in the data, with the
   GL account number taken from F0911. Display name / bank account number / sort order stay empty
   until the client provides them -> dbo.usp_bank_recon_set_account. Until then the UI shows the
   GL account number. Existing rows are never overwritten by the notebook. */
IF OBJECT_ID('dbo.bank_recon_account') IS NULL
BEGIN
    CREATE TABLE dbo.bank_recon_account (
        gl_bank_account      varchar(20)  NOT NULL,   -- JDE Account ID (F09617 G_L Bank Account = F0911 Account ID)
        gl_account_number    varchar(50)  NULL,       -- BU.Object.Sub from F0911, e.g. '4.11310.OPERATE'
        display_name         varchar(100) NULL,       -- from the client (name shown in the sidebar)
        bank_account_number  varchar(30)  NULL,       -- from the client: Electronic Bank Account Number
        sort_order           int          NULL,       -- from the client (sidebar order)
        is_active            bit          NOT NULL,
        first_seen_run_id    varchar(36)  NULL,       -- run that discovered the account
        first_seen_at        datetime2(6) NULL,
        updated_by           varchar(200) NULL,
        updated_at           datetime2(6) NULL
    );
    ALTER TABLE dbo.bank_recon_account ADD CONSTRAINT pk_bank_recon_account
        PRIMARY KEY NONCLUSTERED (gl_bank_account) NOT ENFORCED;
END;
GO

/* ---------- Extra display columns the UI shows (added one by one at the END of the existing tables; COL_LENGTH is not supported in Fabric) ---------- */
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'external_txn_type') ALTER TABLE dbo.bank_recon_match_line ADD external_txn_type varchar(10) NULL;   -- bank: External Transaction Type
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'bank_reference_1') ALTER TABLE dbo.bank_recon_match_line ADD bank_reference_1 varchar(50) NULL;   -- bank: Reference 1
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'gl_alpha_name') ALTER TABLE dbo.bank_recon_match_line ADD gl_alpha_name varchar(100) NULL;   -- GL: Name Alpha Explanation  (UI 'Name - Alpha')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'gl_remark') ALTER TABLE dbo.bank_recon_match_line ADD gl_remark varchar(100) NULL;   -- GL: Name Remark Explanation (UI 'Name - Remark Explanation')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'batch_number') ALTER TABLE dbo.bank_recon_match_line ADD batch_number varchar(20) NULL;   -- GL: Batch Number            (UI 'Batch')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'account_number') ALTER TABLE dbo.bank_recon_match_line ADD account_number varchar(50) NULL;   -- GL: Account Number          (UI 'Account')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_match_line') AND name = 'business_unit') ALTER TABLE dbo.bank_recon_match_line ADD business_unit varchar(20) NULL;   -- GL: Business Unit           (UI 'BU')
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'external_txn_type') ALTER TABLE dbo.bank_recon_unmatched_line ADD external_txn_type varchar(10) NULL;   -- bank: External Transaction Type
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'bank_reference_1') ALTER TABLE dbo.bank_recon_unmatched_line ADD bank_reference_1 varchar(50) NULL;   -- bank: Reference 1
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'gl_alpha_name') ALTER TABLE dbo.bank_recon_unmatched_line ADD gl_alpha_name varchar(100) NULL;   -- GL: Name Alpha Explanation  (UI 'Name - Alpha')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'gl_remark') ALTER TABLE dbo.bank_recon_unmatched_line ADD gl_remark varchar(100) NULL;   -- GL: Name Remark Explanation (UI 'Name - Remark Explanation')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'batch_number') ALTER TABLE dbo.bank_recon_unmatched_line ADD batch_number varchar(20) NULL;   -- GL: Batch Number            (UI 'Batch')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'account_number') ALTER TABLE dbo.bank_recon_unmatched_line ADD account_number varchar(50) NULL;   -- GL: Account Number          (UI 'Account')
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_unmatched_line') AND name = 'business_unit') ALTER TABLE dbo.bank_recon_unmatched_line ADD business_unit varchar(20) NULL;   -- GL: Business Unit           (UI 'BU')
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_audit_log') AND name = 'gl_bank_account') ALTER TABLE dbo.bank_recon_audit_log ADD gl_bank_account varchar(20) NULL;   -- for actions not tied to a match (unmatched, sign-off)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_audit_log') AND name = 'line_id') ALTER TABLE dbo.bank_recon_audit_log ADD line_id varchar(200) NULL;   -- line the action was about
GO

/* ---------- Refresh the 02 views that use SELECT * ----------
   A view with * keeps the column list it had when created, so after adding columns it must be re-created. */
CREATE OR ALTER VIEW dbo.vw_bank_recon_unmatched_latest AS
SELECT u.*
FROM dbo.bank_recon_unmatched_line u
WHERE u.run_id = (SELECT TOP 1 run_id FROM dbo.vw_bank_recon_completed_runs ORDER BY finished_at DESC);
GO
CREATE OR ALTER VIEW dbo.vw_bank_recon_proposal_lines AS
SELECT l.*, p.status, p.match_type, p.match_rule, p.confidence, p.recon_state
FROM dbo.bank_recon_match_line l
JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id;
GO

/* ---------- Per-account run statistics (overview cards, period ending) - written by the notebook ---------- */
IF OBJECT_ID('dbo.bank_recon_run_account') IS NULL
CREATE TABLE dbo.bank_recon_run_account (
    run_id            varchar(36)  NOT NULL,
    gl_bank_account   varchar(20)  NOT NULL,
    bank_lines        int          NOT NULL,   -- all bank lines of the account
    gl_lines          int          NOT NULL,   -- all GL lines of the account (AA, in date scope)
    bank_open         int          NOT NULL,   -- not reconciled in JDE
    gl_open           int          NOT NULL,
    proposals         int          NOT NULL,   -- created in this run
    bank_unmatched    int          NOT NULL,
    gl_unmatched      int          NOT NULL,
    period_end        date         NULL,       -- latest bank statement date of the account
    bank_loaded_at    datetime2(6) NULL,       -- source LoadDate (freshness of the JDE data)
    gl_loaded_at      datetime2(6) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.bank_recon_run_account') AND name = 'period_start')
    ALTER TABLE dbo.bank_recon_run_account ADD period_start date NULL;   -- first bank statement date of the account (UI top right)
GO

/* ---------- Alternative candidates of MEDIUM matches (exception screen) - written by the notebook ---------- */
IF OBJECT_ID('dbo.bank_recon_match_candidate') IS NULL
CREATE TABLE dbo.bank_recon_match_candidate (
    match_id            varchar(36)   NOT NULL,
    run_id              varchar(36)   NOT NULL,
    side                varchar(4)    NOT NULL,   -- side of the alternative line (BANK / GL)
    line_id             varchar(200)  NOT NULL,
    is_proposed         bit           NOT NULL,   -- 1 = the line currently in the match
    gap_days            int           NOT NULL,
    gl_bank_account     varchar(20)   NOT NULL,
    txn_date            date          NOT NULL,
    amount              decimal(18,2) NOT NULL,
    is_reconciled       bit           NOT NULL,
    description         varchar(500)  NULL,
    bank_statement_id   varchar(20)   NULL,
    statement_date      date          NULL,
    line_number         varchar(10)   NULL,
    tr_code             varchar(4)    NULL,
    doc_type            varchar(4)    NULL,
    doc_number          varchar(20)   NULL,
    doc_company         varchar(10)   NULL,
    gl_date             date          NULL,
    je_line_number      varchar(10)   NULL,
    ledger_type         varchar(4)    NULL,
    line_ext_code       varchar(4)    NULL,
    external_txn_type   varchar(10)   NULL,
    bank_reference_1    varchar(50)   NULL,
    gl_alpha_name       varchar(100)  NULL,
    gl_remark           varchar(100)  NULL,
    batch_number        varchar(20)   NULL,
    account_number      varchar(50)   NULL,
    business_unit       varchar(20)   NULL
);
GO

/* ---------- Reviewer decisions on unmatched lines ("Confirm as unmatched") ---------- */
IF OBJECT_ID('dbo.bank_recon_line_decision') IS NULL
CREATE TABLE dbo.bank_recon_line_decision (
    decision_id      varchar(36)   NOT NULL,
    side             varchar(4)    NOT NULL,
    line_id          varchar(200)  NOT NULL,
    gl_bank_account  varchar(20)   NOT NULL,
    decision         varchar(30)   NOT NULL,   -- CONFIRMED_UNMATCHED
    is_active        bit           NOT NULL,   -- 0 after UNDO
    decided_by       varchar(200)  NOT NULL,
    decided_at       datetime2(6)  NOT NULL,
    comment          varchar(1000) NULL
);
GO

/* ---------- Sign-off per account and period ("Complete reconciliation") ---------- */
IF OBJECT_ID('dbo.bank_recon_signoff') IS NULL
CREATE TABLE dbo.bank_recon_signoff (
    signoff_id        varchar(36)   NOT NULL,
    gl_bank_account   varchar(20)   NOT NULL,
    period_end        date          NOT NULL,
    signed_by         varchar(200)  NOT NULL,
    signed_at         datetime2(6)  NOT NULL,
    proposals         int           NOT NULL,   -- control totals at sign-off
    confirmed         int           NOT NULL,
    rejected          int           NOT NULL,
    unmatched_bank    int           NOT NULL,
    unmatched_gl      int           NOT NULL,
    comment           varchar(1000) NULL
);
GO

/* =====================================================================================
   VIEWS
   ===================================================================================== */

/* Latest completed run (most screens show the current state) */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_latest_run AS
SELECT TOP 1 * FROM dbo.vw_bank_recon_completed_runs ORDER BY finished_at DESC;
GO

/* Per-account counters used by the sidebar, overview and summary.
   Exceptions = MEDIUM matches still pending (several candidates) + matches a reviewer flagged EXCEPTION. */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_overview AS
WITH p AS (
    SELECT p.gl_bank_account,
           COUNT(*)                                                                    AS proposed_total,
           SUM(CASE WHEN p.status = 'PENDING' AND p.confidence <> 'MEDIUM' THEN 1 ELSE 0 END) AS pending_review,
           SUM(CASE WHEN p.status = 'APPROVED' THEN 1 ELSE 0 END)                       AS confirmed,
           SUM(CASE WHEN p.status = 'REJECTED' THEN 1 ELSE 0 END)                       AS rejected,
           SUM(CASE WHEN p.status = 'EXCEPTION'
                     OR (p.status = 'PENDING' AND p.confidence = 'MEDIUM') THEN 1 ELSE 0 END) AS exceptions_open,
           SUM(CASE WHEN p.exported_at IS NOT NULL THEN 1 ELSE 0 END)                   AS exported
    FROM dbo.bank_recon_match_proposal p
    JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
    GROUP BY p.gl_bank_account
),
u AS (
    SELECT u.gl_bank_account,
           SUM(CASE WHEN u.side = 'BANK' THEN 1 ELSE 0 END) AS unmatched_bank,
           SUM(CASE WHEN u.side = 'GL'   THEN 1 ELSE 0 END) AS unmatched_gl,
           SUM(CASE WHEN d.line_id IS NOT NULL THEN 1 ELSE 0 END) AS confirmed_unmatched
    FROM dbo.vw_bank_recon_unmatched_latest u
    LEFT JOIN dbo.bank_recon_line_decision d
           ON d.line_id = u.line_id AND d.side = u.side AND d.is_active = 1
    GROUP BY u.gl_bank_account
),
s AS (
    SELECT ra.* FROM dbo.bank_recon_run_account ra
    JOIN dbo.vw_bank_recon_ui_latest_run lr ON lr.run_id = ra.run_id
),
-- Every account that appears anywhere in the results - the account table is NOT required
acc AS (
    SELECT gl_bank_account FROM s
    UNION SELECT gl_bank_account FROM dbo.bank_recon_match_proposal
    UNION SELECT gl_bank_account FROM dbo.bank_recon_unmatched_line
    UNION SELECT gl_bank_account FROM dbo.bank_recon_account
),
-- GL account number (BU.Object.Sub) read from the GL lines, used when the account table has none
ga AS (
    SELECT gl_bank_account, MAX(account_number) AS gl_account_number
    FROM (SELECT gl_bank_account, account_number FROM dbo.bank_recon_match_line   WHERE side = 'GL'
          UNION ALL
          SELECT gl_bank_account, account_number FROM dbo.bank_recon_unmatched_line WHERE side = 'GL') x
    WHERE account_number IS NOT NULL AND account_number <> ''
    GROUP BY gl_bank_account
)
SELECT acc.gl_bank_account,
       -- name: client name -> GL account number -> account id
       COALESCE(a.display_name, a.gl_account_number, ga.gl_account_number, acc.gl_bank_account) AS display_name,
       a.bank_account_number,                                                    -- NULL until the client provides it
       COALESCE(a.gl_account_number, ga.gl_account_number) AS gl_account_number,
       a.sort_order,
       lr.run_id AS last_run_id, lr.finished_at AS last_run_at, lr.status AS last_run_status,
       s.period_start, s.period_end, s.bank_lines, s.gl_lines, s.bank_open, s.gl_open, s.bank_loaded_at, s.gl_loaded_at,
       CASE WHEN ISNULL(s.bank_lines, 0) > 0 THEN 1 ELSE 0 END AS bank_data_available,
       CASE WHEN ISNULL(s.gl_lines, 0) > 0 THEN 1 ELSE 0 END   AS gl_data_available,
       CASE WHEN ISNULL(s.bank_lines, 0) > 0 AND ISNULL(s.gl_lines, 0) > 0 THEN 1 ELSE 0 END AS source_files_detected,
       ISNULL(p.proposed_total, 0)  AS proposed_total,
       ISNULL(p.pending_review, 0)  AS pending_review,
       ISNULL(p.confirmed, 0)       AS confirmed,
       ISNULL(p.rejected, 0)        AS rejected,
       ISNULL(p.exceptions_open, 0) AS exceptions_open,
       ISNULL(p.exported, 0)        AS exported,
       ISNULL(u.unmatched_bank, 0)  AS unmatched_bank,
       ISNULL(u.unmatched_gl, 0)    AS unmatched_gl,
       ISNULL(u.confirmed_unmatched, 0) AS confirmed_unmatched,
       CASE WHEN ISNULL(p.proposed_total, 0) = 0 THEN 0
            ELSE CAST(100.0 * ISNULL(p.confirmed, 0) / p.proposed_total AS decimal(5,1)) END AS progress_pct,
       CASE WHEN ISNULL(p.pending_review, 0) = 0 AND ISNULL(p.exceptions_open, 0) = 0 THEN 1 ELSE 0 END AS can_complete
FROM acc
LEFT JOIN dbo.bank_recon_account a ON a.gl_bank_account = acc.gl_bank_account   -- optional details
LEFT JOIN ga ON ga.gl_bank_account = acc.gl_bank_account
LEFT JOIN dbo.vw_bank_recon_ui_latest_run lr ON 1 = 1
LEFT JOIN p ON p.gl_bank_account = acc.gl_bank_account
LEFT JOIN u ON u.gl_bank_account = acc.gl_bank_account
LEFT JOIN s ON s.gl_bank_account = acc.gl_bank_account
WHERE ISNULL(a.is_active, 1) = 1;      -- hidden only if someone set is_active = 0
GO

/* Sidebar: account list with the 4 badge counts */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_accounts AS
SELECT gl_bank_account, display_name, bank_account_number, gl_account_number, sort_order,
       pending_review, exceptions_open, unmatched_bank, unmatched_gl, period_end
FROM dbo.vw_bank_recon_ui_overview;
GO

/* Proposed matches: one row per match, bank side | GL side | result (as in the UI card).
   Several lines on one side (1:M / M:1) are joined with ' | '. */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_matches AS
WITH b AS (
    SELECT match_id,
           MIN(txn_date) AS bank_date,
           STRING_AGG(NULLIF(description, ''), ' | ')                    AS bank_reference,
           STRING_AGG(NULLIF(tr_code, ''), ' | ')                        AS bank_tr_code,
           STRING_AGG(NULLIF(external_txn_type, ''), ' | ')              AS bank_txn_type,
           STRING_AGG(CONCAT(bank_statement_id, '/', line_number), ' | ') AS bank_statement_lines
    FROM dbo.bank_recon_match_line WHERE side = 'BANK' GROUP BY match_id
),
g AS (
    SELECT match_id,
           MIN(txn_date) AS gl_date,
           STRING_AGG(NULLIF(gl_alpha_name, ''), ' | ')                  AS gl_alpha_name,
           STRING_AGG(NULLIF(gl_remark, ''), ' | ')                      AS gl_remark,
           STRING_AGG(CONCAT(doc_type, ' ', doc_number), ' | ')          AS gl_documents,
           STRING_AGG(NULLIF(batch_number, ''), ' | ')                   AS gl_batches,
           MIN(account_number)                                           AS gl_account_number,
           MIN(business_unit)                                            AS gl_business_unit
    FROM dbo.bank_recon_match_line WHERE side = 'GL' GROUP BY match_id
)
SELECT p.match_id, p.run_id, p.gl_bank_account,
       COALESCE(a.display_name, a.gl_account_number, g.gl_account_number, p.gl_bank_account) AS display_name,
       p.status, p.confidence, p.match_type, p.match_rule, p.match_category, p.recon_state,
       CASE WHEN p.match_category = '1:1' THEN 'Direct' ELSE 'Potential (split payment)' END AS review_group,
       CASE WHEN p.status = 'EXCEPTION' OR (p.status = 'PENDING' AND p.confidence = 'MEDIUM')
            THEN 1 ELSE 0 END AS is_exception,
       -- bank side
       b.bank_date, p.bank_amount, b.bank_reference, b.bank_tr_code, b.bank_txn_type, b.bank_statement_lines,
       p.bank_line_count,
       -- GL side
       g.gl_date, p.gl_amount, g.gl_alpha_name, g.gl_remark, g.gl_documents, g.gl_batches,
       g.gl_account_number, g.gl_business_unit, p.gl_line_count,
       -- "why proposed" ticks shown in the result column
       CASE WHEN p.max_date_gap_days = 0 THEN 'Same date'
            ELSE CONCAT('Dates ', p.max_date_gap_days, ' day', CASE WHEN p.max_date_gap_days > 1 THEN 's' ELSE '' END, ' apart') END AS reason_date,
       'Exact amount' AS reason_amount,
       CASE p.confidence WHEN 'HIGH' THEN 'Unique candidate'
                         WHEN 'MEDIUM' THEN 'Several candidates'
                         ELSE CONCAT(p.bank_line_count + p.gl_line_count, ' lines combined') END AS reason_unique,
       CASE p.recon_state WHEN 'GL_R_BANK_OPEN' THEN 'G/L already reconciled in JDE'
                          WHEN 'BANK_R_GL_OPEN' THEN 'Bank line already reconciled in JDE'
                          ELSE NULL END AS reason_recon_state,
       p.note, p.decided_by, p.decided_at, p.decision_comment, p.export_batch_id, p.exported_at, p.created_at,
       -- one text column for the UI search box
       LOWER(CONCAT_WS(' ', b.bank_reference, g.gl_alpha_name, g.gl_remark, g.gl_documents,
                       CAST(p.bank_amount AS varchar(30)), b.bank_statement_lines)) AS search_text
FROM dbo.bank_recon_match_proposal p
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id
LEFT JOIN dbo.bank_recon_account a ON a.gl_bank_account = p.gl_bank_account
LEFT JOIN b ON b.match_id = p.match_id
LEFT JOIN g ON g.match_id = p.match_id;
GO

/* Match detail drawer: every line of a match (filter by match_id) */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_match_lines AS
SELECT l.*, p.status, p.confidence, p.match_rule, p.recon_state
FROM dbo.bank_recon_match_line l
JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
JOIN dbo.vw_bank_recon_completed_runs r ON r.run_id = p.run_id;
GO

/* Exception queue: one row per open exception */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_exceptions AS
SELECT m.match_id, m.gl_bank_account, m.display_name,
       CASE WHEN m.status = 'EXCEPTION' THEN 'Flagged by reviewer' ELSE 'Multiple candidates' END AS exception_label,
       m.status, m.match_rule, m.bank_date, m.bank_amount, m.bank_reference, m.bank_statement_lines,
       m.gl_date, m.gl_documents, m.gl_alpha_name, m.note,
       (SELECT COUNT(*) FROM dbo.bank_recon_match_candidate c WHERE c.match_id = m.match_id) AS candidate_count
FROM dbo.vw_bank_recon_ui_matches m
WHERE m.is_exception = 1;
GO

/* Exception resolution: the candidate lines of one exception (filter by match_id) */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_exception_candidates AS
SELECT c.*,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.bank_recon_match_line l
                         JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
                         WHERE l.line_id = c.line_id AND l.side = c.side AND l.match_id <> c.match_id
                           AND p.status IN ('PENDING', 'APPROVED', 'EXCEPTION'))
            THEN 1 ELSE 0 END AS used_in_other_match     -- cannot be selected while 1
FROM dbo.bank_recon_match_candidate c;
GO

/* Unmatched bank transactions (latest run) */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_unmatched_bank AS
SELECT u.gl_bank_account, u.line_id,
       u.txn_date AS post_date, u.amount, u.description AS reference, u.external_txn_type, u.tr_code,
       u.bank_statement_id, u.statement_date, u.line_number, u.bank_reference_1,
       u.reason, u.nearest_same_amount_gap_days,
       CASE WHEN d.line_id IS NULL THEN 'Unmatched' ELSE 'Confirmed unmatched' END AS status,
       d.decided_by, d.decided_at, d.comment
FROM dbo.vw_bank_recon_unmatched_latest u
LEFT JOIN dbo.bank_recon_line_decision d ON d.line_id = u.line_id AND d.side = u.side AND d.is_active = 1
WHERE u.side = 'BANK';
GO

/* Unmatched G/L transactions (latest run) */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_unmatched_gl AS
SELECT u.gl_bank_account, u.line_id,
       u.txn_date AS gl_date, u.amount, u.gl_alpha_name, u.gl_remark, u.description,
       u.doc_type, u.doc_number, u.doc_company, u.je_line_number, u.batch_number,
       u.account_number, u.business_unit,
       u.reason, u.nearest_same_amount_gap_days,
       CASE WHEN d.line_id IS NULL THEN 'Unmatched' ELSE 'Confirmed unmatched' END AS status,
       d.decided_by, d.decided_at, d.comment
FROM dbo.vw_bank_recon_unmatched_latest u
LEFT JOIN dbo.bank_recon_line_decision d ON d.line_id = u.line_id AND d.side = u.side AND d.is_active = 1
WHERE u.side = 'GL';
GO

/* Sign-off history per account */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_signoff AS
SELECT s.*, COALESCE(a.display_name, a.gl_account_number, s.gl_bank_account) AS display_name
FROM dbo.bank_recon_signoff s
LEFT JOIN dbo.bank_recon_account a ON a.gl_bank_account = s.gl_bank_account;
GO

/* Audit history per account: runs + decisions + unmatched confirmations + sign-offs */
CREATE OR ALTER VIEW dbo.vw_bank_recon_ui_audit AS
SELECT ra.gl_bank_account, r.finished_at AS event_at, r.triggered_by AS event_by, 'RUN' AS event_type,
       CONCAT('Matching run ', LOWER(r.status), ': ', ra.proposals, ' proposals, ',
              ra.bank_unmatched, ' bank and ', ra.gl_unmatched, ' G/L lines unmatched') AS event_text,
       NULL AS match_id
FROM dbo.bank_recon_run_log r
JOIN dbo.bank_recon_run_account ra ON ra.run_id = r.run_id
UNION ALL
SELECT COALESCE(al.gl_bank_account, p.gl_bank_account), al.action_at, al.action_by, al.action,
       CONCAT(al.action, CASE WHEN al.old_status IS NOT NULL THEN CONCAT(': ', al.old_status, ' -> ', al.new_status) ELSE '' END,
              CASE WHEN p.match_rule IS NOT NULL THEN CONCAT(' (', p.match_rule, ', ', p.bank_amount, ')') ELSE '' END,
              CASE WHEN al.comment IS NOT NULL THEN CONCAT(' - ', al.comment) ELSE '' END),
       al.match_id
FROM dbo.bank_recon_audit_log al
LEFT JOIN dbo.bank_recon_match_proposal p ON p.match_id = al.match_id;
GO

/* =====================================================================================
   PROCEDURES (buttons)
   ===================================================================================== */

/* "Match selected candidate": swap the line in an exception for the chosen candidate and approve it.
     EXEC dbo.usp_bank_recon_resolve_exception @match_id = '...', @line_id = 'G|RC|...', @user = 'jane@...'; */
CREATE OR ALTER PROCEDURE dbo.usp_bank_recon_resolve_exception
    @match_id varchar(36),
    @line_id  varchar(200),
    @user     varchar(200),
    @comment  varchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status varchar(20), @side varchar(4), @old_line varchar(200), @now datetime2(6) = SYSUTCDATETIME();

    IF NULLIF(LTRIM(RTRIM(@user)), '') IS NULL
        THROW 50002, '@user is required for the audit trail.', 1;
    SELECT @status = status FROM dbo.bank_recon_match_proposal WHERE match_id = @match_id;
    IF @status IS NULL
        THROW 50010, 'Unknown match.', 1;
    IF @status NOT IN ('PENDING', 'EXCEPTION')
        THROW 50011, 'Only pending or exception matches can be resolved.', 1;
    SELECT @side = side FROM dbo.bank_recon_match_candidate WHERE match_id = @match_id AND line_id = @line_id;
    IF @side IS NULL
        THROW 50012, 'The selected line is not a candidate of this match.', 1;
    IF EXISTS (SELECT 1 FROM dbo.bank_recon_match_line l
               JOIN dbo.bank_recon_match_proposal p ON p.match_id = l.match_id
               WHERE l.line_id = @line_id AND l.side = @side AND l.match_id <> @match_id
                 AND p.status IN ('PENDING', 'APPROVED', 'EXCEPTION'))
        THROW 50013, 'The selected line is already part of another open or approved match.', 1;
    SELECT TOP 1 @old_line = line_id FROM dbo.bank_recon_match_line WHERE match_id = @match_id AND side = @side;

    BEGIN TRANSACTION;
        IF @old_line <> @line_id
        BEGIN
            DELETE FROM dbo.bank_recon_match_line WHERE match_id = @match_id AND side = @side;
            INSERT INTO dbo.bank_recon_match_line
                (match_id, run_id, side, line_id, gl_bank_account, txn_date, amount, is_reconciled, description,
                 bank_statement_id, statement_date, line_number, tr_code,
                 doc_type, doc_number, doc_company, gl_date, je_line_number, ledger_type, line_ext_code,
                 external_txn_type, bank_reference_1, gl_alpha_name, gl_remark, batch_number, account_number, business_unit)
            SELECT match_id, run_id, side, line_id, gl_bank_account, txn_date, amount, is_reconciled, description,
                   bank_statement_id, statement_date, line_number, tr_code,
                   doc_type, doc_number, doc_company, gl_date, je_line_number, ledger_type, line_ext_code,
                   external_txn_type, bank_reference_1, gl_alpha_name, gl_remark, batch_number, account_number, business_unit
            FROM dbo.bank_recon_match_candidate
            WHERE match_id = @match_id AND line_id = @line_id;

            UPDATE dbo.bank_recon_match_candidate
            SET is_proposed = CASE WHEN line_id = @line_id THEN 1 ELSE 0 END
            WHERE match_id = @match_id AND side = @side;
        END;

        UPDATE p
        SET status = 'APPROVED', decided_by = @user, decided_at = @now,
            decision_comment = COALESCE(@comment, 'Candidate selected in exception resolution'),
            note = CASE WHEN @old_line <> @line_id THEN CONCAT('Pairing changed by reviewer (was ', @old_line, ')') ELSE p.note END,
            max_date_gap_days = x.gap,
            recon_state = CASE WHEN x.bank_r = 1 THEN 'BANK_R_GL_OPEN' WHEN x.gl_r = 1 THEN 'GL_R_BANK_OPEN' ELSE 'BOTH_OPEN' END
        FROM dbo.bank_recon_match_proposal p
        JOIN (SELECT match_id,
                     DATEDIFF(day, MIN(txn_date), MAX(txn_date)) AS gap,
                     MAX(CASE WHEN side = 'BANK' AND is_reconciled = 1 THEN 1 ELSE 0 END) AS bank_r,
                     MAX(CASE WHEN side = 'GL'   AND is_reconciled = 1 THEN 1 ELSE 0 END) AS gl_r
              FROM dbo.bank_recon_match_line WHERE match_id = @match_id GROUP BY match_id) x
             ON x.match_id = p.match_id;

        INSERT INTO dbo.bank_recon_audit_log
            (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment, gl_bank_account, line_id)
        SELECT CONVERT(varchar(36), NEWID()), @match_id, 'RESOLVE', @status, 'APPROVED', @user, @now,
               CONCAT('Selected ', @line_id, CASE WHEN @old_line <> @line_id THEN CONCAT(' instead of ', @old_line) ELSE '' END,
                      CASE WHEN @comment IS NOT NULL THEN CONCAT(' - ', @comment) ELSE '' END),
               gl_bank_account, @line_id
        FROM dbo.bank_recon_match_proposal WHERE match_id = @match_id;
    COMMIT TRANSACTION;
END;
GO

/* "Confirm as unmatched" / undo, for one or many lines of one side (comma list of line_ids).
     EXEC dbo.usp_bank_recon_confirm_unmatched @side = 'BANK', @line_ids = 'B|...,B|...', @action = 'CONFIRM', @user = 'jane@...'; */
CREATE OR ALTER PROCEDURE dbo.usp_bank_recon_confirm_unmatched
    @side     varchar(4),
    @line_ids varchar(max),
    @action   varchar(10),          -- CONFIRM or UNDO
    @user     varchar(200),
    @comment  varchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(6) = SYSUTCDATETIME();
    IF @side NOT IN ('BANK', 'GL')
        THROW 50020, '@side must be BANK or GL.', 1;
    IF UPPER(@action) NOT IN ('CONFIRM', 'UNDO')
        THROW 50021, '@action must be CONFIRM or UNDO.', 1;
    IF NULLIF(LTRIM(RTRIM(@user)), '') IS NULL
        THROW 50002, '@user is required for the audit trail.', 1;

    SELECT DISTINCT LTRIM(RTRIM(value)) AS line_id INTO #ids FROM STRING_SPLIT(@line_ids, ',');

    BEGIN TRANSACTION;
        IF UPPER(@action) = 'CONFIRM'
        BEGIN
            -- only lines that are unmatched in the latest run and not already confirmed
            SELECT u.line_id, u.gl_bank_account INTO #todo
            FROM dbo.vw_bank_recon_unmatched_latest u
            JOIN #ids i ON i.line_id = u.line_id
            WHERE u.side = @side
              AND NOT EXISTS (SELECT 1 FROM dbo.bank_recon_line_decision d
                              WHERE d.line_id = u.line_id AND d.side = @side AND d.is_active = 1);

            INSERT INTO dbo.bank_recon_line_decision
                (decision_id, side, line_id, gl_bank_account, decision, is_active, decided_by, decided_at, comment)
            SELECT CONVERT(varchar(36), NEWID()), @side, line_id, gl_bank_account, 'CONFIRMED_UNMATCHED', 1, @user, @now, @comment
            FROM #todo;

            INSERT INTO dbo.bank_recon_audit_log
                (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment, gl_bank_account, line_id)
            SELECT CONVERT(varchar(36), NEWID()), NULL, 'LEAVE_UNMATCHED', 'Unmatched', 'Confirmed unmatched', @user, @now,
                   CONCAT(@side, ' line ', line_id, CASE WHEN @comment IS NOT NULL THEN CONCAT(' - ', @comment) ELSE '' END),
                   gl_bank_account, line_id
            FROM #todo;

            -- tell the caller what happened (0 = no line found: wrong line_id, or not unmatched in the latest run)
            SELECT COUNT(*) AS lines_updated,
                   (SELECT COUNT(*) FROM #ids) - COUNT(*) AS lines_not_found_or_already_confirmed
            FROM #todo;
        END
        ELSE
        BEGIN
            SELECT d.line_id, d.gl_bank_account INTO #undo
            FROM dbo.bank_recon_line_decision d JOIN #ids i ON i.line_id = d.line_id
            WHERE d.side = @side AND d.is_active = 1;

            UPDATE d SET is_active = 0
            FROM dbo.bank_recon_line_decision d JOIN #undo u ON u.line_id = d.line_id
            WHERE d.side = @side AND d.is_active = 1;

            INSERT INTO dbo.bank_recon_audit_log
                (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment, gl_bank_account, line_id)
            SELECT CONVERT(varchar(36), NEWID()), NULL, 'UNDO_UNMATCHED', 'Confirmed unmatched', 'Unmatched', @user, @now,
                   CONCAT(@side, ' line ', line_id, CASE WHEN @comment IS NOT NULL THEN CONCAT(' - ', @comment) ELSE '' END),
                   gl_bank_account, line_id
            FROM #undo;

            SELECT COUNT(*) AS lines_updated,
                   (SELECT COUNT(*) FROM #ids) - COUNT(*) AS lines_not_found_or_not_confirmed
            FROM #undo;
        END;
    COMMIT TRANSACTION;
END;
GO

/* "Complete reconciliation": sign off one account for a period. Refused while anything is pending.
     EXEC dbo.usp_bank_recon_complete @gl_bank_account = '00498785', @period_end = '2026-08-31', @user = 'jane@...'; */
CREATE OR ALTER PROCEDURE dbo.usp_bank_recon_complete
    @gl_bank_account varchar(20),
    @period_end      date,
    @user            varchar(200),
    @comment         varchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(6) = SYSUTCDATETIME();
    DECLARE @pending int, @exceptions int, @proposed int, @confirmed int, @rejected int, @ub int, @ug int;

    IF NULLIF(LTRIM(RTRIM(@user)), '') IS NULL
        THROW 50002, '@user is required for the audit trail.', 1;
    SELECT @pending = pending_review, @exceptions = exceptions_open, @proposed = proposed_total,
           @confirmed = confirmed, @rejected = rejected, @ub = unmatched_bank, @ug = unmatched_gl
    FROM dbo.vw_bank_recon_ui_overview WHERE gl_bank_account = @gl_bank_account;
    IF @proposed IS NULL
        THROW 50030, 'Unknown or inactive account.', 1;
    IF @pending > 0 OR @exceptions > 0
        THROW 50031, 'Cannot complete: proposals are still pending or exceptions are open.', 1;
    IF EXISTS (SELECT 1 FROM dbo.bank_recon_signoff WHERE gl_bank_account = @gl_bank_account AND period_end = @period_end)
        THROW 50032, 'This account is already signed off for this period.', 1;

    BEGIN TRANSACTION;
        INSERT INTO dbo.bank_recon_signoff
            (signoff_id, gl_bank_account, period_end, signed_by, signed_at, proposals, confirmed, rejected,
             unmatched_bank, unmatched_gl, comment)
        VALUES (CONVERT(varchar(36), NEWID()), @gl_bank_account, @period_end, @user, @now, @proposed, @confirmed,
                @rejected, @ub, @ug, @comment);

        INSERT INTO dbo.bank_recon_audit_log
            (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment, gl_bank_account, line_id)
        VALUES (CONVERT(varchar(36), NEWID()), NULL, 'SIGNOFF', NULL, CONVERT(varchar(10), @period_end, 23), @user, @now,
                CONCAT('Reconciliation completed for period ending ', CONVERT(varchar(10), @period_end, 23),
                       CASE WHEN @comment IS NOT NULL THEN CONCAT(' - ', @comment) ELSE '' END),
                @gl_bank_account, NULL);
    COMMIT TRANSACTION;
END;
GO

/* Account details from the client (name, bank account number, sidebar order, active flag).
   Only the parameters you pass are changed; NULL = keep the current value.
     EXEC dbo.usp_bank_recon_set_account @gl_bank_account = '00498785', @display_name = '<from client>',
          @bank_account_number = '<from client>', @sort_order = 1, @user = 'admin@...'; */
CREATE OR ALTER PROCEDURE dbo.usp_bank_recon_set_account
    @gl_bank_account     varchar(20),
    @display_name        varchar(100) = NULL,
    @bank_account_number varchar(30)  = NULL,
    @sort_order          int          = NULL,
    @is_active           bit          = NULL,
    @user                varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(6) = SYSUTCDATETIME();
    IF NULLIF(LTRIM(RTRIM(@user)), '') IS NULL
        THROW 50002, '@user is required for the audit trail.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_bank_recon_ui_overview WHERE gl_bank_account = @gl_bank_account)
       AND NOT EXISTS (SELECT 1 FROM dbo.bank_recon_account WHERE gl_bank_account = @gl_bank_account)
        THROW 50040, 'Unknown account - it does not appear in any matching result.', 1;

    -- account table is optional: create the row the first time details are entered
    IF NOT EXISTS (SELECT 1 FROM dbo.bank_recon_account WHERE gl_bank_account = @gl_bank_account)
        INSERT INTO dbo.bank_recon_account
            (gl_bank_account, gl_account_number, display_name, bank_account_number, sort_order,
             is_active, first_seen_run_id, first_seen_at, updated_by, updated_at)
        SELECT @gl_bank_account, gl_account_number, NULL, NULL, NULL, 1, NULL, @now, @user, @now
        FROM dbo.vw_bank_recon_ui_overview WHERE gl_bank_account = @gl_bank_account;

    DECLARE @old varchar(200) = (SELECT CONCAT(display_name, ' | ', bank_account_number, ' | ', sort_order, ' | ', CAST(is_active AS varchar(1)))
                                 FROM dbo.bank_recon_account WHERE gl_bank_account = @gl_bank_account);
    BEGIN TRANSACTION;
        UPDATE dbo.bank_recon_account
        SET display_name        = COALESCE(@display_name, display_name),
            bank_account_number = COALESCE(@bank_account_number, bank_account_number),
            sort_order          = COALESCE(@sort_order, sort_order),
            is_active           = COALESCE(@is_active, is_active),
            updated_by = @user, updated_at = @now
        WHERE gl_bank_account = @gl_bank_account;

        INSERT INTO dbo.bank_recon_audit_log
            (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment, gl_bank_account, line_id)
        SELECT CONVERT(varchar(36), NEWID()), NULL, 'ACCOUNT', @old,
               CONCAT(display_name, ' | ', bank_account_number, ' | ', sort_order, ' | ', CAST(is_active AS varchar(1))),
               @user, @now, 'Account details changed', @gl_bank_account, NULL
        FROM dbo.bank_recon_account WHERE gl_bank_account = @gl_bank_account;
    COMMIT TRANSACTION;
END;
GO
