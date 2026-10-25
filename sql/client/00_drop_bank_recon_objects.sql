/* =====================================================================================
   Bank Reconciliation - REMOVE all bank_recon objects from dbo (clean restart)

   !! DESTRUCTIVE: deletes the tables AND all their data (runs, proposals, decisions,
   !! audit log, sign-offs). Only for a fresh start before go-live.

   Step 1: run the PREVIEW query and check the list contains only bank_recon objects.
   Step 2: run the DROP part.
   Step 3: re-run 01_bank_recon_tables.sql, 02_bank_recon_views_procs.sql, 03_bank_recon_ui.sql.
   ===================================================================================== */

/* ---------- Step 1: PREVIEW - what will be removed ---------- */
SELECT s.name AS schema_name, o.name AS object_name, o.type_desc
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'dbo'
  AND (o.name LIKE 'bank[_]recon[_]%' OR o.name LIKE 'vw[_]bank[_]recon[_]%' OR o.name LIKE 'usp[_]bank[_]recon[_]%')
ORDER BY o.type_desc, o.name;

/* ---------- Step 2: DROP - procedures, then views (dependent ones first), then tables ---------- */
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_set_account;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_complete;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_confirm_unmatched;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_resolve_exception;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_set_config;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_create_export_batch;
DROP PROCEDURE IF EXISTS dbo.usp_bank_recon_decide_match;
GO

DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_audit;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_signoff;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_unmatched_gl;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_unmatched_bank;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_exception_candidates;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_exceptions;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_match_lines;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_matches;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_accounts;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_overview;
DROP VIEW IF EXISTS dbo.vw_bank_recon_ui_latest_run;
DROP VIEW IF EXISTS dbo.vw_bank_recon_jde_output;
DROP VIEW IF EXISTS dbo.vw_bank_recon_unmatched_latest;
DROP VIEW IF EXISTS dbo.vw_bank_recon_proposal_lines;
DROP VIEW IF EXISTS dbo.vw_bank_recon_proposal_review;
DROP VIEW IF EXISTS dbo.vw_bank_recon_rejected_signatures;
DROP VIEW IF EXISTS dbo.vw_bank_recon_locked_lines;
DROP VIEW IF EXISTS dbo.vw_bank_recon_completed_runs;
GO

DROP TABLE IF EXISTS dbo.bank_recon_signoff;
DROP TABLE IF EXISTS dbo.bank_recon_line_decision;
DROP TABLE IF EXISTS dbo.bank_recon_match_candidate;
DROP TABLE IF EXISTS dbo.bank_recon_run_account;
DROP TABLE IF EXISTS dbo.bank_recon_account;
DROP TABLE IF EXISTS dbo.bank_recon_audit_log;
DROP TABLE IF EXISTS dbo.bank_recon_unmatched_line;
DROP TABLE IF EXISTS dbo.bank_recon_match_line;
DROP TABLE IF EXISTS dbo.bank_recon_match_proposal;
DROP TABLE IF EXISTS dbo.bank_recon_run_log;
DROP TABLE IF EXISTS dbo.bank_recon_config;
GO

/* ---------- Check: must return 0 rows ---------- */
SELECT o.name, o.type_desc
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'dbo'
  AND (o.name LIKE 'bank[_]recon[_]%' OR o.name LIKE 'vw[_]bank[_]recon[_]%' OR o.name LIKE 'usp[_]bank[_]recon[_]%');
