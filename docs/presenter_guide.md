# Presenter guide — Openflow Retail VHOL

## Run of show (~85 min)
| Min | Act | Presenter does | Attendees do |
|---|---|---|---|
| 0–10 | Setup | Tell the four-personas story. Walk through bootstrap + CoCo connection | Clone, run bootstrap, connect CoCo |
| 10–15 | 0 + 1 | Explain why the deployment goes first (~15 min to ACTIVE) | Preflight, environment, kick off `SPCS_SOM` |
| 15–30 | 2 | Pitch OLTP + analytics on one platform. Show the 5 `bronze` tables and the JSONB/PostGIS columns | Create `RETAIL_HOL_PG`, load data |
| 30–45 | 3 | Highlight the connector-as-code moment: show `config.json`, COMMIT, START. Mention that the wizard (Option B) builds the same connector | Runtime, connector (SQL or wizard), Bronze checkpoint |
| 45–58 | 4 | Open Connector Observability live. Start the continuous generator, chart latency, then break `pos_events` and show the alert firing while the other tables keep flowing | Observability SQL, dashboard, generator, latency, alert drill |
| 55–70 | 5 | Show AI sentiment on the worst reviews, then FROZEN WHERE in `SHOW DYNAMIC TABLES` | Silver, Gold |
| 70–82 | 6 | Ask each persona's question, then open Agent Studio and **Add to Snowflake CoWork** | Semantic view, agent, questions, CoWork |
| 82–85 | 7 | Recap the architecture, then cleanup | Cleanup (optional) |

## Talk track (one line per act)
1. "Before any data moves we separate concerns: the connector runs as a single ingest role, and that's the whole blast radius."
2. "The OLTP database lives in the same account as the analytics, so there's no egress and no second security perimeter."
3. "There's no Debezium or Kafka. The CDC engine is Snowflake-managed compute, and its config is a versioned file you commit."
4. "Health is an event table you own. The connector measures its own latency, commit to Bronze, in seconds. And when one table breaks, an alert fires and the other tables keep flowing."
5. "The data is open Iceberg with zero setup. Refresh is adaptive and history is frozen, and the AI is just a SQL function."
6. "Four personas, one semantic model, one agent with a budget, and one click puts it in CoWork."

## Timing risks and mitigations
- **Deployment provisioning (~15 min).** It must start in Act 1. If an attendee is late, have them run Act 1 immediately and do Act 2 while it provisions.
- **Runtime provisioning (2–5 min).** Attendees only ask for the connector; point out that CoCo worked out it needed a runtime and created it. Fill the wait by explaining `EXECUTE_AS_ROLE` and the cost-control tasks.
- **Initial snapshot.** Bronze tables can take a few minutes to appear after START.
- **AI functions.** Silver/Gold use `AI_SENTIMENT`, `AI_CLASSIFY` and `AI_SUMMARIZE` (new accounts are blocked from the legacy `SNOWFLAKE.CORTEX.*` functions). `AI_SENTIMENT` returns a label (positive/negative/neutral/mixed); the lab maps it to a 1/0/-1 score so averages and "worst sentiment" questions still work.
- **Cortex in Silver/Gold.** The first refresh of `SILVER_PRODUCT_REVIEWS` and `CUSTOMER_VOICE_ANALYTICS` calls AI functions on every row, so allow a couple of minutes.

## Connector SQL path: verified, still rehearse
The SQL steps (`CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC`, then GET/PUT `config.json`, then `COMMIT` and `START`) follow the Snowflake docs. The exact parameter keys in `config.json`, and how the PostgreSQL JDBC driver asset is referenced, come from the definition itself. This was verified end to end on a live account (Nov 2026): the connector reached RUNNING and all 5 Bronze tables matched Postgres. `scripts/configure_connector.py` encodes the real `config.json` format. Still do a dry run on one event account before the day. If the SQL path is blocked, use the wizard fallback in `references/connector_config.md`.

## Observed timings (live run)
- Deployment `SPCS_SOM`: ~15 min to ACTIVE.
- Postgres instance: ~5 min to READY. Loader: <1 min.
- Runtime: ~4 min to ACTIVE. Connector create -> RUNNING: ~2 min. Snapshot in Bronze: ~1–2 min.
- Silver/Gold creation including first AI refresh: ~1 min. Agent answers: 20–30 s. The 30 s budget can truncate multi-step answers ("continue" resumes).

## Data caveat for the story
The generated inventory is never CRITICAL or LOW (~86% OVERSTOCKED), so tell the Supply Chain story as overstock and rebalancing, not stock-outs.

## Observability notes
- The dashboard needs minimum versions (Snowflake deployment 1.26.0, runtime 2026.3.17.13, PostgreSQL connector 0.39.0). If a connector shows **Upgrade required**, the SQL checks in `04b_observability.sql` still work.
- Remind attendees to **switch Snowsight to `OPENFLOW_ADMIN`** before opening Connector Observability or the wizard; under other roles the connector doesn't show.
- Connectors appear only if they emitted telemetry in the selected window. Use **Last Hour** and event table `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`.
- The `severity_text` error query from the original notebook never matches Openflow logs (verified: 0 rows while 116 errors existed). Use query 5 in `04b_observability.sql`.

## Act 4 drill notes
- Start `cdc_demo.py --continuous` early in Act 4; latency metrics are only reported while data flows (every 60 s). CoCo answers immediately with whatever reports exist (no waiting); the numbers get fuller if asked again a few minutes later.
- `fail_replication.py --break` stops and restarts the connector (~1–2 min) to add `pos_events`; the failure status and alert follow ~2–3 min later. Fill the gap with the latency chart.
- Run `--fix` before Act 5 so the dashboard is green again. It runs in the background and returns once START is sent, so start Act 5 immediately; the connector is RUNNING again ~1–2 min later. Only `pos_events` is affected; Silver/Gold don't read it.
- The SQL alert logs to a table (no notification integration needed). For email/webhook, show the OPENFLOW **Table replication failure alert** template in Snowsight Alerts.

## Troubleshooting quick reference
- Openflow errors: run query 5 in `solutions/04b_observability.sql` (parses `value` as JSON and filters `level = 'ERROR'`).
- Connector observability: Snowsight -> Ingestion -> Openflow -> Connector Observability -> event table `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`.
- Lost Postgres password: reset the `snowflake_admin` credentials on the instance, then update the secret and `pg_creds.json`.
- Ask CoCo: "use the openflow-observability skill to diagnose POSTGRES_INGEST".

## Cost notes
- The deployment control pool (CPU_X64_S) runs while the deployment exists.
- The runtime (SMALL, tier S1, one node) bills while ACTIVE. Optional suspend/resume tasks are included.
- The Postgres instance is STANDARD_M with 10 GB.
- Run `99_cleanup.sql` after the event.
