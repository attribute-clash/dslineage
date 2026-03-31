# RUNBOOK: Построение сжатого lineage из `dbo.T_LNG_DS_JOB_OBJECT`

## 1. Что изменилось

В этом решении **нет загрузки из DataStage/DB2**. Предполагается, что исходные данные уже лежат в таблице:

- `dbo.T_LNG_DS_JOB_OBJECT`

Процедура строит граф колонок по `PREV_STAGE_NAME/NEXT_STAGE_NAME`, `DERIVATION`, `SOURCECOLUMNID`, а затем пишет **сжатые пути** в итоговую таблицу.

## 2. Ожидаемая структура входной таблицы

Источник:

- `dbo.T_LNG_DS_JOB_OBJECT`

Ключевые поля, используемые алгоритмом:
- `DSNAMESPACE` (проект)
- `JOB_NAME`
- `STAGE_NAME`
- `PREV_STAGE_NAME`
- `NEXT_STAGE_NAME`
- `COLUMN_NAME`
- `DERIVATION`
- `SOURCECOLUMNID`

## 3. Что создает скрипт `sql/lineage_full_setup.sql`

1. Лог запусков:
   - `dbo.T_LNG_DS_RUN_LOG`
2. Детальные ребра графа колонок:
   - `dbo.T_LNG_DS_COLUMN_EDGE`
3. Итоговый сжатый lineage:
   - `dbo.T_LNG_DS_LINEAGE_COMPRESSED`
4. View с последним успешным результатом:
   - `dbo.V_LNG_DS_LINEAGE_LATEST`
5. Основная процедура расчета:
   - `dbo.usp_lng_ds_build_lineage`

## 4. Развертывание

Выполните:

```sql
:r .\sql\lineage_full_setup.sql
```

или запустите содержимое файла в SSMS.

## 5. Запуск расчета lineage

### 5.1 Все проекты и все jobs

```sql
EXEC dbo.usp_lng_ds_build_lineage;
```

### 5.2 Только выбранные проекты

```sql
EXEC dbo.usp_lng_ds_build_lineage
     @project_list_csv = 'PROJECT_A,PROJECT_B';
```

### 5.3 Фильтр по имени job

```sql
EXEC dbo.usp_lng_ds_build_lineage
     @job_name_like = 'LOAD_%';
```

### 5.4 С фильтром проектов + job

```sql
EXEC dbo.usp_lng_ds_build_lineage
     @project_list_csv = 'PROJECT_A,PROJECT_B',
     @job_name_like    = 'FIN_%',
     @max_depth        = 300;
```

## 6. Где смотреть результат

### 6.1 Последний успешный запуск

```sql
SELECT *
FROM dbo.V_LNG_DS_LINEAGE_LATEST;
```

### 6.2 Результат по конкретному RUN_ID

```sql
SELECT *
FROM dbo.T_LNG_DS_LINEAGE_COMPRESSED
WHERE RUN_ID = <RUN_ID>
ORDER BY DSNAMESPACE, JOB_NAME, SOURCE_STAGE_NAME, SOURCE_COLUMN_NAME;
```

### 6.3 Лог запусков

```sql
SELECT *
FROM dbo.T_LNG_DS_RUN_LOG
ORDER BY RUN_ID DESC;
```

## 7. Как работает компрессия

1. Для каждой целевой колонки на stage ищутся входные колонки из `PREV_STAGE_NAME`.
2. Приоритет маппинга:
   1) `SOURCECOLUMNID` содержит имя входной колонки,
   2) `DERIVATION` содержит имя входной колонки,
   3) fallback: одинаковые имена колонок (`SAME_NAME`).
3. Строится граф зависимостей колонок.
4. Выполняется обход от входных stage-колонок (где `PREV_STAGE_NAME` пуст) до выходных (где `NEXT_STAGE_NAME` пуст).
5. В итог пишется одна строка на пару Source→Target с минимальным количеством шагов (сжатый путь).

## 8. Примечания

- Если в `DERIVATION/SOURCECOLUMNID` используются нестандартные форматы имен колонок, правила матчинга можно расширить в CTE `candidate_edge`.
- `PATH_TEXT` хранит один из кратчайших найденных путей для диагностики.
- Тип зависимости:
  - `DIRECT` — только проходные/одноименные связи,
  - `DERIVED` — по пути есть связь через `DERIVATION` или `SOURCECOLUMNID`.
