/* =====================================================================================
   Migration: add recon.match_proposal.match_rule (why a proposal matched) and backfill it.
   Safe to re-run. A fresh install already has the column from 01_warehouse_schema.sql.
   The CASE below mirrors describe_rule() in src/recon_engine.py - keep them in sync.
   ===================================================================================== */

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('recon.match_proposal') AND name = 'match_rule')
    ALTER TABLE recon.match_proposal ADD match_rule varchar(200) NULL;
GO

UPDATE recon.match_proposal
SET match_rule =
    CASE
        WHEN match_type = 'EXACT'
            THEN 'Rule 2 - Exact match: same amount, same date'
        WHEN match_type LIKE 'TOLERANCE_T%'
            THEN CONCAT('Rule ', tolerance_days + 2, ' - Tolerance T+/-', tolerance_days,
                        ' (1:1): same amount, dates ', tolerance_days,
                        CASE WHEN tolerance_days > 1 THEN ' days' ELSE ' day' END, ' apart')
        WHEN match_type = 'ONE_TO_MANY'
            THEN CONCAT('Rule 8 - One-to-many (1:M, potential): 1 bank line = sum of ', gl_line_count,
                        ' GL lines, ',
                        CASE WHEN tolerance_days = 0 THEN 'same date'
                             ELSE CONCAT('within +/-', tolerance_days,
                                         CASE WHEN tolerance_days > 1 THEN ' days' ELSE ' day' END) END)
        WHEN match_type = 'MANY_TO_ONE'
            THEN CONCAT('Rule 9 - Many-to-one (M:1, potential): ', bank_line_count,
                        ' bank lines sum to 1 GL line, ',
                        CASE WHEN tolerance_days = 0 THEN 'same date'
                             ELSE CONCAT('within +/-', tolerance_days,
                                         CASE WHEN tolerance_days > 1 THEN ' days' ELSE ' day' END) END)
        ELSE match_type
    END
WHERE match_rule IS NULL;
GO
