/*
    DataStage Parallel Jobs Lineage - Full MS SQL Server setup (dbo + prefixes)
    Version: 1.1
    Date: 2026-03-31
*/

SET NOCOUNT ON;
GO

/* ============================================================
   1) Control and logging tables (dbo + ctl_ prefix)
   ============================================================ */
IF OBJECT_ID('dbo.ctl_project_filter', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ctl_project_filter (
        project_name      NVARCHAR(256) NOT NULL PRIMARY KEY,
        is_active         BIT NOT NULL CONSTRAINT DF_ctl_project_filter_is_active DEFAULT (1),
        created_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_ctl_project_filter_created DEFAULT (SYSUTCDATETIME())
    );
END;
GO

IF OBJECT_ID('dbo.ctl_db2_extract_query', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ctl_db2_extract_query (
        entity_name       SYSNAME NOT NULL PRIMARY KEY,
        is_active         BIT NOT NULL CONSTRAINT DF_ctl_db2_extract_is_active DEFAULT (1),
        remote_sql        NVARCHAR(MAX) NOT NULL,
        load_order        INT NOT NULL,
        updated_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_ctl_db2_extract_updated DEFAULT (SYSUTCDATETIME())
    );
END;
GO

IF OBJECT_ID('dbo.ctl_etl_run', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ctl_etl_run (
        run_id            BIGINT IDENTITY(1,1) PRIMARY KEY,
        started_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_ctl_etl_run_started DEFAULT (SYSUTCDATETIME()),
        finished_at_utc   DATETIME2(0) NULL,
        status            NVARCHAR(20) NOT NULL,
        linked_server     SYSNAME NULL,
        project_csv       NVARCHAR(MAX) NULL,
        error_message     NVARCHAR(MAX) NULL
    );
END;
GO

IF OBJECT_ID('dbo.ctl_etl_run_step', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ctl_etl_run_step (
        run_step_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id            BIGINT NOT NULL,
        step_name         NVARCHAR(200) NOT NULL,
        started_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_ctl_etl_step_started DEFAULT (SYSUTCDATETIME()),
        finished_at_utc   DATETIME2(0) NULL,
        status            NVARCHAR(20) NOT NULL,
        rows_affected     BIGINT NULL,
        message           NVARCHAR(MAX) NULL,
        CONSTRAINT FK_ctl_etl_run_step_run FOREIGN KEY (run_id) REFERENCES dbo.ctl_etl_run(run_id)
    );
END;
GO

/* ============================================================
   2) RAW canonical metadata tables (dbo + raw_ds_ prefix)
   ============================================================ */
IF OBJECT_ID('dbo.raw_ds_projects', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_projects (
        project_id        BIGINT NOT NULL,
        project_name      NVARCHAR(256) NOT NULL,
        CONSTRAINT PK_raw_ds_projects PRIMARY KEY (project_id)
    );
END;
GO

IF OBJECT_ID('dbo.raw_ds_jobs', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_jobs (
        job_id            BIGINT NOT NULL,
        project_id        BIGINT NOT NULL,
        job_name          NVARCHAR(256) NOT NULL,
        job_type          NVARCHAR(64) NOT NULL,
        is_parallel       BIT NOT NULL,
        last_modified_utc DATETIME2(0) NULL,
        CONSTRAINT PK_raw_ds_jobs PRIMARY KEY (job_id),
        CONSTRAINT FK_raw_ds_jobs_project FOREIGN KEY (project_id) REFERENCES dbo.raw_ds_projects(project_id)
    );
END;
GO

IF OBJECT_ID('dbo.raw_ds_stages', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_stages (
        stage_id          BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        stage_name        NVARCHAR(256) NOT NULL,
        stage_type        NVARCHAR(128) NOT NULL,
        is_source         BIT NOT NULL,
        is_target         BIT NOT NULL,
        CONSTRAINT PK_raw_ds_stages PRIMARY KEY (stage_id),
        CONSTRAINT FK_raw_ds_stages_job FOREIGN KEY (job_id) REFERENCES dbo.raw_ds_jobs(job_id)
    );
END;
GO

IF OBJECT_ID('dbo.raw_ds_links', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_links (
        link_id           BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        link_name         NVARCHAR(256) NOT NULL,
        from_stage_id     BIGINT NOT NULL,
        to_stage_id       BIGINT NOT NULL,
        CONSTRAINT PK_raw_ds_links PRIMARY KEY (link_id),
        CONSTRAINT FK_raw_ds_links_job FOREIGN KEY (job_id) REFERENCES dbo.raw_ds_jobs(job_id),
        CONSTRAINT FK_raw_ds_links_from_stage FOREIGN KEY (from_stage_id) REFERENCES dbo.raw_ds_stages(stage_id),
        CONSTRAINT FK_raw_ds_links_to_stage FOREIGN KEY (to_stage_id) REFERENCES dbo.raw_ds_stages(stage_id)
    );
END;
GO

IF OBJECT_ID('dbo.raw_ds_stage_columns', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_stage_columns (
        column_id         BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        stage_id          BIGINT NOT NULL,
        link_id           BIGINT NULL,
        column_name       NVARCHAR(256) NOT NULL,
        io_type           NVARCHAR(10) NOT NULL,
        data_type         NVARCHAR(128) NULL,
        ordinal_position  INT NULL,
        CONSTRAINT PK_raw_ds_stage_columns PRIMARY KEY (column_id),
        CONSTRAINT FK_raw_ds_stage_columns_job FOREIGN KEY (job_id) REFERENCES dbo.raw_ds_jobs(job_id),
        CONSTRAINT FK_raw_ds_stage_columns_stage FOREIGN KEY (stage_id) REFERENCES dbo.raw_ds_stages(stage_id)
    );
END;
GO

IF OBJECT_ID('dbo.raw_ds_column_mapping', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.raw_ds_column_mapping (
        mapping_id        BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        stage_id          BIGINT NOT NULL,
        out_column_id     BIGINT NOT NULL,
        in_column_id      BIGINT NOT NULL,
        map_type          NVARCHAR(32) NOT NULL,
        expression_text   NVARCHAR(MAX) NULL,
        CONSTRAINT PK_raw_ds_column_mapping PRIMARY KEY (mapping_id),
        CONSTRAINT FK_raw_ds_colmap_job FOREIGN KEY (job_id) REFERENCES dbo.raw_ds_jobs(job_id)
    );
END;
GO

/* ============================================================
   3) Staging graph tables (dbo + stg_ds_ prefix)
   ============================================================ */
IF OBJECT_ID('dbo.stg_ds_column_node', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.stg_ds_column_node (
        node_id           BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id            BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        stage_id          BIGINT NOT NULL,
        column_id         BIGINT NOT NULL,
        qualified_name    NVARCHAR(800) NOT NULL,
        is_source_node    BIT NOT NULL,
        is_target_node    BIT NOT NULL
    );
    CREATE UNIQUE INDEX UX_stg_ds_column_node_run_column ON dbo.stg_ds_column_node(run_id, column_id);
END;
GO

IF OBJECT_ID('dbo.stg_ds_column_edge', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.stg_ds_column_edge (
        edge_id           BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id            BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        src_column_id     BIGINT NOT NULL,
        dst_column_id     BIGINT NOT NULL,
        edge_type         NVARCHAR(32) NOT NULL,
        expression_text   NVARCHAR(MAX) NULL
    );
    CREATE INDEX IX_stg_ds_column_edge_run_src ON dbo.stg_ds_column_edge(run_id, src_column_id);
    CREATE INDEX IX_stg_ds_column_edge_run_dst ON dbo.stg_ds_column_edge(run_id, dst_column_id);
END;
GO

/* ============================================================
   4) Output lineage tables (dbo + lineage_ prefix)
   ============================================================ */
IF OBJECT_ID('dbo.lineage_column_lineage_detailed', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.lineage_column_lineage_detailed (
        detailed_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id            BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        source_column_id  BIGINT NOT NULL,
        target_column_id  BIGINT NOT NULL,
        hop_count         INT NOT NULL,
        edge_path         NVARCHAR(MAX) NOT NULL,
        has_derived_step  BIT NOT NULL,
        created_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_lineage_detailed_created DEFAULT (SYSUTCDATETIME())
    );
    CREATE INDEX IX_lineage_detailed_run_job ON dbo.lineage_column_lineage_detailed(run_id, job_id);
    CREATE INDEX IX_lineage_detailed_run_source ON dbo.lineage_column_lineage_detailed(run_id, source_column_id);
    CREATE INDEX IX_lineage_detailed_run_target ON dbo.lineage_column_lineage_detailed(run_id, target_column_id);
END;
GO

IF OBJECT_ID('dbo.lineage_column_lineage_collapsed', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.lineage_column_lineage_collapsed (
        collapsed_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id            BIGINT NOT NULL,
        job_id            BIGINT NOT NULL,
        source_column_id  BIGINT NOT NULL,
        target_column_id  BIGINT NOT NULL,
        min_hop_count     INT NOT NULL,
        dependency_type   NVARCHAR(16) NOT NULL,
        created_at_utc    DATETIME2(0) NOT NULL CONSTRAINT DF_lineage_collapsed_created DEFAULT (SYSUTCDATETIME())
    );
    CREATE UNIQUE INDEX UX_lineage_collapsed_run_job_src_tgt ON dbo.lineage_column_lineage_collapsed(run_id, job_id, source_column_id, target_column_id);
END;
GO

IF OBJECT_ID('dbo.lineage_column_lineage_export', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.lineage_column_lineage_export (
        export_id             BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id                BIGINT NOT NULL,
        project_name          NVARCHAR(256) NOT NULL,
        job_name              NVARCHAR(256) NOT NULL,
        source_qualified_name NVARCHAR(800) NOT NULL,
        target_qualified_name NVARCHAR(800) NOT NULL,
        dependency_type       NVARCHAR(16) NOT NULL,
        min_hop_count         INT NOT NULL,
        created_at_utc        DATETIME2(0) NOT NULL CONSTRAINT DF_lineage_export_created DEFAULT (SYSUTCDATETIME())
    );
    CREATE INDEX IX_lineage_export_run ON dbo.lineage_column_lineage_export(run_id);
END;
GO

/* ============================================================
   5) Procedures
   ============================================================ */
CREATE OR ALTER PROCEDURE dbo.ctl_usp_seed_db2_extract_queries
AS
BEGIN
    SET NOCOUNT ON;

    MERGE dbo.ctl_db2_extract_query AS tgt
    USING (
        SELECT 'projects' AS entity_name, 10 AS load_order,
N'SELECT project_id, project_name
   FROM xmeta.projects
  WHERE project_name IN ({{PROJECT_FILTER}})' AS remote_sql
        UNION ALL
        SELECT 'jobs', 20,
N'SELECT job_id, project_id, job_name, job_type,
        CASE WHEN UPPER(job_type) = ''PARALLEL'' THEN 1 ELSE 0 END AS is_parallel,
        last_modified_utc
   FROM xmeta.jobs
  WHERE project_id IN (
        SELECT project_id
          FROM xmeta.projects
         WHERE project_name IN ({{PROJECT_FILTER}})
  )
    AND UPPER(job_type) = ''PARALLEL''' 
        UNION ALL
        SELECT 'stages', 30,
N'SELECT stage_id, job_id, stage_name, stage_type, is_source, is_target
   FROM xmeta.stages
  WHERE job_id IN (SELECT job_id FROM xmeta.jobs WHERE UPPER(job_type) = ''PARALLEL'')'
        UNION ALL
        SELECT 'links', 40,
N'SELECT link_id, job_id, link_name, from_stage_id, to_stage_id
   FROM xmeta.links
  WHERE job_id IN (SELECT job_id FROM xmeta.jobs WHERE UPPER(job_type) = ''PARALLEL'')'
        UNION ALL
        SELECT 'stage_columns', 50,
N'SELECT column_id, job_id, stage_id, link_id, column_name, io_type, data_type, ordinal_position
   FROM xmeta.stage_columns
  WHERE job_id IN (SELECT job_id FROM xmeta.jobs WHERE UPPER(job_type) = ''PARALLEL'')'
        UNION ALL
        SELECT 'column_mapping', 60,
N'SELECT mapping_id, job_id, stage_id, out_column_id, in_column_id, map_type, expression_text
   FROM xmeta.column_mapping
  WHERE job_id IN (SELECT job_id FROM xmeta.jobs WHERE UPPER(job_type) = ''PARALLEL'')'
    ) AS src
    ON tgt.entity_name = src.entity_name
    WHEN MATCHED THEN
      UPDATE SET tgt.remote_sql = src.remote_sql,
                 tgt.load_order = src.load_order,
                 tgt.is_active = 1,
                 tgt.updated_at_utc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
      INSERT (entity_name, is_active, remote_sql, load_order)
      VALUES (src.entity_name, 1, src.remote_sql, src.load_order);
END;
GO

CREATE OR ALTER PROCEDURE dbo.ctl_usp_set_project_filter
    @project_csv NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@project_csv)), '') IS NULL
        THROW 50001, N'Список проектов обязателен. Пример: ProjectA,ProjectB', 1;

    DELETE FROM dbo.ctl_project_filter;

    ;WITH x AS (
        SELECT TRIM(value) AS project_name
        FROM STRING_SPLIT(@project_csv, ',')
        WHERE TRIM(value) <> ''
    )
    INSERT INTO dbo.ctl_project_filter(project_name)
    SELECT DISTINCT project_name
    FROM x;

    IF NOT EXISTS (SELECT 1 FROM dbo.ctl_project_filter)
        THROW 50002, N'После разбора project_csv список проектов пуст.', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ctl_usp_full_load_from_db2
    @linked_server SYSNAME,
    @run_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @project_filter_sql NVARCHAR(MAX);
    SELECT @project_filter_sql = STRING_AGG(QUOTENAME(project_name, ''''), ',')
    FROM dbo.ctl_project_filter
    WHERE is_active = 1;

    IF NULLIF(@project_filter_sql, '') IS NULL
        THROW 50003, N'Нет активных проектов в dbo.ctl_project_filter.', 1;

    DECLARE @entity SYSNAME, @remote_sql NVARCHAR(MAX), @load_sql NVARCHAR(MAX), @rows BIGINT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT entity_name, REPLACE(remote_sql, '{{PROJECT_FILTER}}', @project_filter_sql)
        FROM dbo.ctl_db2_extract_query
        WHERE is_active = 1
        ORDER BY load_order, entity_name;

    OPEN cur;
    FETCH NEXT FROM cur INTO @entity, @remote_sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @target_table SYSNAME = CONCAT('raw_ds_', @entity);
        DECLARE @step_id BIGINT;

        INSERT INTO dbo.ctl_etl_run_step(run_id, step_name, status)
        VALUES (@run_id, CONCAT('load_', @entity), 'RUNNING');
        SET @step_id = SCOPE_IDENTITY();

        BEGIN TRY
            SET @load_sql = N'TRUNCATE TABLE dbo.' + QUOTENAME(@target_table) + N';';
            EXEC sp_executesql @load_sql;

            SET @load_sql = N'INSERT INTO dbo.' + QUOTENAME(@target_table) + N'
                             SELECT *
                             FROM OPENQUERY(' + QUOTENAME(@linked_server) + N', ''' + REPLACE(@remote_sql, '''', '''''') + N''');';
            EXEC sp_executesql @load_sql;

            SET @rows = @@ROWCOUNT;

            UPDATE dbo.ctl_etl_run_step
               SET finished_at_utc = SYSUTCDATETIME(),
                   status = 'DONE',
                   rows_affected = @rows
             WHERE run_step_id = @step_id;
        END TRY
        BEGIN CATCH
            UPDATE dbo.ctl_etl_run_step
               SET finished_at_utc = SYSUTCDATETIME(),
                   status = 'FAILED',
                   message = ERROR_MESSAGE()
             WHERE run_step_id = @step_id;
            THROW;
        END CATCH;

        FETCH NEXT FROM cur INTO @entity, @remote_sql;
    END

    CLOSE cur;
    DEALLOCATE cur;
END;
GO

CREATE OR ALTER PROCEDURE dbo.stg_ds_usp_prepare_graph
    @run_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.stg_ds_column_node WHERE run_id = @run_id;
    DELETE FROM dbo.stg_ds_column_edge WHERE run_id = @run_id;

    INSERT INTO dbo.stg_ds_column_node (run_id, job_id, stage_id, column_id, qualified_name, is_source_node, is_target_node)
    SELECT
        @run_id,
        c.job_id,
        c.stage_id,
        c.column_id,
        CONCAT(p.project_name, '.', j.job_name, '.', s.stage_name, '.', c.column_name) AS qualified_name,
        CASE WHEN s.is_source = 1 AND c.io_type = 'OUT' THEN 1 ELSE 0 END AS is_source_node,
        CASE WHEN s.is_target = 1 AND c.io_type = 'IN' THEN 1 ELSE 0 END AS is_target_node
    FROM dbo.raw_ds_stage_columns c
    INNER JOIN dbo.raw_ds_stages s ON s.stage_id = c.stage_id
    INNER JOIN dbo.raw_ds_jobs j ON j.job_id = c.job_id AND j.is_parallel = 1
    INNER JOIN dbo.raw_ds_projects p ON p.project_id = j.project_id
    INNER JOIN dbo.ctl_project_filter pf ON pf.project_name = p.project_name AND pf.is_active = 1;

    INSERT INTO dbo.stg_ds_column_edge (run_id, job_id, src_column_id, dst_column_id, edge_type, expression_text)
    SELECT
        @run_id,
        m.job_id,
        m.in_column_id,
        m.out_column_id,
        UPPER(m.map_type),
        m.expression_text
    FROM dbo.raw_ds_column_mapping m
    INNER JOIN dbo.raw_ds_jobs j ON j.job_id = m.job_id AND j.is_parallel = 1;

    INSERT INTO dbo.stg_ds_column_edge (run_id, job_id, src_column_id, dst_column_id, edge_type, expression_text)
    SELECT
        @run_id,
        l.job_id,
        src.column_id,
        dst.column_id,
        'PASS_THROUGH',
        NULL
    FROM dbo.raw_ds_links l
    INNER JOIN dbo.raw_ds_jobs j ON j.job_id = l.job_id AND j.is_parallel = 1
    INNER JOIN dbo.raw_ds_stage_columns src ON src.link_id = l.link_id AND src.io_type = 'OUT'
    INNER JOIN dbo.raw_ds_stage_columns dst ON dst.link_id = l.link_id AND dst.io_type = 'IN' AND dst.column_name = src.column_name
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.stg_ds_column_edge e
        WHERE e.run_id = @run_id
          AND e.job_id = l.job_id
          AND e.src_column_id = src.column_id
          AND e.dst_column_id = dst.column_id
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.lineage_usp_build_detailed_lineage
    @run_id BIGINT,
    @max_depth INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.lineage_column_lineage_detailed WHERE run_id = @run_id;

    ;WITH src AS (
        SELECT run_id, job_id, column_id AS source_column_id
        FROM dbo.stg_ds_column_node
        WHERE run_id = @run_id AND is_source_node = 1
    ),
    tgt AS (
        SELECT run_id, job_id, column_id AS target_column_id
        FROM dbo.stg_ds_column_node
        WHERE run_id = @run_id AND is_target_node = 1
    ),
    walk AS (
        SELECT
            s.run_id,
            s.job_id,
            s.source_column_id,
            s.source_column_id AS current_column_id,
            CAST(CONCAT('|', CAST(s.source_column_id AS NVARCHAR(30)), '|') AS NVARCHAR(MAX)) AS visit_path,
            CAST('' AS NVARCHAR(MAX)) AS edge_path,
            0 AS hop_count,
            CAST(0 AS BIT) AS has_derived_step
        FROM src s

        UNION ALL

        SELECT
            w.run_id,
            w.job_id,
            w.source_column_id,
            e.dst_column_id AS current_column_id,
            CAST(w.visit_path + CAST(e.dst_column_id AS NVARCHAR(30)) + '|' AS NVARCHAR(MAX)) AS visit_path,
            CAST(
                CASE WHEN w.edge_path = ''
                     THEN CONCAT(e.src_column_id, '->', e.dst_column_id, ':', e.edge_type)
                     ELSE CONCAT(w.edge_path, ';', e.src_column_id, '->', e.dst_column_id, ':', e.edge_type)
                END AS NVARCHAR(MAX)
            ) AS edge_path,
            w.hop_count + 1,
            CAST(CASE WHEN w.has_derived_step = 1 OR e.edge_type IN ('DERIVED','LOOKUP','JOIN') THEN 1 ELSE 0 END AS BIT) AS has_derived_step
        FROM walk w
        INNER JOIN dbo.stg_ds_column_edge e
            ON e.run_id = w.run_id
           AND e.job_id = w.job_id
           AND e.src_column_id = w.current_column_id
        WHERE w.hop_count < @max_depth
          AND CHARINDEX(CONCAT('|', CAST(e.dst_column_id AS NVARCHAR(30)), '|'), w.visit_path) = 0
    )
    INSERT INTO dbo.lineage_column_lineage_detailed (run_id, job_id, source_column_id, target_column_id, hop_count, edge_path, has_derived_step)
    SELECT
        w.run_id,
        w.job_id,
        w.source_column_id,
        t.target_column_id,
        w.hop_count,
        w.edge_path,
        w.has_derived_step
    FROM walk w
    INNER JOIN tgt t
        ON t.run_id = w.run_id
       AND t.job_id = w.job_id
       AND t.target_column_id = w.current_column_id
    WHERE w.hop_count > 0
    OPTION (MAXRECURSION 32767);
END;
GO

CREATE OR ALTER PROCEDURE dbo.lineage_usp_build_collapsed_lineage
    @run_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.lineage_column_lineage_collapsed WHERE run_id = @run_id;

    INSERT INTO dbo.lineage_column_lineage_collapsed (run_id, job_id, source_column_id, target_column_id, min_hop_count, dependency_type)
    SELECT
        d.run_id,
        d.job_id,
        d.source_column_id,
        d.target_column_id,
        MIN(d.hop_count) AS min_hop_count,
        CASE WHEN MAX(CASE WHEN d.has_derived_step = 1 THEN 1 ELSE 0 END) = 1
             THEN 'DERIVED'
             ELSE 'DIRECT'
        END AS dependency_type
    FROM dbo.lineage_column_lineage_detailed d
    WHERE d.run_id = @run_id
    GROUP BY d.run_id, d.job_id, d.source_column_id, d.target_column_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.lineage_usp_refresh_export
    @run_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.lineage_column_lineage_export WHERE run_id = @run_id;

    INSERT INTO dbo.lineage_column_lineage_export
    (
        run_id,
        project_name,
        job_name,
        source_qualified_name,
        target_qualified_name,
        dependency_type,
        min_hop_count
    )
    SELECT
        c.run_id,
        p.project_name,
        j.job_name,
        src.qualified_name,
        tgt.qualified_name,
        c.dependency_type,
        c.min_hop_count
    FROM dbo.lineage_column_lineage_collapsed c
    INNER JOIN dbo.stg_ds_column_node src ON src.run_id = c.run_id AND src.column_id = c.source_column_id
    INNER JOIN dbo.stg_ds_column_node tgt ON tgt.run_id = c.run_id AND tgt.column_id = c.target_column_id
    INNER JOIN dbo.raw_ds_jobs j ON j.job_id = c.job_id
    INNER JOIN dbo.raw_ds_projects p ON p.project_id = j.project_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ctl_usp_run_full_lineage
    @linked_server SYSNAME,
    @project_csv NVARCHAR(MAX),
    @max_depth INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_id BIGINT;
    INSERT INTO dbo.ctl_etl_run(status, linked_server, project_csv)
    VALUES ('RUNNING', @linked_server, @project_csv);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC dbo.ctl_usp_set_project_filter @project_csv = @project_csv;

        IF NOT EXISTS (SELECT 1 FROM dbo.ctl_db2_extract_query WHERE is_active = 1)
            EXEC dbo.ctl_usp_seed_db2_extract_queries;

        EXEC dbo.ctl_usp_full_load_from_db2 @linked_server = @linked_server, @run_id = @run_id;
        EXEC dbo.stg_ds_usp_prepare_graph @run_id = @run_id;
        EXEC dbo.lineage_usp_build_detailed_lineage @run_id = @run_id, @max_depth = @max_depth;
        EXEC dbo.lineage_usp_build_collapsed_lineage @run_id = @run_id;
        EXEC dbo.lineage_usp_refresh_export @run_id = @run_id;

        UPDATE dbo.ctl_etl_run
           SET status = 'DONE',
               finished_at_utc = SYSUTCDATETIME()
         WHERE run_id = @run_id;

        SELECT @run_id AS run_id, 'DONE' AS status;
    END TRY
    BEGIN CATCH
        UPDATE dbo.ctl_etl_run
           SET status = 'FAILED',
               finished_at_utc = SYSUTCDATETIME(),
               error_message = ERROR_MESSAGE()
         WHERE run_id = @run_id;
        THROW;
    END CATCH;
END;
GO

/* ============================================================
   6) Views (dbo + lineage_ prefix)
   ============================================================ */
CREATE OR ALTER VIEW dbo.lineage_vw_latest_export
AS
SELECT e.*
FROM dbo.lineage_column_lineage_export e
INNER JOIN (
    SELECT MAX(run_id) AS run_id
    FROM dbo.ctl_etl_run
    WHERE status = 'DONE'
) x ON x.run_id = e.run_id;
GO

CREATE OR ALTER VIEW dbo.lineage_vw_run_stats
AS
SELECT
    r.run_id,
    r.started_at_utc,
    r.finished_at_utc,
    r.status,
    DATEDIFF(SECOND, r.started_at_utc, r.finished_at_utc) AS duration_sec,
    (SELECT COUNT(*) FROM dbo.lineage_column_lineage_detailed d WHERE d.run_id = r.run_id) AS detailed_rows,
    (SELECT COUNT(*) FROM dbo.lineage_column_lineage_collapsed c WHERE c.run_id = r.run_id) AS collapsed_rows,
    (SELECT COUNT(*) FROM dbo.lineage_column_lineage_export e WHERE e.run_id = r.run_id) AS export_rows
FROM dbo.ctl_etl_run r;
GO
