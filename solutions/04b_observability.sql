-- Openflow Retail VHOL — Act 4: Watch it flow (observability)
-- Source: docs "Monitor connectors using the Openflow Connectors Dashboard" + "Monitor Openflow using telemetry data".
-- Prereq: Act 3 done (connector POSTGRES_INGEST RUNNING). Safe to re-run.
-- Story: health (1-8) -> latency (9-11) -> Openflow template alert + failure drill (alert block, 12, scripts/fail_replication.py).

USE ROLE ACCOUNTADMIN;

-- 1. Dedicated event table for Openflow telemetry (created in Act 1; IF NOT EXISTS keeps this re-runnable).
--    A dedicated table keeps Openflow logs/metrics out of the account-wide SNOWFLAKE.TELEMETRY.EVENTS,
--    so the dashboard and SQL queries are faster and access can be granted narrowly.
CREATE EVENT TABLE IF NOT EXISTS OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  COMMENT = 'Openflow telemetry (logs + metrics) for deployment SPCS_SOM';
ALTER OPENFLOW DEPLOYMENT SPCS_SOM SET EVENT_TABLE = OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS;

-- 2. Read access for the data role (the dashboard needs at least read-only access to the event table).
GRANT USAGE ON DATABASE OPENFLOW_DB TO ROLE RETAIL_HOL_ROLE;
GRANT USAGE ON SCHEMA OPENFLOW_DB.OPENFLOW_SCHEMA TO ROLE RETAIL_HOL_ROLE;
GRANT SELECT ON TABLE OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS TO ROLE RETAIL_HOL_ROLE;

-- 3. Speed up the dashboard: cluster the event table (documented recommendation).
--    Automatic clustering uses serverless credits; the benefit appears once background clustering completes.
ALTER TABLE OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  CLUSTER BY (
    DATE_TRUNC('HOUR', timestamp),
    RECORD_TYPE,
    CAST(record_attributes:"metricNameHash" AS STRING)
  );

-- 4. Is telemetry arriving? (rows by type in the last hour)
SELECT record_type, COUNT(*) AS events_last_hour, MAX(timestamp) AS latest_event
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('hour', -1, SYSDATE())
GROUP BY record_type;

-- 5. Error logs from the Openflow runtime (last 30 min).
--    A short burst right after the connector STARTs is normal: net.snowflake.client...RestRequest
--    "SocketTimeoutException / Stop retrying since elapsed time due to network issues" for a few seconds while the
--    runtime's network comes up (seen on a clean run: 16 rows within 2 s, data loaded fine). Judge health by 5b.
SELECT timestamp, runtime_key,
       parsed_log:level::STRING            AS log_level,
       parsed_log:loggerName::STRING       AS logger,
       parsed_log:formattedMessage::STRING AS message
FROM (
  SELECT timestamp,
         resource_attributes:"k8s.namespace.name"::STRING AS runtime_key,
         TRY_PARSE_JSON(value) AS parsed_log
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('minutes', -30, SYSDATE())
    AND record_type = 'LOG'
    AND resource_attributes:"k8s.namespace.name" LIKE 'runtime-%'
)
WHERE log_level = 'ERROR'
ORDER BY timestamp DESC
LIMIT 20;

-- 5b. Errors still happening: last 5 minutes. Expect 0 once the connector has been running a few minutes.
--     A non-zero count here (not just the startup burst above) is the signal to troubleshoot.
SELECT COUNT(*) AS errors_last_5_min,
       ARRAY_AGG(DISTINCT TRY_PARSE_JSON(value):loggerName::STRING) AS loggers
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minutes', -5, SYSDATE())
  AND record_type = 'LOG'
  AND resource_attributes:"k8s.namespace.name" LIKE 'runtime-%'
  AND TRY_PARSE_JSON(value):level::STRING = 'ERROR';

-- 6. Stuck FlowFiles: connections with data queued > 30 minutes. Expect zero rows.
SELECT * FROM (
  SELECT resource_attributes:"k8s.namespace.name"::STRING AS runtime_key,
         record_attributes:name::STRING AS connection_name,
         MAX(TO_NUMBER(value / 60 / 1000)) AS max_queued_minutes
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE record_type = 'METRIC'
    AND record:metric:name = 'connection.queued.duration.max'
    AND timestamp > DATEADD('minutes', -30, SYSDATE())
  GROUP BY 1, 2
) WHERE max_queued_minutes > 30;

-- 7. Runtime CPU (%), last 30 min — chart this in Snowsight.
SELECT timestamp,
       resource_attributes:"k8s.pod.name"::STRING AS runtime_pod,
       TO_NUMBER(value, 10, 3) * 100 AS cpu_usage_pct
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minute', -30, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name ILIKE 'container.cpu.usage'
  AND resource_attributes:"k8s.namespace.name" ILIKE 'runtime-%'
  AND resource_attributes:"k8s.container.name" ILIKE '%-server'
ORDER BY timestamp DESC;

-- 8. Prove CDC end to end: freshest row per Bronze table (run after changing data in Postgres).
SELECT 'SALES_TRANSACTIONS' AS table_name, COUNT(*) AS row_count FROM RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS
UNION ALL SELECT 'PRODUCT_REVIEWS',   COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.PRODUCT_REVIEWS
UNION ALL SELECT 'CUSTOMER_COMMENTS', COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.CUSTOMER_COMMENTS
UNION ALL SELECT 'DAILY_REVIEWS',     COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.DAILY_REVIEWS
UNION ALL SELECT 'INVENTORY_FEED',    COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.INVENTORY_FEED;

-- ============================ Latency (PostgreSQL connector metrics) ============================
-- The connector reports three latencies every 60 s while data flows (docs: "Monitor the Openflow Connector for PostgreSQL"):
--   db.commit.to.capture.latency   source COMMIT -> connector read it        (connector level)
--   db.capture.to.journal.latency  connector read -> journal table in Snowflake (connector level)
--   db.commit.to.merge.latency     source COMMIT -> merged into the Bronze table (per table, end to end)
-- Run scripts/cdc_demo.py --continuous first so there is traffic to measure.

-- 9. End-to-end latency per table (commit in Postgres -> row in Bronze). Chart: X = minute, Y = latency_s, series = source_table.
SELECT DATE_TRUNC('minute', timestamp)                AS minute,
       record_attributes:"source.table.name"::STRING   AS source_table,
       MAX(value::NUMBER) / 1000                       AS latency_s
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('hour', -1, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name = 'db.commit.to.merge.latency'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

-- 10. Where the time goes: capture vs journal vs end-to-end, last 15 min (p50 / max of the 60 s reports).
SELECT record:metric:name::STRING                                  AS metric,
       COUNT(*)                                                    AS reports,
       ROUND(APPROX_PERCENTILE(value::NUMBER, 0.5) / 1000, 1)      AS p50_s,
       ROUND(MAX(value::NUMBER) / 1000, 1)                         AS max_s
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minute', -15, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name IN ('db.commit.to.capture.latency', 'db.capture.to.journal.latency', 'db.commit.to.merge.latency')
GROUP BY 1
ORDER BY 1;

-- 11. Freshness + phase per table: latest replication status and when Bronze was last written.
--     Status 1 NEW, 2 SNAPSHOT_REPLICATION, 3 INCREMENTAL_REPLICATION, >= 4 FAILED (4008 = MISSING_PRIMARY_KEYS).
WITH status AS (
  SELECT record_attributes:"source.schema.name"::STRING AS source_schema,
         record_attributes:"source.table.name"::STRING  AS source_table,
         value::NUMBER                                  AS status,
         timestamp
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('hour', -1, SYSDATE())
    AND record_type = 'METRIC'
    AND record:metric:name = 'db.table.status'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY source_schema, source_table ORDER BY timestamp DESC) = 1
), fresh AS (
  SELECT record_attributes:"source.schema.name"::STRING AS source_schema,
         record_attributes:"source.table.name"::STRING  AS source_table,
         TO_TIMESTAMP_LTZ(MAX(value::NUMBER), 3)        AS last_ingested
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('hour', -1, SYSDATE())
    AND record_type = 'METRIC'
    AND record:metric:name = 'db.last.ingestion.time'
  GROUP BY 1, 2
)
SELECT s.source_schema, s.source_table, s.status,
       CASE s.status WHEN 1 THEN 'NEW' WHEN 2 THEN 'SNAPSHOT_REPLICATION' WHEN 3 THEN 'INCREMENTAL_REPLICATION'
                     WHEN 4008 THEN 'FAILED: MISSING_PRIMARY_KEYS' ELSE IFF(s.status >= 4, 'FAILED', 'REMOVED') END AS phase,
       f.last_ingested,
       DATEDIFF('second', f.last_ingested, CURRENT_TIMESTAMP()) AS seconds_since_last_write
FROM status s LEFT JOIN fresh f USING (source_schema, source_table)
ORDER BY s.status DESC, s.source_table;

-- ============================ Alert: table replication failure (template) ============================
-- Two parts, because the template notifies the user who runs the CREATE, and that must be the person watching
-- Snowsight (CoCo's VHOLuser never logs in to the web UI, so its in-app notifications would go unseen).
--   PART A (CoCo, as VHOLuser):            grants + drop any old copy. Run by CoCo.
--   PART B (Snowsight, as YOUR web user):  CREATE + RESUME. Paste into a Snowsight worksheet and run it there.
-- The alert is owned by OPENFLOW_ADMIN, the role that runs Openflow. The owner role needs the EXECUTE ALERT
-- account privilege (otherwise every run fails with "EXECUTE ALERT privilege must be granted to owner role"),
-- CREATE ALERT on the schema, and USAGE on the warehouse. It also needs USAGE on the runtime in scope, which it
-- already has as the runtime owner; without it the template fails with "No Openflow connectors visible for scope".
-- POSTGRES_INGEST is a gen 2 connector, so use the Gen2 template; the gen 1 template does not monitor it.
-- Snowsight equivalent: Monitoring -> Alerts -> + Alert -> OPENFLOW group -> "Table replication failure alert (Gen2)".

-- ---------- PART A (CoCo) ----------
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE ALERT ON SCHEMA OPENFLOW_DB.OPENFLOW_SCHEMA TO ROLE OPENFLOW_ADMIN;
GRANT USAGE ON WAREHOUSE RETAIL_HOL_WH TO ROLE OPENFLOW_ADMIN;

-- An earlier lab version created this alert as ACCOUNTADMIN; CREATE OR REPLACE as OPENFLOW_ADMIN needs
-- ownership, so drop any existing copy first (safe: the template recreates it below).
DROP ALERT IF EXISTS OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT;
DROP TABLE IF EXISTS OPENFLOW_DB.OPENFLOW_SCHEMA.REPLICATION_ALERT_LOG;  -- log table from the old hand-written alert

-- ---------- PART B (Snowsight worksheet, signed in as your web user, e.g. the event USER) ----------
-- Your user needs OPENFLOW_ADMIN; event users get it through ACCOUNTADMIN -> SYSADMIN (02_openflow_deployment.sql).
USE ROLE OPENFLOW_ADMIN;
USE WAREHOUSE RETAIL_HOL_WH;

-- Optional: list the Openflow replication templates and their current versions
SELECT t.value:template_id::STRING     AS template_id,
       t.value:display_name::STRING    AS display_name,
       t.value:template_version::STRING AS template_version
FROM TABLE(FLATTEN(PARSE_JSON(SYSTEM$LIST_ALERT_TEMPLATES()):template_groups)) g,
     TABLE(FLATTEN(g.value:templates)) t
WHERE g.value:product::STRING = 'OPENFLOW'
  AND t.value:display_name ILIKE '%replication%';

-- Optional: see the template's variables and a ready-made CREATE statement
SELECT PARSE_JSON(SYSTEM$GET_ALERT_TEMPLATE('OPENFLOW_GEN2_TABLE_REPLICATION_FAILURE')):template:create_syntax::STRING AS create_syntax;

-- The template supplies the condition and action; you only set scope, lookback and notification.
--   SCOPE_ACTIVE / SCOPE_NAME  limit the alert to the POSTGRES_INGEST connector
--   TABLE_NAMES                empty = every replicated table
--   NOTIFICATION_MODE IN_APP   notifies the user who runs this CREATE (the template records that user at create time),
--                              which is why PART B runs in Snowsight as you. The alert is owned by OPENFLOW_ADMIN, so
--                              fail_replication.py (as VHOLuser) can still SUSPEND/RESUME it. No notification integration
--                              needed. The template takes one mode per alert; for email, set EMAIL (verified profile email).
--   SCHEDULE '1 MINUTE'        so the failure drill shows quickly (template default is 5 minutes)
--   LOOKBACK 1 hour            the minimum (whole hours). After --fix the alert would keep TRIGGERing for up to an hour
--                              on the old failure, so fail_replication.py --fix suspends it and --break resumes it.
CREATE OR REPLACE ALERT OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT
  FROM TEMPLATE OPENFLOW_GEN2_TABLE_REPLICATION_FAILURE
  WAREHOUSE = RETAIL_HOL_WH
  SCHEDULE = '1 MINUTE'
  TEMPLATE_PARAMS = '{
  "template_variables" : {
    "LOOKBACK_WINDOW_IN_HOURS" : 1,
    "SCOPE_ACTIVE" : "OPENFLOW_CONNECTOR",
    "SCOPE_NAME" : "OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST",
    "TABLE_NAMES" : "",
    "NOTIFICATION_MODE" : "IN_APP",
    "EMAIL_NOTIFICATION_INTEGRATION" : "",
    "WEBHOOK_NOTIFICATION_INTEGRATION" : "",
    "QUEUE_NOTIFICATION_INTEGRATION" : ""
  }
}';

ALTER ALERT OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT RESUME;  -- alerts are created suspended
-- ---------- end of PART B; back to CoCo for the drill (scripts/fail_replication.py --break) ----------

-- 12. Did it fire? (after scripts/fail_replication.py --break; allow ~2-3 min: 60 s metric + 1 min schedule)
--     The template keeps no log table (no REPLICATION_ALERT_LOG); firings show here and in Monitoring -> Alerts.
--     It reports TRIGGERED on every run while a table is failed but notifies at most once per hour.
SELECT name, state, scheduled_time, completed_time, sql_error_message
FROM TABLE(OPENFLOW_DB.INFORMATION_SCHEMA.ALERT_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('minute', -30, CURRENT_TIMESTAMP()),
  ALERT_NAME => 'POSTGRES_INGEST_TABLE_FAILURE_ALERT'))
ORDER BY scheduled_time DESC
LIMIT 10;

-- Which table failed? Same per-table status the alert reads (query 11 in 04b_observability.sql has the full version).
SELECT record_attributes:"source.schema.name"::STRING AS source_schema,
       record_attributes:"source.table.name"::STRING  AS source_table,
       value::NUMBER                                  AS status,
       timestamp                                      AS observed_at_utc
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minute', -10, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name = 'db.table.status'
QUALIFY ROW_NUMBER() OVER (PARTITION BY source_schema, source_table ORDER BY timestamp DESC) = 1
  AND status >= 4;

-- Dashboard (Snowsight UI): Ingestion -> Openflow -> Connector Observability
--   Event table filter: OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS   Time frame: Last Hour
--   POSTGRES_INGEST -> (more) -> View Details: per-table replication status/phase/Last Ingested
--   Unhealthy? -> Troubleshoot (AI root cause), Issues tab, View logs, Go to canvas (read-only for wizard connectors)
