/* =====================================================================================
   Bank Reconciliation Agent - views & stored procedures (safe to re-run any time)
   ===================================================================================== */

/* Only runs that finished are visible - a crashed run leaves no half-written proposals behind */
CREATE OR ALTER VIEW recon.vw_completed_runs AS
SELECT * FROM recon.run_log WHERE status = 'COMPLETED';
GO

/* Lines the notebook must NOT re-match: in an open/approved/exception proposal of a completed run.
   Once JDE reconciles them they disappear from the source anyway (Reconciliation Code / R ND = 'R'). */
CREATE OR ALTER VIEW recon.vw_locked_lines AS
SELECT DISTINCT l.line_id
FROM recon.match_line l
JOIN recon.match_proposal p ON p.match_id = l.match_id
JOIN recon.vw_completed_runs r ON r.run_id = p.run_id
WHERE p.status IN ('PENDING', 'APPROVED', 'EXCEPTION');
GO

/* Combinations a user rejected - the engine will not propose the exact same set again */
CREATE OR ALTER VIEW recon.vw_rejected_signatures AS
SELECT DISTINCT p.group_signature
FROM recon.match_proposal p
JOIN recon.vw_completed_runs r ON r.run_id = p.run_id
WHERE p.status = 'REJECTED';
GO

/* Review queue for Power Apps (header level) */
CREATE OR ALTER VIEW recon.vw_proposal_review AS
SELECT p.match_id, p.run_id, r.started_at AS run_started_at, r.triggered_by,
       p.match_type, p.match_rule, p.match_category, p.confidence, p.tolerance_days, p.max_date_gap_days,
       p.gl_bank_account, p.bank_line_count, p.gl_line_count, p.bank_amount, p.gl_amount,
       p.note, p.status, p.decided_by, p.decided_at, p.decision_comment,
       p.export_batch_id, p.exported_at, p.created_at,
       CASE WHEN p.match_category = '1:1' THEN 'Direct' ELSE 'Potential (split payment)' END AS review_group
FROM recon.match_proposal p
JOIN recon.vw_completed_runs r ON r.run_id = p.run_id;
GO

/* Review queue (line level) */
CREATE OR ALTER VIEW recon.vw_proposal_lines AS
SELECT l.*, p.status, p.match_type, p.match_rule, p.confidence
FROM recon.match_line l
JOIN recon.match_proposal p ON p.match_id = l.match_id
JOIN recon.vw_completed_runs r ON r.run_id = p.run_id;
GO

/* Unmatched bank / GL lines from the most recent completed run */
CREATE OR ALTER VIEW recon.vw_unmatched_latest AS
SELECT u.*
FROM recon.unmatched_line u
WHERE u.run_id = (SELECT TOP 1 run_id FROM recon.vw_completed_runs ORDER BY finished_at DESC);
GO

/* JDE output: one row per approved (bank line, GL line) link.
     F09617 Remark      <- GL Document Number
     F0911  Reference 3 <- '<Bank Statement ID>-<Line Number>'  (GLR3 is 8 chars)
   1:M gives one row per GL line under the same bank line; M:1 one row per bank line. */
CREATE OR ALTER VIEW recon.vw_jde_output AS
SELECT p.match_id, p.match_type, p.match_rule, p.match_category, p.confidence,
       -- F09617 primary key
       b.bank_statement_id, b.gl_bank_account, b.statement_date, b.line_number,
       b.txn_date            AS bank_cleared_date,
       b.amount              AS bank_amount,
       g.doc_number          AS bank_remark,
       -- F0911 primary key
       g.doc_type, g.doc_number, g.doc_company, g.gl_date, g.je_line_number, g.ledger_type, g.line_ext_code,
       g.amount              AS gl_amount,
       LEFT(CONCAT(b.bank_statement_id, '-', b.line_number), 8) AS gl_reference_3,
       p.decided_by          AS approved_by,
       p.decided_at          AS approved_at,
       p.export_batch_id, p.exported_at
FROM recon.match_proposal p
JOIN recon.match_line b ON b.match_id = p.match_id AND b.side = 'BANK'
JOIN recon.match_line g ON g.match_id = p.match_id AND g.side = 'GL'
WHERE p.status = 'APPROVED';
GO

/* -------------------------------------------------------------------------------------
   Approve / reject / exception / reopen one or many proposals (bulk approve = comma list)
     EXEC recon.usp_decide_match @match_ids = 'id1,id2', @action = 'APPROVE',
                                 @user = 'jane@tris.com', @comment = NULL;
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE recon.usp_decide_match
    @match_ids varchar(max),
    @action    varchar(20),
    @user      varchar(200),
    @comment   varchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @new_status varchar(20) =
        CASE UPPER(@action) WHEN 'APPROVE' THEN 'APPROVED' WHEN 'REJECT' THEN 'REJECTED'
                            WHEN 'EXCEPTION' THEN 'EXCEPTION' WHEN 'REOPEN' THEN 'PENDING' END;
    IF @new_status IS NULL
        THROW 50001, 'Action must be APPROVE, REJECT, EXCEPTION or REOPEN.', 1;
    IF NULLIF(LTRIM(RTRIM(@user)), '') IS NULL
        THROW 50002, '@user is required for the audit trail.', 1;

    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    -- Eligible rows: exported matches are frozen; REOPEN only from REJECTED/EXCEPTION/APPROVED(not exported)
    SELECT p.match_id, p.status AS old_status
    INTO #todo
    FROM recon.match_proposal p
    JOIN (SELECT DISTINCT LTRIM(RTRIM(value)) AS match_id FROM STRING_SPLIT(@match_ids, ',')) s
         ON s.match_id = p.match_id
    WHERE p.exported_at IS NULL
      AND p.status <> @new_status;

    BEGIN TRANSACTION;
        INSERT INTO recon.audit_log (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment)
        SELECT CONVERT(varchar(36), NEWID()), t.match_id, UPPER(@action), t.old_status, @new_status, @user, @now, @comment
        FROM #todo t;

        UPDATE p
        SET status = @new_status,
            decided_by = CASE WHEN @new_status = 'PENDING' THEN NULL ELSE @user END,
            decided_at = CASE WHEN @new_status = 'PENDING' THEN NULL ELSE @now END,
            decision_comment = @comment
        FROM recon.match_proposal p
        JOIN #todo t ON t.match_id = p.match_id;
    COMMIT TRANSACTION;

    SELECT COUNT(*) AS updated_count FROM #todo;
END;
GO

/* -------------------------------------------------------------------------------------
   Stamp all approved, not-yet-exported matches with a new export batch and return its id.
   Power Automate: EXEC proc -> SELECT * FROM recon.vw_jde_output WHERE export_batch_id = <id>
                   -> write CSV -> SFTP.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE recon.usp_create_export_batch
    @user varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @batch varchar(36) = CONVERT(varchar(36), NEWID());
    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    SELECT match_id INTO #todo
    FROM recon.match_proposal
    WHERE status = 'APPROVED' AND exported_at IS NULL;

    BEGIN TRANSACTION;
        UPDATE p SET export_batch_id = @batch, exported_at = @now
        FROM recon.match_proposal p JOIN #todo t ON t.match_id = p.match_id;

        INSERT INTO recon.audit_log (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment)
        SELECT CONVERT(varchar(36), NEWID()), match_id, 'EXPORT', 'APPROVED', 'APPROVED', @user, @now,
               CONCAT('Export batch ', @batch)
        FROM #todo;
    COMMIT TRANSACTION;

    SELECT @batch AS export_batch_id, COUNT(*) AS match_count FROM #todo;
END;
GO

/* Change a configuration parameter (audited) */
CREATE OR ALTER PROCEDURE recon.usp_set_config
    @param_name  varchar(100),
    @param_value varchar(200),
    @user        varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM recon.config WHERE param_name = @param_name)
        THROW 50003, 'Unknown parameter.', 1;
    IF @param_name IN ('max_tolerance_days', 'aggregate_tolerance_days')
       AND (TRY_CONVERT(int, @param_value) IS NULL OR TRY_CONVERT(int, @param_value) NOT BETWEEN 0 AND 5)
        THROW 50004, 'Date tolerance must be a whole number between 0 and 5.', 1;

    DECLARE @old varchar(200) = (SELECT param_value FROM recon.config WHERE param_name = @param_name);
    DECLARE @now datetime2(6) = SYSUTCDATETIME();

    BEGIN TRANSACTION;
        UPDATE recon.config SET param_value = @param_value, updated_by = @user, updated_at = @now
        WHERE param_name = @param_name;
        INSERT INTO recon.audit_log (audit_id, match_id, action, old_status, new_status, action_by, action_at, comment)
        VALUES (CONVERT(varchar(36), NEWID()), NULL, 'CONFIG', @old, @param_value, @user, @now, @param_name);
    COMMIT TRANSACTION;
END;
GO
