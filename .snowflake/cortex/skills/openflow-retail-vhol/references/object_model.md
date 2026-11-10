# Object model — where the verbatim DDL lives

All DDL is in the repo `solutions/` folder and was taken verbatim from the original
notebooks in `notebooks/`. Run the file for each part in order; do not improvise syntax.

| Act | File | Run as |
|---|---|---|
| 0 | `solutions/00_bootstrap.sql` | Attendee in Snowsight (not CoCo) |
| 1a | `solutions/01_environment.sql` | ACCOUNTADMIN |
| 1b | `solutions/02_openflow_deployment.sql` | ACCOUNTADMIN, then OPENFLOW_ADMIN |
| 2 | `scripts/setup_postgres.py` (runs `03_postgres_instance.sql` steps 1-3) + `scripts/load_retail_data.py` | RETAIL_HOL_ROLE, then ACCOUNTADMIN |
| 3 | `solutions/04_runtime_connector.sql` steps 1-2 (runtime, tasks) + `scripts/configure_connector.py` (connector) | ACCOUNTADMIN / OPENFLOW_ADMIN |
| 4 | `solutions/04b_observability.sql` (health, latency, Openflow template alert) + `scripts/cdc_demo.py --continuous` + `scripts/fail_replication.py --break/--fix` (dashboard is Snowsight UI) | ACCOUNTADMIN; alert + fail_replication as OPENFLOW_ADMIN |
| 5a | `solutions/05_silver.sql` | ACCOUNTADMIN (grants), then RETAIL_HOL_ROLE |
| 5b | `solutions/06_gold.sql` | RETAIL_HOL_ROLE |
| 6a | `solutions/07_semantic_view.sql` | RETAIL_HOL_ROLE |
| 6b | `solutions/08_agent.sql` (agent, then the CoWork publish block) | RETAIL_HOL_ROLE, then ACCOUNTADMIN for CoWork |
| 7 | `solutions/99_cleanup.sql` | ACCOUNTADMIN — confirm first |

## Gotchas
- `01_environment.sql` must run before `02_openflow_deployment.sql` (service-role grants reference its objects).
- `SET MY_USER = CURRENT_USER()` + `IDENTIFIER($MY_USER)` replaces the notebook's hard-coded `"USER"`; run both statements in the same session.
- `CREATE POSTGRES INSTANCE ... ->> SELECT ... FROM $1` uses the pipe operator; the result has the password — handle per SKILL.md "Secrets handling".
- Silver/Gold reference `BRONZE.<TABLE>` unqualified by database, so `USE DATABASE RETAIL_HOL_ICEBERG` first (included in the files).
- `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML` and the agent spec are dollar-quoted with plain `$$`.
- Storage Lifecycle Policies are mentioned in the original Section 3 doc but are NOT in the notebook code; they are intentionally not part of this lab.
