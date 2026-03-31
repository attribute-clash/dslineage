# RUNBOOK: Full DataStage Parallel Lineage in MS SQL Server

## 1. Prerequisites

1. MS SQL Server instance with rights to create schemas/tables/procedures.
2. Linked Server to DB2 repository is configured (example name: `DB2_DS_REPO`).
3. DB2 login used by Linked Server has **read-only** access to required repository objects.

## 2. One-time deployment

Run:

```sql
:r .\sql\lineage_full_setup.sql
```

Or execute the script content in SSMS.

## 3. Initial configuration

1. Verify/adjust SQL templates in `ctl.db2_extract_query`:

```sql
SELECT * FROM ctl.db2_extract_query ORDER BY load_order;
```

2. Replace placeholder DB2 object names (`xmeta.projects`, `xmeta.jobs`, etc.) with actual tables/views in your repository.
3. Make sure each `remote_sql` returns columns in exactly the same order as destination `raw_ds.*` table.

## 4. Full pipeline execution

```sql
EXEC ctl.usp_run_full_lineage
     @linked_server = 'DB2_DS_REPO',
     @project_csv   = 'PROJECT_A,PROJECT_B',
     @max_depth     = 200;
```

What happens automatically:
1. Project filter is refreshed.
2. Full reload from DB2 is executed for all configured entities.
3. Graph is prepared in `stg_ds`.
4. Detailed lineage is computed.
5. Collapsed lineage is computed.
6. Final export table is refreshed.

## 5. Where to read results

1. Latest export:

```sql
SELECT * FROM lineage.vw_latest_export;
```

2. All export rows for a run:

```sql
SELECT *
FROM lineage.column_lineage_export
WHERE run_id = <run_id>;
```

3. Run statistics:

```sql
SELECT * FROM lineage.vw_run_stats ORDER BY run_id DESC;
SELECT * FROM ctl.etl_run_step WHERE run_id = <run_id> ORDER BY run_step_id;
```

## 6. Operational notes

- Current implementation is **full load + full recompute** only.
- Sequence jobs and server jobs are out of scope.
- Project filtering is mandatory.
- If DB2 SQL dialect differs, adjust `remote_sql` in `ctl.db2_extract_query`.
