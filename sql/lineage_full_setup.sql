/*
    DataStage lineage from preloaded table dbo.T_LNG_DS_JOB_OBJECT
    Version: 2.0
    Date: 2026-03-31
*/

SET NOCOUNT ON;
GO

/* ============================================================
   1) Служебные таблицы
   ============================================================ */
IF OBJECT_ID('dbo.T_LNG_DS_RUN_LOG', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.T_LNG_DS_RUN_LOG (
        RUN_ID           BIGINT IDENTITY(1,1) PRIMARY KEY,
        STARTED_AT_UTC   DATETIME2(0) NOT NULL CONSTRAINT DF_T_LNG_DS_RUN_LOG_STARTED DEFAULT (SYSUTCDATETIME()),
        FINISHED_AT_UTC  DATETIME2(0) NULL,
        STATUS           VARCHAR(20) NOT NULL,
        MESSAGE          VARCHAR(4000) NULL
    );
END;
GO

IF OBJECT_ID('dbo.T_LNG_DS_COLUMN_EDGE', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.T_LNG_DS_COLUMN_EDGE (
        RUN_ID              BIGINT NOT NULL,
        DSNAMESPACE         VARCHAR(255) NOT NULL,
        JOB_NAME            VARCHAR(512) NOT NULL,
        SRC_STAGE_NAME      VARCHAR(512) NOT NULL,
        SRC_COLUMN_NAME     VARCHAR(255) NOT NULL,
        DST_STAGE_NAME      VARCHAR(512) NOT NULL,
        DST_COLUMN_NAME     VARCHAR(255) NOT NULL,
        EDGE_RULE           VARCHAR(32) NOT NULL,      -- SOURCECOLUMNID / DERIVATION / SAME_NAME
        TARGET_ROW_ID       BIGINT NOT NULL,
        DERIVATION          VARCHAR(4000) NULL,
        SOURCECOLUMNID      VARCHAR(4000) NULL
    );

    CREATE INDEX IX_T_LNG_DS_COLUMN_EDGE_RUN_JOB_SRC ON dbo.T_LNG_DS_COLUMN_EDGE(RUN_ID, DSNAMESPACE, JOB_NAME, SRC_STAGE_NAME, SRC_COLUMN_NAME);
    CREATE INDEX IX_T_LNG_DS_COLUMN_EDGE_RUN_JOB_DST ON dbo.T_LNG_DS_COLUMN_EDGE(RUN_ID, DSNAMESPACE, JOB_NAME, DST_STAGE_NAME, DST_COLUMN_NAME);
END;
GO

IF OBJECT_ID('dbo.T_LNG_DS_LINEAGE_COMPRESSED', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.T_LNG_DS_LINEAGE_COMPRESSED (
        RUN_ID                 BIGINT NOT NULL,
        DSNAMESPACE            VARCHAR(255) NOT NULL,
        JOB_NAME               VARCHAR(512) NOT NULL,
        SOURCE_STAGE_NAME      VARCHAR(512) NOT NULL,
        SOURCE_COLUMN_NAME     VARCHAR(255) NOT NULL,
        TARGET_STAGE_NAME      VARCHAR(512) NOT NULL,
        TARGET_COLUMN_NAME     VARCHAR(255) NOT NULL,
        HOP_COUNT              INT NOT NULL,
        DEPENDENCY_TYPE        VARCHAR(16) NOT NULL,   -- DIRECT / DERIVED
        PATH_TEXT              VARCHAR(4000) NULL,
        CREATED_AT_UTC         DATETIME2(0) NOT NULL CONSTRAINT DF_T_LNG_DS_LINEAGE_COMPRESSED_CREATED DEFAULT (SYSUTCDATETIME())
    );

    CREATE INDEX IX_T_LNG_DS_LINEAGE_COMPRESSED_RUN_JOB ON dbo.T_LNG_DS_LINEAGE_COMPRESSED(RUN_ID, DSNAMESPACE, JOB_NAME);
    CREATE INDEX IX_T_LNG_DS_LINEAGE_COMPRESSED_SRC ON dbo.T_LNG_DS_LINEAGE_COMPRESSED(RUN_ID, SOURCE_STAGE_NAME, SOURCE_COLUMN_NAME);
    CREATE INDEX IX_T_LNG_DS_LINEAGE_COMPRESSED_DST ON dbo.T_LNG_DS_LINEAGE_COMPRESSED(RUN_ID, TARGET_STAGE_NAME, TARGET_COLUMN_NAME);
END;
GO

/* ============================================================
   2) Представление с последним успешным compressed lineage
   ============================================================ */
CREATE OR ALTER VIEW dbo.V_LNG_DS_LINEAGE_LATEST
AS
SELECT c.*
FROM dbo.T_LNG_DS_LINEAGE_COMPRESSED c
INNER JOIN (
    SELECT MAX(RUN_ID) AS RUN_ID
    FROM dbo.T_LNG_DS_RUN_LOG
    WHERE STATUS = 'DONE'
) x ON x.RUN_ID = c.RUN_ID;
GO

/* ============================================================
   3) Процедура расчета lineage
   Важно: источник уже загружен в dbo.T_LNG_DS_JOB_OBJECT
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.usp_lng_ds_build_lineage
    @project_list_csv VARCHAR(MAX) = NULL,  -- можно ограничить расчет проектами
    @job_name_like    VARCHAR(512) = NULL,  -- можно ограничить расчет конкретными job
    @max_depth        INT = 200
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_id BIGINT;
    INSERT INTO dbo.T_LNG_DS_RUN_LOG(STATUS, MESSAGE)
    VALUES ('RUNNING', 'Lineage build started');
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        IF OBJECT_ID('dbo.T_LNG_DS_JOB_OBJECT', 'U') IS NULL
            THROW 51000, 'Table dbo.T_LNG_DS_JOB_OBJECT was not found.', 1;

        IF @max_depth IS NULL OR @max_depth < 1
            SET @max_depth = 200;

        DELETE FROM dbo.T_LNG_DS_COLUMN_EDGE WHERE RUN_ID = @run_id;
        DELETE FROM dbo.T_LNG_DS_LINEAGE_COMPRESSED WHERE RUN_ID = @run_id;

        ;WITH src_data AS (
            SELECT
                o.ID,
                UPPER(LTRIM(RTRIM(o.DSNAMESPACE)))      AS DSNAMESPACE,
                UPPER(LTRIM(RTRIM(o.JOB_NAME)))         AS JOB_NAME,
                UPPER(LTRIM(RTRIM(o.STAGE_NAME)))       AS STAGE_NAME,
                UPPER(LTRIM(RTRIM(o.PREV_STAGE_NAME)))  AS PREV_STAGE_NAME,
                UPPER(LTRIM(RTRIM(o.NEXT_STAGE_NAME)))  AS NEXT_STAGE_NAME,
                UPPER(LTRIM(RTRIM(o.COLUMN_NAME)))      AS COLUMN_NAME,
                o.DERIVATION,
                o.SOURCECOLUMNID
            FROM dbo.T_LNG_DS_JOB_OBJECT o
            WHERE ISNULL(LTRIM(RTRIM(o.DSNAMESPACE)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.JOB_NAME)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.STAGE_NAME)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.COLUMN_NAME)), '') <> ''
              AND (
                    @project_list_csv IS NULL
                    OR UPPER(LTRIM(RTRIM(o.DSNAMESPACE))) IN (
                        SELECT UPPER(TRIM(value))
                        FROM STRING_SPLIT(@project_list_csv, ',')
                        WHERE TRIM(value) <> ''
                    )
                  )
              AND (
                    @job_name_like IS NULL
                    OR UPPER(LTRIM(RTRIM(o.JOB_NAME))) LIKE UPPER(@job_name_like)
                  )
        ),
        candidate_edge AS (
            SELECT
                t.ID AS target_row_id,
                t.DSNAMESPACE,
                t.JOB_NAME,
                s.STAGE_NAME AS src_stage_name,
                s.COLUMN_NAME AS src_column_name,
                t.STAGE_NAME AS dst_stage_name,
                t.COLUMN_NAME AS dst_column_name,
                t.DERIVATION,
                t.SOURCECOLUMNID,
                CASE
                    WHEN ISNULL(t.SOURCECOLUMNID, '') <> ''
                         AND CHARINDEX(s.COLUMN_NAME, UPPER(t.SOURCECOLUMNID)) > 0 THEN 1
                    WHEN ISNULL(t.DERIVATION, '') <> ''
                         AND CHARINDEX(s.COLUMN_NAME, UPPER(t.DERIVATION)) > 0 THEN 2
                    WHEN s.COLUMN_NAME = t.COLUMN_NAME THEN 3
                    ELSE 99
                END AS match_score,
                CASE
                    WHEN ISNULL(t.SOURCECOLUMNID, '') <> ''
                         AND CHARINDEX(s.COLUMN_NAME, UPPER(t.SOURCECOLUMNID)) > 0 THEN 'SOURCECOLUMNID'
                    WHEN ISNULL(t.DERIVATION, '') <> ''
                         AND CHARINDEX(s.COLUMN_NAME, UPPER(t.DERIVATION)) > 0 THEN 'DERIVATION'
                    WHEN s.COLUMN_NAME = t.COLUMN_NAME THEN 'SAME_NAME'
                    ELSE 'UNKNOWN'
                END AS edge_rule
            FROM src_data t
            INNER JOIN src_data s
                ON s.DSNAMESPACE = t.DSNAMESPACE
               AND s.JOB_NAME = t.JOB_NAME
               AND s.STAGE_NAME = t.PREV_STAGE_NAME
            WHERE ISNULL(t.PREV_STAGE_NAME, '') <> ''
        ),
        best_edge AS (
            SELECT *
            FROM (
                SELECT
                    c.*,
                    MIN(c.match_score) OVER (PARTITION BY c.target_row_id) AS min_score
                FROM candidate_edge c
                WHERE c.match_score < 99
            ) z
            WHERE z.match_score = z.min_score
        )
        INSERT INTO dbo.T_LNG_DS_COLUMN_EDGE
        (
            RUN_ID, DSNAMESPACE, JOB_NAME,
            SRC_STAGE_NAME, SRC_COLUMN_NAME,
            DST_STAGE_NAME, DST_COLUMN_NAME,
            EDGE_RULE, TARGET_ROW_ID,
            DERIVATION, SOURCECOLUMNID
        )
        SELECT DISTINCT
            @run_id,
            b.DSNAMESPACE,
            b.JOB_NAME,
            b.src_stage_name,
            b.src_column_name,
            b.dst_stage_name,
            b.dst_column_name,
            b.edge_rule,
            b.target_row_id,
            b.DERIVATION,
            b.SOURCECOLUMNID
        FROM best_edge b;

        ;WITH nodes AS (
            SELECT DISTINCT
                UPPER(LTRIM(RTRIM(o.DSNAMESPACE))) AS DSNAMESPACE,
                UPPER(LTRIM(RTRIM(o.JOB_NAME))) AS JOB_NAME,
                UPPER(LTRIM(RTRIM(o.STAGE_NAME))) AS STAGE_NAME,
                UPPER(LTRIM(RTRIM(o.COLUMN_NAME))) AS COLUMN_NAME,
                UPPER(LTRIM(RTRIM(o.PREV_STAGE_NAME))) AS PREV_STAGE_NAME,
                UPPER(LTRIM(RTRIM(o.NEXT_STAGE_NAME))) AS NEXT_STAGE_NAME
            FROM dbo.T_LNG_DS_JOB_OBJECT o
            WHERE ISNULL(LTRIM(RTRIM(o.DSNAMESPACE)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.JOB_NAME)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.STAGE_NAME)), '') <> ''
              AND ISNULL(LTRIM(RTRIM(o.COLUMN_NAME)), '') <> ''
              AND (
                    @project_list_csv IS NULL
                    OR UPPER(LTRIM(RTRIM(o.DSNAMESPACE))) IN (
                        SELECT UPPER(TRIM(value))
                        FROM STRING_SPLIT(@project_list_csv, ',')
                        WHERE TRIM(value) <> ''
                    )
                  )
              AND (
                    @job_name_like IS NULL
                    OR UPPER(LTRIM(RTRIM(o.JOB_NAME))) LIKE UPPER(@job_name_like)
                  )
        ),
        src_nodes AS (
            SELECT DSNAMESPACE, JOB_NAME, STAGE_NAME, COLUMN_NAME
            FROM nodes
            WHERE ISNULL(PREV_STAGE_NAME, '') = ''
        ),
        tgt_nodes AS (
            SELECT DSNAMESPACE, JOB_NAME, STAGE_NAME, COLUMN_NAME
            FROM nodes
            WHERE ISNULL(NEXT_STAGE_NAME, '') = ''
        ),
        walk AS (
            SELECT
                s.DSNAMESPACE,
                s.JOB_NAME,
                s.STAGE_NAME AS source_stage_name,
                s.COLUMN_NAME AS source_column_name,
                s.STAGE_NAME AS current_stage_name,
                s.COLUMN_NAME AS current_column_name,
                CAST(CONCAT('|', s.STAGE_NAME, ':', s.COLUMN_NAME, '|') AS VARCHAR(4000)) AS visit_path,
                CAST('' AS VARCHAR(4000)) AS path_text,
                0 AS hop_count,
                CAST(0 AS BIT) AS has_derived
            FROM src_nodes s

            UNION ALL

            SELECT
                w.DSNAMESPACE,
                w.JOB_NAME,
                w.source_stage_name,
                w.source_column_name,
                e.DST_STAGE_NAME AS current_stage_name,
                e.DST_COLUMN_NAME AS current_column_name,
                CAST(w.visit_path + e.DST_STAGE_NAME + ':' + e.DST_COLUMN_NAME + '|' AS VARCHAR(4000)) AS visit_path,
                CAST(
                    CASE WHEN w.path_text = ''
                         THEN CONCAT(e.SRC_STAGE_NAME, '.', e.SRC_COLUMN_NAME, '->', e.DST_STAGE_NAME, '.', e.DST_COLUMN_NAME, '[', e.EDGE_RULE, ']')
                         ELSE CONCAT(w.path_text, ';', e.SRC_STAGE_NAME, '.', e.SRC_COLUMN_NAME, '->', e.DST_STAGE_NAME, '.', e.DST_COLUMN_NAME, '[', e.EDGE_RULE, ']')
                    END AS VARCHAR(4000)
                ) AS path_text,
                w.hop_count + 1,
                CAST(CASE WHEN w.has_derived = 1 OR e.EDGE_RULE IN ('SOURCECOLUMNID','DERIVATION') THEN 1 ELSE 0 END AS BIT) AS has_derived
            FROM walk w
            INNER JOIN dbo.T_LNG_DS_COLUMN_EDGE e
                ON e.RUN_ID = @run_id
               AND e.DSNAMESPACE = w.DSNAMESPACE
               AND e.JOB_NAME = w.JOB_NAME
               AND e.SRC_STAGE_NAME = w.current_stage_name
               AND e.SRC_COLUMN_NAME = w.current_column_name
            WHERE w.hop_count < @max_depth
              AND CHARINDEX(CONCAT('|', e.DST_STAGE_NAME, ':', e.DST_COLUMN_NAME, '|'), w.visit_path) = 0
        ),
        resolved AS (
            SELECT
                w.DSNAMESPACE,
                w.JOB_NAME,
                w.source_stage_name,
                w.source_column_name,
                w.current_stage_name AS target_stage_name,
                w.current_column_name AS target_column_name,
                w.hop_count,
                w.path_text,
                w.has_derived
            FROM walk w
            INNER JOIN tgt_nodes t
                ON t.DSNAMESPACE = w.DSNAMESPACE
               AND t.JOB_NAME = w.JOB_NAME
               AND t.STAGE_NAME = w.current_stage_name
               AND t.COLUMN_NAME = w.current_column_name
            WHERE w.hop_count > 0
        ),
        compressed AS (
            SELECT
                r.DSNAMESPACE,
                r.JOB_NAME,
                r.source_stage_name,
                r.source_column_name,
                r.target_stage_name,
                r.target_column_name,
                MIN(r.hop_count) AS min_hop_count,
                MAX(CASE WHEN r.has_derived = 1 THEN 1 ELSE 0 END) AS has_derived
            FROM resolved r
            GROUP BY
                r.DSNAMESPACE,
                r.JOB_NAME,
                r.source_stage_name,
                r.source_column_name,
                r.target_stage_name,
                r.target_column_name
        )
        INSERT INTO dbo.T_LNG_DS_LINEAGE_COMPRESSED
        (
            RUN_ID, DSNAMESPACE, JOB_NAME,
            SOURCE_STAGE_NAME, SOURCE_COLUMN_NAME,
            TARGET_STAGE_NAME, TARGET_COLUMN_NAME,
            HOP_COUNT, DEPENDENCY_TYPE, PATH_TEXT
        )
        SELECT
            @run_id,
            c.DSNAMESPACE,
            c.JOB_NAME,
            c.source_stage_name,
            c.source_column_name,
            c.target_stage_name,
            c.target_column_name,
            c.min_hop_count,
            CASE WHEN c.has_derived = 1 THEN 'DERIVED' ELSE 'DIRECT' END,
            p.path_text
        FROM compressed c
        OUTER APPLY (
            SELECT TOP (1) r.path_text
            FROM resolved r
            WHERE r.DSNAMESPACE = c.DSNAMESPACE
              AND r.JOB_NAME = c.JOB_NAME
              AND r.source_stage_name = c.source_stage_name
              AND r.source_column_name = c.source_column_name
              AND r.target_stage_name = c.target_stage_name
              AND r.target_column_name = c.target_column_name
            ORDER BY r.hop_count ASC
        ) p
        OPTION (MAXRECURSION 32767);

        UPDATE dbo.T_LNG_DS_RUN_LOG
        SET STATUS = 'DONE',
            FINISHED_AT_UTC = SYSUTCDATETIME(),
            MESSAGE = CONCAT('Lineage build finished. RUN_ID=', @run_id,
                             '; EDGE_COUNT=', (SELECT COUNT(*) FROM dbo.T_LNG_DS_COLUMN_EDGE WHERE RUN_ID = @run_id),
                             '; COMPRESSED_COUNT=', (SELECT COUNT(*) FROM dbo.T_LNG_DS_LINEAGE_COMPRESSED WHERE RUN_ID = @run_id))
        WHERE RUN_ID = @run_id;

        SELECT @run_id AS RUN_ID,
               (SELECT COUNT(*) FROM dbo.T_LNG_DS_COLUMN_EDGE WHERE RUN_ID = @run_id) AS EDGE_COUNT,
               (SELECT COUNT(*) FROM dbo.T_LNG_DS_LINEAGE_COMPRESSED WHERE RUN_ID = @run_id) AS COMPRESSED_COUNT;
    END TRY
    BEGIN CATCH
        UPDATE dbo.T_LNG_DS_RUN_LOG
        SET STATUS = 'FAILED',
            FINISHED_AT_UTC = SYSUTCDATETIME(),
            MESSAGE = ERROR_MESSAGE()
        WHERE RUN_ID = @run_id;

        THROW;
    END CATCH;
END;
GO
