---
name: openflow-retail-vhol
description: "Build the Retail AI-Ready Data Pipeline for the Openflow VHOL: Snowflake Managed Postgres -> Openflow Gen2 PostgreSQL CDC (SQL-configured connector) -> Bronze Iceberg -> Silver/Gold Dynamic Iceberg Tables with Cortex AI -> Semantic View -> Cortex Agent. Loads the exact object model, naming, and DDL so short prompts produce consistent objects. Use when: building any part of this lab. Triggers: openflow vhol, openflow dashboard, connector observability, openflow wizard, retail hol, candle retailer, RETAIL_HOL_PG, SPCS_SOM, POSTGRES_RUNTIME_SOM, POSTGRES_INGEST, postgres cdc, bronze iceberg, silver managed iceberg, gold managed iceberg, retail analyst agent, RETAIL_PRODUCT_INTELLIGENCE."
---

# Openflow Retail VHOL — Ingestion to Insight

You are helping a workshop attendee build an **AI-Ready Data Pipeline** on Snowflake
from **CoCo Desktop**, one prompt per part.

**The story:** a 12-SKU candle and fragrance brand (*Frosted Juniper*, *Vanilla
Cedarlight*, ...) sells online and through 4 regional store networks (NE, NW, SE, SW),
fulfilled from 5 warehouses (LA, Houston, NYC, Chicago, SF). Four personas can't agree
on a number:
- **Merchandiser** (daily): "What sold yesterday? Is anything running low?"
- **VP of Retail** (weekly): "How did we do? Where are we trending?"
- **CX Lead** (constantly): "What are customers saying about us right now?"
- **Supply Chain Planner**: "Which warehouse needs a truck today?"

The fix: one platform, one pipeline, one agent.
`Managed Postgres (OLTP) --CDC/Openflow--> Iceberg Bronze --> Dynamic Iceberg Silver/Gold --> Semantic View --> Cortex Agent`

**Golden rule:** produce objects with the EXACT names, columns and settings in the
Object Model and `references/object_model.md` (verbatim from the original notebooks).
Do not rename objects, change target lags, or "improve" DDL. Use `IF NOT EXISTS` /
`CREATE OR REPLACE` exactly as written so re-runs are safe. After each part, run its
Checkpoint and report the result in one or two lines, then tell the attendee the
"why it matters" line for that part.

**Execution order (strict):** run lab SQL **sequentially, one statement per tool call, in the order it appears in
the `solutions/` file**. Never batch statements into parallel tool calls (no `direct_tool_calling` with
`execution: parallel`, no simultaneous `sql_execute` calls): almost every step depends on the one before it
(role -> grants -> database -> schema -> table -> dynamic table), so parallel runs fail with "does not exist" /
"insufficient privileges". Wait for each statement to succeed before sending the next. Read-only checks
(SHOW / DESCRIBE / SELECT on finished objects) may be grouped only when nothing depends on them. If a statement
fails because an earlier one hadn't run, re-run the remaining statements in file order (all are safe to re-run).

## Fixed context

- Account: event-provided, region **varies**. SPCS, Openflow, Managed Postgres and
  Cortex AI are expected to be available. Run the **Preflight** before Act 1 and
  stop with a clear message if a feature is missing.
- CoCo Desktop connection: user `VHOLuser`, role `ACCOUNTADMIN` (from
  `solutions/00_bootstrap.sql`). Run all SQL through the active CoCo SQL connection.
  Do NOT use `snowflake_connections_list` or shell out to `snow`/`cortex` CLI for SQL:
  those may hit a different default connection.
- Roles: `ACCOUNTADMIN` for setup, `OPENFLOW_ADMIN` for deployment/runtime/connector,
  `RETAIL_HOL_ROLE` for Postgres, Silver/Gold, semantic view and agent. Every DDL block
  starts with the `USE ROLE` shown in `object_model.md`.
- The lab switches roles (`USE ROLE OPENFLOW_ADMIN` / `RETAIL_HOL_ROLE`), so the VHOLuser PAT must be created
  WITHOUT `ROLE_RESTRICTION`. A role-restricted PAT pins the session: `USE ROLE` fails with
  "Current session is restricted. USE ROLE not allowed.", secondary roles are ignored, and everything is
  owned by the restricted role. If you see that error, STOP — do not work around it by creating objects as
  ACCOUNTADMIN (ownership will be wrong, e.g. SPCS_SOM owned by ACCOUNTADMIN). Tell the attendee to, in
  Snowsight: `ALTER USER VHOLuser REMOVE PROGRAMMATIC ACCESS TOKEN vhol_pat;`, re-run bootstrap Block 1,
  then update `secret.pat` and the CoCo connection token. Not to be confused with "Restricted session scope"
  errors from CoCo guardrails (a different feature).
- Setup check prompt ("test the connection and confirm the skill is loaded"): run
  `SELECT CURRENT_ACCOUNT() AS account, CURRENT_USER() AS user, CURRENT_ROLE() AS role, CURRENT_REGION() AS region;`
  report values (expect `VHOLUSER`, `ACCOUNTADMIN`) and confirm `openflow-retail-vhol` is active (the attendee added it
  in README setup step 5; if somehow not, point them back to that step: Agent Settings -> Skills -> + -> Add Local Skill -> pick `<repo>/.snowflake/cortex/skills`, NOT the repo root, which fails
  with "No valid skills found").
  Also run `USE ROLE PUBLIC;` then `USE ROLE ACCOUNTADMIN;` to prove role switching works; if it fails with
  "USE ROLE not allowed", apply the PAT fix above before Act 1.

## Session errors (any act)
- **"Authentication token has expired"** (error 390114): the *session* token expired after a long or idle session;
  the PAT itself is still valid (7 days). Retry the same statement once — the connection re-authenticates. If it
  fails again, tell the attendee to reconnect: CoCo Desktop -> Connections -> select the VHOLuser connection again
  (or start a new chat). Only if the PAT itself expired (`PAT expired` / login fails) re-issue it with bootstrap Block 1.
  Never switch to a different connection to work around it.
- **"No active warehouse selected"**: run `USE WAREHOUSE RETAIL_HOL_WH;` and retry (`01_environment.sql` sets it as
  VHOLuser's default; older runs may not have it). For metadata checks prefer SHOW / DESCRIBE, which need no warehouse.

## Secrets handling (strict)

- The Postgres `snowflake_admin` password is returned ONCE by `CREATE POSTGRES INSTANCE`.
  **Never run that CREATE through the SQL tool** (the password would enter chat context).
  Always run `scripts/setup_postgres.py`, which writes it straight to `pg_creds.json`
  (gitignored, chmod 600), creates the secret, updates the egress rule, and prints only the
  host + `****<last 4>`.
- Never `cat`/read `pg_creds.json`, `secret.pat`, or `~/.snowflake/connections.toml` into chat.
- Helper-script auth: `--account <ORG-ACCOUNT>` (user `VHOLuser` + PAT from `secret.pat` in the
  repo root). Get the account with SQL on the active connection:
  `SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME();`
  If `secret.pat` is missing, ask the attendee to save their `vhol_pat` token into it first.
  (Presenters may use `--connection <name>` instead.)
- If `setup_postgres.py` says the instance exists but `pg_creds.json` is missing, the password
  is lost: tell the attendee, and with their confirmation drop `RETAIL_HOL_PG` and re-run.

## Object Model (single source of truth)

### Act 1 — Environment + Openflow deployment (`solutions/01_environment.sql`, `02_openflow_deployment.sql`)
| Object | Name |
|---|---|
| Data role | `RETAIL_HOL_ROLE` (granted to current user and SYSADMIN, plus `SNOWFLAKE.CORTEX_USER`) |
| Warehouse | `RETAIL_HOL_WH` XSMALL, AUTO_SUSPEND 60 |
| Admin DB | `RETAIL_HOL_ADMIN` with schemas `SECRETS`, `NETWORK` |
| Destination DB | `RETAIL_HOL_ICEBERG` with `CATALOG='SNOWFLAKE'`, `EXTERNAL_VOLUME='SNOWFLAKE_MANAGED'` |
| PG network rule / policy | `RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_INGRESS_RULE` (POSTGRES_INGRESS) / `RETAIL_HOL_NETWORK_POLICY` |
| Egress rule / EAI | `RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE` (HOST_PORT, placeholder `example.com:5432` until Act 2 — must be resolvable; never `*.invalid`) / `RETAIL_HOL_POSTGRES_EAI` |
| Openflow namespace | `OPENFLOW_DB.OPENFLOW_SCHEMA` |
| Roles | `OPENFLOW_ADMIN` (granted to current user and SYSADMIN), `POSTGRES_INGEST_SERVICE_ROLE` (execute-as role) |
| Deployment | `SPCS_SOM` (`DEPLOYMENT_TYPE='SNOWFLAKE'`), ~15 min to ACTIVE |
| Event table | `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`, attached to `SPCS_SOM` |

Order matters: run `01_environment.sql` THEN `02_openflow_deployment.sql` (the service
role grants reference `RETAIL_HOL_ICEBERG`, `RETAIL_HOL_ADMIN`, `RETAIL_HOL_WH`, the EAI).
Kick off the deployment and immediately continue to Act 2 — do not block on ACTIVE.

### Act 2 — Postgres source (`solutions/03_postgres_instance.sql`, `scripts/load_retail_data.py`)
- Instance `RETAIL_HOL_PG`: `COMPUTE_FAMILY='STANDARD_M'`, `STORAGE_SIZE_GB=10`,
  `AUTHENTICATION_AUTHORITY=POSTGRES`, `POSTGRES_VERSION=18`,
  `NETWORK_POLICY='RETAIL_HOL_NETWORK_POLICY'`. Created as `RETAIL_HOL_ROLE`.
- Wait for `state = READY` (poll `DESCRIBE POSTGRES INSTANCE` every ~30s).
- Secret `RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD` (`GENERIC_STRING`), READ to `RETAIL_HOL_ROLE`.
- `ALTER NETWORK RULE RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE SET VALUE_LIST = ('<host>:5432')`.
- Postgres `bronze` schema (loader creates it, with PostGIS) — 5 tables:
  `sales_transactions`, `product_reviews`, `inventory_feed` (JSONB `metadata`, PostGIS
  `warehouse_location`), `customer_comments`, `daily_reviews`. Data is deterministic
  (`random.seed(42)`), dates 2024-01-01 to 2025-02-17.
- Publication `openflow_retail_pub` on all 5 tables.
- **Detect the OS first**, then create the venv at the repo root and install deps:
  - macOS/Linux: `python3 -m venv .venv` -> `.venv/bin/pip install -r scripts/requirements.txt`; interpreter `.venv/bin/python`
  - Windows: `python -m venv .venv` -> `.venv\Scripts\pip.exe install -r scripts\requirements.txt`; interpreter `.venv\Scripts\python.exe` (no `uv`, no POSIX paths)
- Instance + secret + egress: `<venv-python> scripts/setup_postgres.py --account <ORG-ACCOUNT>` (~5 min; polls to READY).
- Data + publication: `<venv-python> scripts/load_retail_data.py` (reads `pg_creds.json`).
  Do not modify the loader's data logic.

### Act 3 — Runtime + CDC connector (`solutions/04_runtime_connector.sql`, `references/connector_config.md`)
- Prereq: `SHOW OPENFLOW DEPLOYMENTS` shows `SPCS_SOM` ACTIVE. If not, report the state and wait.
- **Connector-first:** the attendee asks only for the connector (SQL or wizard). Resolve its prerequisites yourself:
  run `SHOW OPENFLOW RUNTIMES LIKE 'POSTGRES_RUNTIME_SOM' IN SCHEMA OPENFLOW_DB.OPENFLOW_SCHEMA`; if missing, tell
  the attendee "the connector needs a runtime, creating POSTGRES_RUNTIME_SOM first", run steps 1-2 of
  `04_runtime_connector.sql`, wait for ACTIVE, then build the connector. If it exists but isn't ACTIVE, wait/resume it.
- `GRANT READ ON SECRET ... TO ROLE POSTGRES_INGEST_SERVICE_ROLE` (as ACCOUNTADMIN).
- Runtime `OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_RUNTIME_SOM` IN DEPLOYMENT `SPCS_SOM`,
  `NODE_TYPE=SMALL` (default tier S1), `MIN_NODES=1`, `MAX_NODES=1`, `EXECUTE_AS_ROLE=POSTGRES_INGEST_SERVICE_ROLE`,
  `EXTERNAL_ACCESS_INTEGRATIONS=(RETAIL_HOL_POSTGRES_EAI)`. Wait for ACTIVE.
- Tasks `SUSPEND_POSTGRES_RUNTIME_SOM` (5 PM PT) / `RESUME_POSTGRES_RUNTIME_SOM` (6 AM PT). Leave them suspended unless asked.
- Connector `POSTGRES_INGEST` — **configured with SQL, not the wizard.** Run
  `<venv-python> scripts/configure_connector.py --account <ORG-ACCOUNT>`. It does
  `CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC` -> waits out CREATING ->
  `GET` live `config.json` to `./connector/` -> sets values -> `PUT` JDBC jar + config to the live
  **directory** -> `COMMIT` -> wait stable -> `START` -> wait stable, and prints the changed keys.
  Show the attendee the changed-keys list. Details/format: `references/connector_config.md`.
- **Wizard path (Option B):** if the attendee prefers the UI, do NOT run `configure_connector.py`.
  Give them the wizard steps and value table from `references/connector_config.md` ("Wizard path"),
  filling in their real host from the `setup_postgres.py` output (never the password). They create and
  Start it in Snowsight; then you run Checkpoint C. Both paths produce the same `POSTGRES_INGEST`.
- Destination: `RETAIL_HOL_ICEBERG`, schema strategy `SOURCE_SCHEMA` (lands in `RETAIL_HOL_ICEBERG.BRONZE`),
  Iceberg v3 tables, warehouse `RETAIL_HOL_WH`, ingestion type Full (snapshot + CDC).

### Act 4 — Observability (`solutions/04b_observability.sql`, `scripts/cdc_demo.py`)
- Event table `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS` (created in Act 1; re-asserted here with IF NOT EXISTS)
  attached via `ALTER OPENFLOW DEPLOYMENT SPCS_SOM SET EVENT_TABLE = ...`.
- Grants for the dashboard (read access): USAGE on `OPENFLOW_DB` + `OPENFLOW_SCHEMA`, SELECT on the event table to `RETAIL_HOL_ROLE`.
- Clustering (documented dashboard optimization):
  `CLUSTER BY (DATE_TRUNC('HOUR', timestamp), RECORD_TYPE, CAST(record_attributes:"metricNameHash" AS STRING))`.
- Telemetry queries (verified against real Openflow telemetry): log level is `TRY_PARSE_JSON(value):level` with
  `record_type = 'LOG'`; metrics use `record:metric:name` with `record_type = 'METRIC'`. Never filter on
  `record_attributes:severity_text` — Openflow logs don't populate it (returns 0 rows even when errors exist).
- Dashboard (Snowsight UI, attendee clicks): **tell them to switch Snowsight role to OPENFLOW_ADMIN first** (the dashboard
  and the wizard only show the connector under that role); Ingestion -> Openflow -> Connector Observability; event table
  `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`; Last Hour; POSTGRES_INGEST -> View Details (per-table phase/status/Last Ingested);
  Unhealthy -> Troubleshoot (AI), Issues tab, View logs.
- Live-CDC proof (default in the lab): `<venv-python> scripts/cdc_demo.py --account <ORG-ACCOUNT> --continuous`
  **run it in the background** (bash `run_in_background`), then read its output to report Postgres vs Bronze counts.
  It inserts sales + a review and UPDATEs inventory every 5 s for 20 min. It can keep running through
  `fail_replication.py` (Postgres keeps accepting writes while the connector restarts). Stop it (kill the shell) when the
  attendee asks, and always before cleanup.
  One-shot variant (no `--continuous`): inserts 5 sales rows and polls until they land. Never write SQL with the Postgres password.
- Latency (queries 9-11 in `04b_observability.sql`): `db.commit.to.merge.latency` (per table, end to end),
  `db.commit.to.capture.latency`, `db.capture.to.journal.latency` (connector level), all in ms, reported every 60 s
  only while data flows — if they return 0 rows, start the generator. Report p50/max in seconds.
  **Never wait or sleep for more reports.** Answer immediately with whatever exists, even a single report:
  give the latest value per metric/table in seconds (plus p50/max when there are 2+ reports) and its timestamp.
  If there is only 1-2 reports, add one line: "more reports arrive every 60 s; ask again later for a fuller picture".
- Alert + failure drill: run the alert block in `04b_observability.sql` **as written**. It uses the built-in Openflow
  template (`CREATE OR REPLACE ALERT ... FROM TEMPLATE OPENFLOW_GEN2_TABLE_REPLICATION_FAILURE`), owned by
  **OPENFLOW_ADMIN**: first, as ACCOUNTADMIN, grant OPENFLOW_ADMIN `EXECUTE ALERT` on the account, `CREATE ALERT` on the
  schema and USAGE on RETAIL_HOL_WH, and drop any old copy of the alert (+ the legacy `REPLICATION_ALERT_LOG` table);
  then as OPENFLOW_ADMIN create and RESUME it. Do NOT hand-write an alert condition or a log table. Use the **Gen2**
  template (the gen 1 one doesn't see POSTGRES_INGEST). Errors: "EXECUTE ALERT privilege must be granted to owner role"
  or "No Openflow connectors visible for scope" -> re-run the grants. Then
  `<venv-python> scripts/fail_replication.py --account <ORG-ACCOUNT> --break` (adds `bronze.pos_events`, no primary key,
  to the publication and connector; expect `db.table.status = 4008`). Wait ~3 min, show query 11 (pos_events = 4008) and query 12 (ALERT_HISTORY state TRIGGERED; the template keeps
  no log table, and its IN_APP notification goes only to VHOLuser, so point attendees to the history / Monitoring -> Alerts), and
  point to View Details on the dashboard. Restore with `--fix` when asked (or before Act 5): **run `--fix` in the background** (bash `run_in_background`)
  and move straight on with the attendee; don't sit waiting on it. Both modes return as soon as START is sent
  (add `--wait` only if you must block until RUNNING). Never hand-patch around script errors; `git pull` first. Only `pos_events` is
  ever broken — never alter the 5 lab tables. Mention that Snowsight Monitoring -> Alerts -> OPENFLOW offers the same template (email/webhook) as the no-SQL option.

### Act 5 — Silver + Gold Dynamic Iceberg Tables (`solutions/05_silver.sql`, `06_gold.sql`)
First (as ACCOUNTADMIN) grant `RETAIL_HOL_ROLE` USAGE on `RETAIL_HOL_ICEBERG.BRONZE` and
SELECT on all + future tables and Iceberg tables. Then as `RETAIL_HOL_ROLE`:
| Table | Lag | Notes |
|---|---|---|
| `SILVER_MANAGED_ICEBERG.SILVER_SALES` | DOWNSTREAM | unpivot 5 regional unit columns -> REGION rows |
| `SILVER_MANAGED_ICEBERG.SILVER_INVENTORY` | 5 minutes | flatten JSONB, STOCK_HEALTH (CRITICAL/LOW/NORMAL/OVERSTOCKED), lon/lat |
| `SILVER_MANAGED_ICEBERG.SILVER_PRODUCT_REVIEWS` | 10 minutes | `AI_SENTIMENT` label + score, `AI_CLASSIFY` theme |
| `GOLD_MANAGED_ICEBERG.DAILY_PRODUCT_PERFORMANCE` | 10 minutes | FROZEN WHERE > 7 days |
| `GOLD_MANAGED_ICEBERG.CUSTOMER_VOICE_ANALYTICS` | 15 minutes | AI_SENTIMENT + AI_SUMMARIZE + AI_CLASSIFY, FROZEN > 14 days |
| `GOLD_MANAGED_ICEBERG.WEEKLY_PRODUCT_SCORECARD` | 1 hour | reads DAILY_PRODUCT_PERFORMANCE, FROZEN > 30 days |
All: `CREATE OR REPLACE DYNAMIC ICEBERG TABLE`, `WAREHOUSE=RETAIL_HOL_WH`, `REFRESH_MODE=ADAPTIVE`.
No CATALOG/EXTERNAL_VOLUME clauses — they inherit Snowflake-managed storage from the database.
**AI functions:** use only the `AI_*` functions as written in `05_silver.sql` / `06_gold.sql`. Never use
`SNOWFLAKE.CORTEX.SENTIMENT` / `CLASSIFY_TEXT` / `SUMMARIZE` — new accounts are blocked from the legacy namespace.
`AI_SENTIMENT` returns a label (`:categories[0]:sentiment`), so the files keep the label and map it to a FLOAT score
(positive 1, neutral/mixed 0, negative -1) that Gold, the semantic view and the agent use; `AI_CLASSIFY` is read with `:labels[0]`.
Bronze column names are UPPERCASE (connector uses case-insensitive identifiers).

### Act 6 — Semantic View + Agent (`solutions/07_semantic_view.sql`, `08_agent.sql`, `references/agent_spec.md`)
- Semantic view `RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_PRODUCT_INTELLIGENCE`
  via `CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG', $$...$$)`.
  Use the YAML verbatim from `solutions/07_semantic_view.sql`.
- Agent `RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT`, `CREATE OR REPLACE AGENT ... FROM SPECIFICATION $$ ... $$`
  verbatim from `solutions/08_agent.sql` (`models.orchestration: auto`, budget 30s / 16000 tokens).
  Dollar-quote with plain `$$` (named tags like `$spec$` fail in CoCo's SQL path).
- To change the agent, re-run the full CREATE OR REPLACE statement; do not use a workspace
  file edit/redeploy path.
- Snowsight UI (attendee clicks; you can't do it from SQL here): **AI (or AI & ML) -> Agent Studio -> RETAIL_ANALYST_AGENT**.
  **Always publish it to CoWork yourself** right after creating the agent: run the CoWork block at the end of
  `08_agent.sql` as ACCOUNTADMIN (`CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS ...`, `GRANT USAGE ON AGENT`,
  `ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT ...`, `GRANT USAGE ... TO ROLE PUBLIC`,
  `GRANT MODIFY ... TO ROLE RETAIL_HOL_ROLE`). Event accounts have no CoWork object until this runs, so the UI button is
  greyed out for every role (even ACCOUNTADMIN) before it.
  "Already added" on re-run is fine. The UI button needs MODIFY on the CoWork object (ACCOUNTADMIN only), so other roles get
  "You do not have MODIFY privilege". Then the attendee opens the agent in Agent Studio and, on the Preview tab **Preview in Snowflake CoWork** -> pick Retail Analyst Agent -> ask the persona questions. Programmatic option: `SNOWFLAKE.CORTEX.DATA_AGENT_RUN`
  (example in `08_agent.sql`).

## Preflight (run before Act 1)
```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW OPENFLOW DEPLOYMENTS;            -- command must be recognized
SHOW POSTGRES INSTANCES;              -- command must be recognized
SELECT AI_SENTIMENT('Smells amazing'):categories[0]:sentiment::VARCHAR AS cortex_ok;  -- expect 'positive'
```
If any fails with "unsupported"/"unknown command", stop and tell the attendee which
feature is unavailable in this account/region. (Openflow terms of service may need to be
accepted once by ORGADMIN; if deployment creation fails mentioning terms, say so.)

## Workflow (one prompt each)
0. Connection + skill check, Preflight.
1. Environment + kick off Openflow deployment (do not wait). Checkpoint D: `SHOW OPENFLOW DEPLOYMENTS` (expect CREATING/…).
2. Postgres instance -> READY -> pg_creds.json -> secret + egress rule -> venv + loader. Checkpoint P.
3. (Deployment ACTIVE) Attendee asks for the connector -> you detect the missing runtime and create it (SMALL) -> ACTIVE -> tasks -> connector via SQL (Option A) or wizard guidance (Option B) -> START. Checkpoints R, C.
4. Observability: `04b_observability.sql` queries 1-8 -> dashboard -> `cdc_demo.py --continuous` (background) -> latency queries 9-11 -> template alert -> `fail_replication.py --break` -> queries 11-12 -> `--fix`. Checkpoint O.
5. Bronze grants -> Silver -> Gold. Checkpoints S, G.
6. Semantic view -> agent -> ask persona questions (from `references/agent_spec.md`) with DATA_AGENT_RUN -> publish to CoWork via the SQL block in `08_agent.sql` (ACCOUNTADMIN) -> point them to
   Agent Studio -> Preview -> Preview in Snowflake CoWork.
   Data note: the generated inventory is never CRITICAL/LOW (~86% OVERSTOCKED), so the Supply Chain story is
   overstock + rebalancing, not stock-outs. The 30 s budget can cut off long answers; suggest "continue".
7. Cleanup only when explicitly asked: stop any background `cdc_demo.py`, then `solutions/99_cleanup.sql` (confirm first — destructive).
   Do the pre-cleanup checks with SHOW / DESCRIBE (no warehouse needed); RETAIL_HOL_WH is dropped near the end.
   SUSPEND/TERMINATE are async: poll the SHOW check after each until the status is reached before the
   next DROP (in `SHOW OPENFLOW DEPLOYMENTS` the status is the 3rd column; the 2nd is `type`).
   If the account has other Openflow runtimes or objects in `RETAIL_HOL_ADMIN` / using `RETAIL_HOL_ROLE`,
   do NOT drop those shared objects — drop only the lab objects and tell the attendee what was kept.

## Checkpoints
- **D (deployment):** `SHOW OPENFLOW DEPLOYMENTS;` -> `SPCS_SOM` state. ACTIVE needed before Act 3.
- **P (Postgres):** loader prints sales_transactions 4,375 / daily_reviews 4,375 / product_reviews 512 /
  customer_comments 200 / inventory_feed 634 (total 10,096), and the 5 tables in `openflow_retail_pub`.
- **R (runtime):** `DESCRIBE OPENFLOW RUNTIME POSTGRES_RUNTIME_SOM;` -> ACTIVE.
- **C (CDC):** `SHOW ICEBERG TABLES IN SCHEMA RETAIL_HOL_ICEBERG.BRONZE;` shows 5 tables, then
  per-table `COUNT(*)` equals the loader counts (snapshot lands ~1–3 min after START).
  If empty after ~5 min, run the error-log query in `solutions/04b_observability.sql` (`TRY_PARSE_JSON(value):level = 'ERROR'`, `record_type = 'LOG'`; NOT `record_attributes:severity_text`, which never matches Openflow logs).
- **O (observability):** event-table telemetry query (query 4) returns LOG and METRIC rows; error-log query (5)
  returns 0 rows; `cdc_demo.py` shows Bronze keeping up; latency query 9 returns rows; after `--break` query 11 shows
  `pos_events` at 4008 and ALERT_HISTORY shows TRIGGERED; after `--fix` the 5 lab tables are still status 3; dashboard shows POSTGRES_INGEST **Healthy**
  with tables in **Incremental Replication**. Dashboard needs minimum versions (Snowflake deployment 1.26.0,
  runtime 2026.3.17.13, PostgreSQL connector 0.39.0); if it says **Upgrade required**, say so — SQL checks still work.
- **S (silver):** `SHOW DYNAMIC TABLES IN SCHEMA RETAIL_HOL_ICEBERG.SILVER_MANAGED_ICEBERG;` -> 3 tables, is_iceberg = true, ADAPTIVE
  (SILVER_SALES 21,875 rows = 4,375 x 5 regions; SILVER_INVENTORY 634; SILVER_PRODUCT_REVIEWS 512).
  Peek: negative reviews (`AI_SENTIMENT_LABEL = 'negative'`) from `SILVER_PRODUCT_REVIEWS` with `AI_REVIEW_THEME`.
- **G (gold):** `SHOW DYNAMIC TABLES IN SCHEMA RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG;` -> 3 tables with `immutable_where` set; refresh history query in `06_gold.sql`.
- **A (agent):** `SHOW AGENTS IN SCHEMA RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG;`, one DATA_AGENT_RUN answer, and
  `SHOW AGENTS IN SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;` lists RETAIL_ANALYST_AGENT.

## Why it matters (say one line after each part)
1. Infrastructure-as-SQL, least-privilege by construction (connector runs as a single ingest role), observable from minute one (event table).
2. OLTP lives in the same account as analytics — no egress, one security perimeter.
3. CDC without a third-party engine: the Openflow runtime is Snowflake-managed SPCS; connector config is code (config.json, versioned, committed).
4. Telemetry lands in an event table you own: one dashboard for operators, connector-measured latency from source commit to Bronze, plain SQL alerts that catch a failed table (isolated, the rest keep flowing), AI Troubleshoot for root cause.
5. Open format with zero setup (Snowflake-managed Iceberg), ADAPTIVE incremental refresh, FROZEN regions stop re-processing history, AI enrichment inline in SQL.
6. The agent writes the SQL; one semantic model answers all four personas; budgets cap cost; one click puts it in CoWork for business users.

## Stopping points
- Do not start Act 3 until the deployment is ACTIVE; do not START the connector until COMMIT is stable.
- Confirm with the attendee before running `99_cleanup.sql`.

## References
- `references/object_model.md` — part-by-part pointer to verbatim DDL in `solutions/` + gotchas.
- `references/connector_config.md` — SQL connector configuration procedure, real config.json format, and the wizard path.
- `references/agent_spec.md` — persona question bank and agent notes.
