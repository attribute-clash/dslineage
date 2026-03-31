# RUNBOOK: Построение lineage DataStage Parallel Jobs в MS SQL Server

## 1. Предварительные требования

1. Доступ к MS SQL Server с правами на создание таблиц/процедур/представлений в `dbo`.
2. Настроенный Linked Server к DB2-репозиторию DataStage (пример имени: `DB2_DS_REPO`).
3. Учетная запись DB2 для Linked Server имеет права только на чтение метаданных.

## 2. Разовое развертывание

Выполните SQL-скрипт:

```sql
:r .\sql\lineage_full_setup.sql
```

Или откройте файл в SSMS и выполните целиком.

## 3. Первичная настройка источников DB2

1. Проверить шаблоны выгрузки:

```sql
SELECT *
FROM dbo.ctl_db2_extract_query
ORDER BY load_order;
```

2. Заменить плейсхолдеры (`xmeta.projects`, `xmeta.jobs` и т.д.) на реальные таблицы/представления вашего репозитория DB2.
3. Убедиться, что каждая `remote_sql` возвращает колонки в том же порядке, что и целевая таблица `dbo.raw_ds_*`.

## 4. Полный запуск пайплайна lineage

```sql
EXEC dbo.ctl_usp_run_full_lineage
     @linked_server = 'DB2_DS_REPO',
     @project_csv   = 'PROJECT_A,PROJECT_B',
     @max_depth     = 200;
```

Что делает оркестратор:
1. Обновляет фильтр проектов в `dbo.ctl_project_filter`.
2. Делает полную загрузку метаданных из DB2 в `dbo.raw_ds_*`.
3. Готовит граф зависимостей в `dbo.stg_ds_*`.
4. Вычисляет детальный lineage (`dbo.lineage_column_lineage_detailed`).
5. Вычисляет схлопнутый lineage (`dbo.lineage_column_lineage_collapsed`).
6. Публикует итог в `dbo.lineage_column_lineage_export`.

## 5. Где смотреть результаты

1. Последняя успешная выгрузка:

```sql
SELECT * FROM dbo.lineage_vw_latest_export;
```

2. Результаты конкретного запуска:

```sql
SELECT *
FROM dbo.lineage_column_lineage_export
WHERE run_id = <run_id>;
```

3. Статистика запусков и шагов:

```sql
SELECT * FROM dbo.lineage_vw_run_stats ORDER BY run_id DESC;
SELECT * FROM dbo.ctl_etl_run_step WHERE run_id = <run_id> ORDER BY run_step_id;
```

## 6. Важные замечания

- Реализован режим только **full load + full recompute**.
- Sequence jobs и Server jobs исключены из области расчета.
- Фильтр проектов обязателен (по именам проектов).
- Если у вас отличия синтаксиса DB2, корректируйте `remote_sql` в `dbo.ctl_db2_extract_query`.
- Все объекты созданы в одной схеме `dbo`, группировка сделана префиксами: `ctl_`, `raw_ds_`, `stg_ds_`, `lineage_`.
