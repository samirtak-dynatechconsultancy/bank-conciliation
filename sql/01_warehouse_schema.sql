/* =====================================================================================
   Bank Reconciliation Agent - Fabric Warehouse objects
   Run once against the Warehouse (Fabric SQL editor / SSMS). Re-runnable: drops & recreates.
   NOTE: dropping tables deletes history. For an existing environment run only the views/procs
         (02_*.sql) after the first deployment.

   Fabric DW notes: no DEFAULT constraints / IDENTITY used - the notebook and the procs supply
   every value. varchar only (no nvarchar), datetime2(6).
   ===================================================================================== */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'recon')
    EXEC('CREATE SCHEMA recon');
GO

/* ---------- Configuration (parameter table: change behaviour without code changes) ---------- */
DROP TABLE IF EXISTS recon.config;
CREATE TABLE recon.config (
    param_name      varchar(100)  NOT NULL,
    param_value     varchar(200)  NOT NULL,
    description     varchar(500)  NULL,
    updated_by      varchar(200)  NULL,
    updated_at      datetime2(6)  NULL
);

INSERT INTO recon.config (param_name, param_value, description, updated_by, updated_at) VALUES
 ('max_tolerance_days',          '5',     '1:1 date window widens from 0 (exact) up to this many days (1-5)', 'setup', SYSUTCDATETIME()),
 ('aggregate_tolerance_days',    '5',     'Date window for 1:M / M:1 aggregate matching (also widened step by step)', 'setup', SYSUTCDATETIME()),
 ('aggregate_max_lines',         '5',     'Max number of lines combined in one 1:M / M:1 group', 'setup', SYSUTCDATETIME()),
 ('aggregate_max_candidates',    '25',    'Max candidate lines considered per anchor line in aggregate search', 'setup', SYSUTCDATETIME()),
 ('aggregate_search_node_limit', '50000', 'Search budget per anchor line (performance guard)', 'setup', SYSUTCDATETIME()),
 ('enable_one_to_many',          '1',     '1 = run 1:M matching', 'setup', SYSUTCDATETIME()),
 ('enable_many_to_one',          '1',     '1 = run M:1 matching', 'setup', SYSUTCDATETIME());

/* ---------- One row per notebook run. Written LAST by the notebook = commit marker ---------- */
DROP TABLE IF EXISTS recon.run_log;
CREATE TABLE recon.run_log (
    run_id                   varchar(36)   NOT NULL,
    triggered_by             varchar(200)  NULL,
    bank_accounts            varchar(500)  NULL,     -- comma list, '' = all accounts
    date_from                date          NULL,
    date_to                  date          NULL,
    status                   varchar(20)   NOT NULL, -- COMPLETED / FAILED
    started_at               datetime2(6)  NOT NULL,
    finished_at              datetime2(6)  NULL,
    bank_total               int           NULL,
    gl_total                 int           NULL,
    bank_reconciled_skipped  int           NULL,
    gl_reconciled_skipped    int           NULL,
    bank_locked_skipped      int           NULL,
    gl_locked_skipped        int           NULL,
    bank_in_scope            int           NULL,
    gl_in_scope              int           NULL,
    proposals                int           NULL,
    bank_matched             int           NULL,
    gl_matched               int           NULL,
    bank_unmatched           int           NULL,
    gl_unmatched             int           NULL,
    config_json              varchar(4000) NULL,
    error_message            varchar(4000) NULL
);

/* ---------- Match proposals (one row per 1:1 / 1:M / M:1 group) ---------- */
DROP TABLE IF EXISTS recon.match_proposal;
CREATE TABLE recon.match_proposal (
    match_id            varchar(36)   NOT NULL,
    run_id              varchar(36)   NOT NULL,
    match_type          varchar(20)   NOT NULL,  -- EXACT, TOLERANCE_T1..T5, ONE_TO_MANY, MANY_TO_ONE
    match_category      varchar(5)    NOT NULL,  -- 1:1, 1:M, M:1
    confidence          varchar(10)   NOT NULL,  -- HIGH, MEDIUM (ambiguous 1:1), POTENTIAL (aggregates)
    tolerance_days      int           NOT NULL,  -- tier at which the match was found
    max_date_gap_days   int           NOT NULL,
    gl_bank_account     varchar(20)   NOT NULL,
    bank_line_count     int           NOT NULL,
    gl_line_count       int           NOT NULL,
    bank_amount         decimal(18,2) NOT NULL,
    gl_amount           decimal(18,2) NOT NULL,
    group_signature     varchar(40)   NOT NULL,  -- sha1 of the line set; rejected combos are not re-proposed
    note                varchar(500)  NULL,
    status              varchar(20)   NOT NULL,  -- PENDING, APPROVED, REJECTED, EXCEPTION
    decided_by          varchar(200)  NULL,
    decided_at          datetime2(6)  NULL,
    decision_comment    varchar(1000) NULL,
    export_batch_id     varchar(36)   NULL,
    exported_at         datetime2(6)  NULL,
    created_at          datetime2(6)  NOT NULL,
    match_rule          varchar(200)  NULL       -- why it matched, e.g. 'Rule 3 - Tolerance T+/-1 (1:1): ...'
);

/* ---------- Lines inside each proposal (carries full JDE composite keys) ---------- */
DROP TABLE IF EXISTS recon.match_line;
CREATE TABLE recon.match_line (
    match_id            varchar(36)   NOT NULL,
    run_id              varchar(36)   NOT NULL,
    side                varchar(4)    NOT NULL,  -- BANK / GL
    line_id             varchar(200)  NOT NULL,  -- engine key built from the JDE primary key
    gl_bank_account     varchar(20)   NOT NULL,
    txn_date            date          NOT NULL,  -- bank cleared date / GL date
    amount              decimal(18,2) NOT NULL,  -- standardised sign: + money in, - money out
    description         varchar(500)  NULL,
    -- F09617 key (BANK side)
    bank_statement_id   varchar(20)   NULL,
    statement_date      date          NULL,
    line_number         varchar(10)   NULL,
    tr_code             varchar(4)    NULL,
    -- F0911 key (GL side)
    doc_type            varchar(4)    NULL,
    doc_number          varchar(20)   NULL,
    doc_company         varchar(10)   NULL,
    gl_date             date          NULL,
    je_line_number      varchar(10)   NULL,
    ledger_type         varchar(4)    NULL,
    line_ext_code       varchar(4)    NULL
);

/* ---------- Unmatched lines snapshot per run ---------- */
DROP TABLE IF EXISTS recon.unmatched_line;
CREATE TABLE recon.unmatched_line (
    run_id                        varchar(36)   NOT NULL,
    side                          varchar(4)    NOT NULL,
    line_id                       varchar(200)  NOT NULL,
    gl_bank_account               varchar(20)   NOT NULL,
    txn_date                      date          NOT NULL,
    amount                        decimal(18,2) NOT NULL,
    description                   varchar(500)  NULL,
    bank_statement_id             varchar(20)   NULL,
    statement_date                date          NULL,
    line_number                   varchar(10)   NULL,
    tr_code                       varchar(4)    NULL,
    doc_type                      varchar(4)    NULL,
    doc_number                    varchar(20)   NULL,
    doc_company                   varchar(10)   NULL,
    gl_date                       date          NULL,
    je_line_number                varchar(10)   NULL,
    ledger_type                   varchar(4)    NULL,
    line_ext_code                 varchar(4)    NULL,
    nearest_same_amount_gap_days  int           NULL,
    reason                        varchar(300)  NOT NULL
);

/* ---------- Audit trail of every user decision / export ---------- */
DROP TABLE IF EXISTS recon.audit_log;
CREATE TABLE recon.audit_log (
    audit_id        varchar(36)   NOT NULL,
    match_id        varchar(36)   NULL,
    action          varchar(20)   NOT NULL,  -- APPROVE, REJECT, EXCEPTION, REOPEN, EXPORT, CONFIG
    old_status      varchar(20)   NULL,
    new_status      varchar(20)   NULL,
    action_by       varchar(200)  NOT NULL,
    action_at       datetime2(6)  NOT NULL,
    comment         varchar(1000) NULL
);

/* Not-enforced keys: documentation + lets Power Apps treat the tables as editable sources */
ALTER TABLE recon.match_proposal ADD CONSTRAINT pk_match_proposal PRIMARY KEY NONCLUSTERED (match_id) NOT ENFORCED;
ALTER TABLE recon.run_log        ADD CONSTRAINT pk_run_log        PRIMARY KEY NONCLUSTERED (run_id)   NOT ENFORCED;
ALTER TABLE recon.audit_log      ADD CONSTRAINT pk_audit_log      PRIMARY KEY NONCLUSTERED (audit_id) NOT ENFORCED;
ALTER TABLE recon.config         ADD CONSTRAINT pk_config         PRIMARY KEY NONCLUSTERED (param_name) NOT ENFORCED;
GO
