/* =====================================================================================
   Bank Reconciliation - CLIENT warehouse tables (schema dbo, prefix bank_recon_)
   Run in the warehouse SQL editor (Step 8).

   SAFE TO RE-RUN: each table is created only if it does not exist yet - nothing is dropped.
   Fabric Warehouse: no DEFAULT / IDENTITY - the notebook and the procedures fill every value.
   ===================================================================================== */

/* ---------- Settings (change with dbo.usp_bank_recon_set_config) ---------- */
IF OBJECT_ID('dbo.bank_recon_config') IS NULL
BEGIN
    CREATE TABLE dbo.bank_recon_config (
        param_name   varchar(100)  NOT NULL,
        param_value  varchar(200)  NOT NULL,
        description  varchar(500)  NULL,
        updated_by   varchar(200)  NULL,
        updated_at   datetime2(6)  NULL
    );
    ALTER TABLE dbo.bank_recon_config ADD CONSTRAINT pk_bank_recon_config
        PRIMARY KEY NONCLUSTERED (param_name) NOT ENFORCED;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.bank_recon_config)
INSERT INTO dbo.bank_recon_config (param_name, param_value, description, updated_by, updated_at) VALUES
 ('max_tolerance_days',          '5',     '1:1 date window widens from 0 (exact) up to this many days (0-5)', 'setup', SYSUTCDATETIME()),
 ('aggregate_tolerance_days',    '5',     'Date window for 1:M / M:1 split payments (also widened step by step)', 'setup', SYSUTCDATETIME()),
 ('aggregate_max_lines',         '5',     'Max number of lines combined in one 1:M / M:1 sum', 'setup', SYSUTCDATETIME()),
 ('aggregate_max_candidates',    '25',    'Max candidate lines considered per anchor line in the sum search', 'setup', SYSUTCDATETIME()),
 ('aggregate_min_part_share',    '0.01',  'Each line in a 1:M / M:1 sum must be at least this share of the anchor amount', 'setup', SYSUTCDATETIME()),
 ('aggregate_search_node_limit', '50000', 'Search budget per anchor line (performance guard)', 'setup', SYSUTCDATETIME()),
 ('enable_one_to_many',          '1',     '1 = run 1:M matching', 'setup', SYSUTCDATETIME()),
 ('enable_many_to_one',          '1',     '1 = run M:1 matching', 'setup', SYSUTCDATETIME());
GO

/* ---------- One row per notebook run - written LAST = commit marker ---------- */
IF OBJECT_ID('dbo.bank_recon_run_log') IS NULL
BEGIN
    CREATE TABLE dbo.bank_recon_run_log (
        run_id                   varchar(36)   NOT NULL,
        triggered_by             varchar(200)  NULL,
        bank_accounts            varchar(500)  NULL,
        date_from                date          NULL,
        date_to                  date          NULL,
        status                   varchar(20)   NOT NULL,   -- COMPLETED / FAILED
        started_at               datetime2(6)  NOT NULL,
        finished_at              datetime2(6)  NULL,
        bank_total               int           NULL,
        gl_total                 int           NULL,
        bank_reconciled_skipped  int           NULL,
        gl_reconciled_skipped    int           NULL,
        bank_locked_skipped      int           NULL,
        gl_locked_skipped        int           NULL,
        bank_in_scope            int           NULL,       -- open bank lines considered
        gl_in_scope              int           NULL,       -- open GL lines considered
        proposals                int           NULL,
        bank_matched             int           NULL,
        gl_matched               int           NULL,
        bank_unmatched           int           NULL,
        gl_unmatched             int           NULL,
        config_json              varchar(4000) NULL,
        error_message            varchar(4000) NULL
    );
    ALTER TABLE dbo.bank_recon_run_log ADD CONSTRAINT pk_bank_recon_run_log
        PRIMARY KEY NONCLUSTERED (run_id) NOT ENFORCED;
END;
GO

/* ---------- One row per proposed match (1:1, 1:M, M:1) ---------- */
IF OBJECT_ID('dbo.bank_recon_match_proposal') IS NULL
BEGIN
    CREATE TABLE dbo.bank_recon_match_proposal (
        match_id            varchar(36)   NOT NULL,
        run_id              varchar(36)   NOT NULL,
        match_type          varchar(20)   NOT NULL,  -- EXACT, TOLERANCE_T1..T5, ONE_TO_MANY, MANY_TO_ONE
        match_rule          varchar(200)  NOT NULL,  -- why it matched, numbered as in the SOW
        match_category      varchar(5)    NOT NULL,  -- 1:1, 1:M, M:1
        confidence          varchar(10)   NOT NULL,  -- HIGH, MEDIUM, POTENTIAL
        recon_state         varchar(20)   NOT NULL,  -- BOTH_OPEN, GL_R_BANK_OPEN, BANK_R_GL_OPEN
        tolerance_days      int           NOT NULL,
        max_date_gap_days   int           NOT NULL,
        gl_bank_account     varchar(20)   NOT NULL,
        bank_line_count     int           NOT NULL,
        gl_line_count       int           NOT NULL,
        bank_amount         decimal(18,2) NOT NULL,
        gl_amount           decimal(18,2) NOT NULL,
        group_signature     varchar(40)   NOT NULL,  -- rejected combinations are never proposed again
        note                varchar(500)  NULL,
        status              varchar(20)   NOT NULL,  -- PENDING, APPROVED, REJECTED, EXCEPTION
        decided_by          varchar(200)  NULL,
        decided_at          datetime2(6)  NULL,
        decision_comment    varchar(1000) NULL,
        export_batch_id     varchar(36)   NULL,
        exported_at         datetime2(6)  NULL,
        created_at          datetime2(6)  NOT NULL
    );
    ALTER TABLE dbo.bank_recon_match_proposal ADD CONSTRAINT pk_bank_recon_match_proposal
        PRIMARY KEY NONCLUSTERED (match_id) NOT ENFORCED;
END;
GO

/* ---------- Lines inside each match (full JDE primary keys) ---------- */
IF OBJECT_ID('dbo.bank_recon_match_line') IS NULL
CREATE TABLE dbo.bank_recon_match_line (
    match_id            varchar(36)   NOT NULL,
    run_id              varchar(36)   NOT NULL,
    side                varchar(4)    NOT NULL,  -- BANK / GL
    line_id             varchar(200)  NOT NULL,
    gl_bank_account     varchar(20)   NOT NULL,
    txn_date            date          NOT NULL,  -- bank cleared date / GL date
    amount              decimal(18,2) NOT NULL,  -- currency units (bank / 100), + in, - out
    is_reconciled       bit           NOT NULL,  -- line was already 'R' in JDE when matched
    description         varchar(500)  NULL,
    bank_statement_id   varchar(20)   NULL,      -- F09617 key (BANK rows)
    statement_date      date          NULL,
    line_number         varchar(10)   NULL,      -- raw value as stored (x100) - OPEN_ISSUES #2
    tr_code             varchar(4)    NULL,
    doc_type            varchar(4)    NULL,      -- F0911 key (GL rows)
    doc_number          varchar(20)   NULL,
    doc_company         varchar(10)   NULL,
    gl_date             date          NULL,
    je_line_number      varchar(10)   NULL,
    ledger_type         varchar(4)    NULL,
    line_ext_code       varchar(4)    NULL       -- empty today - OPEN_ISSUES #1
);
GO

/* ---------- Open lines without a match, per run ---------- */
IF OBJECT_ID('dbo.bank_recon_unmatched_line') IS NULL
CREATE TABLE dbo.bank_recon_unmatched_line (
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
GO

/* ---------- Audit trail: every decision, export and settings change ---------- */
IF OBJECT_ID('dbo.bank_recon_audit_log') IS NULL
BEGIN
    CREATE TABLE dbo.bank_recon_audit_log (
        audit_id    varchar(36)   NOT NULL,
        match_id    varchar(36)   NULL,
        action      varchar(20)   NOT NULL,  -- APPROVE, REJECT, EXCEPTION, REOPEN, EXPORT, CONFIG
        old_status  varchar(200)  NULL,
        new_status  varchar(200)  NULL,
        action_by   varchar(200)  NOT NULL,
        action_at   datetime2(6)  NOT NULL,
        comment     varchar(1000) NULL
    );
    ALTER TABLE dbo.bank_recon_audit_log ADD CONSTRAINT pk_bank_recon_audit_log
        PRIMARY KEY NONCLUSTERED (audit_id) NOT ENFORCED;
END;
GO
