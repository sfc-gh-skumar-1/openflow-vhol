"""Act 4 failure drill: make ONE table's replication fail on purpose, watch the alert fire, then fix it.

--break  creates Postgres table bronze.pos_events WITHOUT a primary key, adds it to the openflow_retail_pub
         publication and to the POSTGRES_INGEST table list (stop -> edit config.json -> commit -> start).
         The connector can't replicate a table without a primary key, so within ~1-2 min its
         db.table.status becomes 4008 (MISSING_PRIMARY_KEYS), the dashboard shows the table as failed,
         and the Openflow template alert POSTGRES_INGEST_TABLE_FAILURE_ALERT (solutions/04b_observability.sql) fires.
         The 5 lab tables keep replicating: the failure is isolated to one table.
--fix    removes pos_events from the connector and the publication, and drops it from Postgres.

By default the script returns as soon as START is sent (the connector finishes starting on its own);
pass --wait to block until it is RUNNING again. If anything fails after the connector is stopped, the script restarts it on its last committed config,
so CDC is never left paused. Both modes are safe to re-run (e.g. after a partial failure): publication membership and the connector's
live version are checked before they are changed.

Auth (pick one):
  --account ORG-ACCOUNT    uses user VHOLuser + the PAT in secret.pat (repo root)
  --connection NAME        uses a named connection from ~/.snowflake/connections.toml
"""
import argparse
import json
import os
import sys

import psycopg2
import snowflake.connector

from configure_connector import DRIVER, LIVE, ROOT, TABLES, WORK, connect, ensure_live_version, run

DRILL_TABLE = "pos_events"
WAIT = "SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST')"
WAIT_RUNNING = ("SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(600, 'RUNNING', "
                "'OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST')")  # STARTING -> RUNNING, 10 min
TABLE_KEY = ("Replication table schema", "Included Comma Separated Source Table Names")


def in_publication(cur):
    cur.execute("SELECT 1 FROM pg_publication_tables WHERE pubname = 'openflow_retail_pub' "
                "AND schemaname = 'bronze' AND tablename = %s", (DRILL_TABLE,))
    return cur.fetchone() is not None


def postgres(sql_statements):
    with open(os.path.join(ROOT, "pg_creds.json")) as f:
        creds = json.load(f)
    pg = psycopg2.connect(host=creds["host"], port=creds.get("port", 5432), dbname=creds.get("database", "postgres"),
                          user=creds.get("user", "snowflake_admin"), password=creds["password"], sslmode="require")
    pg.autocommit = True
    cur = pg.cursor()
    for sql in sql_statements:
        if callable(sql):  # a step that decides for itself whether to run (keeps re-runs safe)
            sql(cur)
            continue
        cur.execute(sql)
        print(f"PG  {' '.join(sql.split())[:100]}")
    pg.close()


def add_to_publication(cur):
    if in_publication(cur):
        print(f"PG  bronze.{DRILL_TABLE} already in openflow_retail_pub (skipped)")
        return
    cur.execute(f"ALTER PUBLICATION openflow_retail_pub ADD TABLE bronze.{DRILL_TABLE}")
    print(f"PG  ALTER PUBLICATION openflow_retail_pub ADD TABLE bronze.{DRILL_TABLE}")


def drop_from_publication(cur):
    if not in_publication(cur):
        print(f"PG  bronze.{DRILL_TABLE} not in openflow_retail_pub (skipped)")
        return
    cur.execute(f"ALTER PUBLICATION openflow_retail_pub DROP TABLE bronze.{DRILL_TABLE}")
    print(f"PG  ALTER PUBLICATION openflow_retail_pub DROP TABLE bronze.{DRILL_TABLE}")


def set_connector_tables(cur, tables, wait_for_running=False):
    """Stop the connector, set its replicated-table list in the live config.json, commit and start it again."""
    run(cur, "USE ROLE OPENFLOW_ADMIN")
    run(cur, "USE DATABASE OPENFLOW_DB")
    run(cur, "USE SCHEMA OPENFLOW_SCHEMA")
    status = run(cur, "SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST'", show=False)
    if not status:
        sys.exit("Connector POSTGRES_INGEST not found. Finish Act 3 first.")
    if status[0][1] == "RUNNING":
        run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST STOP")
        print("   ", run(cur, WAIT)[0][0])
    try:
        edit_and_commit(cur, tables)
    except BaseException:
        # Never leave CDC paused: whatever failed (commit, upload, Ctrl+C), try to bring the connector back
        # on its last committed config before exiting.
        print("\n!! Edit/commit failed; restarting POSTGRES_INGEST on its last committed config so CDC keeps flowing.")
        try:
            run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST START")
        except Exception as e:
            print(f"!! Could not restart it ({e}). Run: ALTER OPENFLOW CONNECTOR "
                  "OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST START;")
        raise
    run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST START")
    if wait_for_running:
        print("   ", run(cur, WAIT_RUNNING)[0][0])
    else:
        # START is asynchronous; nothing in the lab needs to block until RUNNING, so return now (saves ~1-2 min).
        print("    START sent; the connector reaches RUNNING in ~1-2 min "
              "(check: SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST')")
    print("   ", run(cur, "SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST'", show=False)[0][:3])


def edit_and_commit(cur, tables):
    """Set the replicated-table list in the live config.json and commit it (connector must be stopped)."""
    ensure_live_version(cur)

    os.makedirs(WORK, exist_ok=True)
    run(cur, f"GET '{LIVE}config.json' 'file://{WORK}/'")
    path = os.path.join(WORK, "config.json")
    with open(path) as f:
        cfg = json.load(f)
    group = next(g for g in cfg["configuration"] if g["name"] == TABLE_KEY[0])
    group["properties"][TABLE_KEY[1]] = {"valueType": "STRING_LITERAL", "value": tables}
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"Set {TABLE_KEY[0]} / {TABLE_KEY[1]} = {tables}")

    jar = os.path.join(WORK, DRIVER)
    if os.path.exists(jar):  # keep the driver asset next to the config in the live version
        run(cur, f"PUT 'file://{jar}' '{LIVE}' AUTO_COMPRESS = FALSE OVERWRITE = TRUE")
    run(cur, f"PUT 'file://{path}' '{LIVE}' AUTO_COMPRESS = FALSE OVERWRITE = TRUE")
    run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST COMMIT")
    print("   ", run(cur, WAIT)[0][0])


ALERT = "OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT"


def set_alert(cur, action):
    """RESUME the drill alert on --break; SUSPEND it on --fix (its 1-hour lookback would keep firing on the
    old failure). The alert is optional: skip quietly if it hasn't been created yet."""
    try:
        run(cur, "USE ROLE OPENFLOW_ADMIN")
        run(cur, f"ALTER ALERT IF EXISTS {ALERT} {action}")
    except snowflake.connector.errors.ProgrammingError as e:
        print(f"    (alert not {action.lower()}d: {e.msg})")


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--account")
    g.add_argument("--connection")
    m = p.add_mutually_exclusive_group(required=True)
    m.add_argument("--break", dest="mode", action="store_const", const="break")
    m.add_argument("--fix", dest="mode", action="store_const", const="fix")
    p.add_argument("--wait", action="store_true", help="block until the connector is RUNNING again after START")
    args = p.parse_args()

    conn = connect(args)
    cur = conn.cursor()
    if args.mode == "break":
        postgres([
            f"CREATE TABLE IF NOT EXISTS bronze.{DRILL_TABLE} "
            "(store_id INT, event_type TEXT, event_at TIMESTAMPTZ DEFAULT NOW())",  # no PRIMARY KEY on purpose
            f"INSERT INTO bronze.{DRILL_TABLE} (store_id, event_type) VALUES (1, 'open'), (2, 'open'), (3, 'close')",
            add_to_publication,
        ])
        set_connector_tables(cur, f'{TABLES},"bronze"."{DRILL_TABLE}"', args.wait)
        set_alert(cur, "RESUME")
        print(f"\nBroken on purpose: bronze.{DRILL_TABLE} has no primary key. In ~1-2 min expect "
              "db.table.status = 4008 (query 11), the alert TRIGGERED in ALERT_HISTORY (query 12),\n"
              "and the table marked failed in Connector Observability -> POSTGRES_INGEST -> View Details. "
              "Then run with --fix.")
    else:
        set_connector_tables(cur, TABLES, args.wait)
        set_alert(cur, "SUSPEND")
        postgres([
            drop_from_publication,
            f"DROP TABLE IF EXISTS bronze.{DRILL_TABLE}",
        ])
        print(f"\nFixed: bronze.{DRILL_TABLE} removed from replication; the 5 lab tables are unaffected. "
              "The connector is restarting in the background; you can carry on (e.g. Act 5) now.\n"
              "The drill alert is suspended (its 1-hour lookback would keep firing on the old failure); --break resumes it.")
    conn.close()


if __name__ == "__main__":
    main()
