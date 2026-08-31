# Netflix Relational Database

A full relational database design and implementation of a Netflix-style streaming platform, built for **CS 727 — Relational Database Implementation and Applications**.

Everything here is real and runnable: a 13-table PostgreSQL schema, ~1,225 rows of reproducible mock data, 26 indexes, 5 views, a temp-table ETL pipeline, 4 functions, 3 stored procedures, and 5 triggers — each with its actual SQL and captured output.

**[Live dashboard →](#)** *(paste your published dashboard link here)*

## What's in here

| Folder | Contents |
|---|---|
| `docs/` | Design document (.docx), implementation report (.docx), ERD (draw.io + PNG), UML class diagram (draw.io) |
| `sql/` | All DDL, indexes, views, temp-table pipeline, functions, triggers, and procedures, in build order |
| `data/` | `generate_data.py` — Faker-based mock data generator (seed 42, fully reproducible) |
| `output/` | Captured terminal output for every step — DDL creation, data load counts, EXPLAIN ANALYZE before/after, view samples, trigger/procedure test runs |
| `dashboard/` | `netflix_dashboard.html` — a self-contained visual dashboard summarizing the schema, catalog, engagement, and subscriber data |
| `netflix_db_full_dump.sql` | Full `pg_dump` of the populated database |

## Schema

13 tables: `Plan`, `Account`, `Profile`, `Title`, `Season`, `Episode`, `Genre`, `Person`, `TitleGenre`, `Credit`, `WatchHistory`, `MyList`, `Rating`.

See `docs/netflix_erd.png` for the entity-relationship diagram, or open `docs/Netflix_ERD.drawio` / `docs/Netflix_UML.drawio` directly in [draw.io](https://app.diagrams.net) to explore or edit.

## Running it locally

Requires PostgreSQL 13+ and Python 3 with `psycopg2-binary` and `faker` installed.

```bash
createdb netflix_db
psql -d netflix_db -f sql/01_ddl.sql
python3 data/generate_data.py
psql -d netflix_db -f sql/02_indexes.sql
psql -d netflix_db -f sql/03_views.sql
psql -d netflix_db -f sql/04_temp_table.sql
psql -d netflix_db -f sql/05_functions.sql
psql -d netflix_db -f sql/06_triggers.sql
psql -d netflix_db -f sql/07_procedures.sql
```

Or restore everything in one shot from the dump:

```bash
createdb netflix_db
psql -d netflix_db -f netflix_db_full_dump.sql
```

## Notable engineering findings

Two real bugs were caught and documented during testing rather than quietly fixed:

- **SQL fan-out in the temp-table pipeline** — joining `WatchHistory`, `MyList`, and `Rating` directly on `TitleID` before aggregating multiplied row counts across tables. Fixed by pre-aggregating each relation in its own CTE before joining.
- **Trigger firing order** — PostgreSQL fires same-event `BEFORE INSERT` triggers alphabetically by name, which meant `trg_EnforceKidsMaturity` intercepted a test meant to isolate `trg_WatchHistoryEpisodeConsistency`. Re-run with an Adults profile to isolate the intended trigger.




