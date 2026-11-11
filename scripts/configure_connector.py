"""Act 3 helper: configure + start the POSTGRES_INGEST Openflow Gen2 PostgreSQL CDC connector with SQL.

Follows "Configure a gen 2 connector with SQL" (Snowflake docs):
  CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC
  -> GET live config.json -> set values -> PUT JDBC driver jar + config.json to the live version
  -> ALTER ... COMMIT -> wait stable -> ALTER ... START -> wait stable

The password is never in config.json: it is a SECRET_REFERENCE to
RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD. The host is read from pg_creds.json.

Auth (pick one):
  --account ORG-ACCOUNT    uses user VHOLuser + the PAT in secret.pat (repo root)
  --connection NAME        uses a named connection from ~/.snowflake/connections.toml
Flags:
  --no-start               commit only, do not start
"""
import argparse
import json
import os
import sys
import time
import urllib.request

import snowflake.connector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "connector")  # gitignored
FQN = "OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST"
LIVE = f"snow://openflow_connector/{FQN}/versions/live/"
DRIVER = "postgresql-42.7.5.jar"
DRIVER_URL = f"https://jdbc.postgresql.org/download/{DRIVER}"

TABLES = ",".join(
    f'"bronze"."{t}"'
    for t in ["customer_comments", "daily_reviews", "inventory_feed", "product_reviews", "sales_transactions"]
)


def lit(value):
    return {"valueType": "STRING_LITERAL", "value": value}


def desired(host):
    """Values per config group. Keys/enums match a committed OPENFLOW_POSTGRES_CDC config.json."""
    return {
        "Source": {
            "Source Database Connection URL": lit(f"jdbc:postgresql://{host}:5432/postgres"),
            "Source Database User": lit("snowflake_admin"),
            "Source Database Password": {
                "valueType": "SECRET_REFERENCE",
                "fullyQualifiedSecretName": "RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD",
            },
            "Source Database Publication Name": lit("openflow_retail_pub"),
            "Source Database Driver": {"valueType": "ASSET_REFERENCE", "assetIds": [DRIVER]},
        },
        "Replication table schema": {"Included Comma Separated Source Table Names": lit(TABLES)},
        "Replication columns": {"Column Filter JSON": lit("[]")},
        "Destination authentication": {"Snowflake Authentication Strategy": lit("SNOWFLAKE_MANAGED")},
        "Destination details": {
            "Snowflake Destination Database": lit("RETAIL_HOL_ICEBERG"),
            "Snowflake Warehouse": lit("RETAIL_HOL_WH"),
            "Destination Schema Strategy": lit("SOURCE_SCHEMA"),
            "Object Identifier Resolution": lit("CASE_INSENSITIVE"),
            "Oversized Value Strategy": lit("Set Null"),
            "Table Storage Format": lit("ICEBERG"),
            "Iceberg Version": lit("3"),
        },
        "Tuning": {"Merge Task Schedule CRON": lit("* * * * * ?"), "Concurrent Snapshot Queries": lit("2")},
        "Migration": {"Ingestion Type": lit("full")},
    }


def ensure_live_version(cur):
    """A stopped/committed connector has no live version; LS on it raises instead of returning no rows."""
    try:
        if run(cur, f"LS '{LIVE}'", show=False):
            return
    except snowflake.connector.errors.ProgrammingError:
        pass
    try:
        run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST ADD LIVE VERSION FROM LAST")
    except snowflake.connector.errors.ProgrammingError as e:
        if "already" not in str(e).lower():  # a live version appeared in the meantime: fine
            raise
        print(f"    live version already exists ({e.msg})")


def connect(args):
    if args.connection:
        return snowflake.connector.connect(connection_name=args.connection)
    with open(os.path.join(ROOT, "secret.pat")) as f:
        token = f.read().strip()
    return snowflake.connector.connect(
        account=args.account, user="VHOLuser", authenticator="PROGRAMMATIC_ACCESS_TOKEN", token=token
    )


def run(cur, sql, show=True):
    cur.execute(sql)
    rows = cur.fetchall() if cur.description else []
    if show:
        print(f"OK  {' '.join(sql.split())[:100]}")
    return rows


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--account")
    g.add_argument("--connection")
    p.add_argument("--no-start", action="store_true")
    args = p.parse_args()

    with open(os.path.join(ROOT, "pg_creds.json")) as f:
        host = json.load(f)["host"]
    os.makedirs(WORK, exist_ok=True)

    conn = connect(args)
    cur = conn.cursor()
    run(cur, "USE ROLE OPENFLOW_ADMIN")
    run(cur, "USE DATABASE OPENFLOW_DB")
    run(cur, "USE SCHEMA OPENFLOW_SCHEMA")

    state = run(cur, "DESCRIBE OPENFLOW RUNTIME POSTGRES_RUNTIME_SOM", show=False)[0][1]
    if state != "ACTIVE":
        sys.exit(f"Runtime POSTGRES_RUNTIME_SOM is {state}; wait for ACTIVE and re-run.")

    run(cur, "CREATE OPENFLOW CONNECTOR IF NOT EXISTS POSTGRES_INGEST IN RUNTIME POSTGRES_RUNTIME_SOM "
             "FROM DEFINITION OPENFLOW_POSTGRES_CDC DISPLAY_NAME = 'POSTGRES_INGEST'")
    # A new connector is CREATING briefly before it settles in STOPPED; block server-side instead of polling.
    run(cur, "SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST')")
    status = run(cur, "SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST'", show=False)[0][1]
    if status not in ("STOPPED", "DRAFT"):
        print(f"Connector is {status}; nothing to configure. (Stop it and ADD LIVE VERSION FROM LAST to edit.)")
        return
    # After a commit there is no live version; create one from the last committed config.
    ensure_live_version(cur)

    run(cur, f"GET '{LIVE}config.json' 'file://{WORK}/'")
    path = os.path.join(WORK, "config.json")
    with open(path) as f:
        cfg = json.load(f)

    groups = {g["name"]: g for g in cfg["configuration"]}
    changed = []
    for group, props in desired(host).items():
        if group not in groups:
            sys.exit(f"config.json has no group '{group}'. Groups found: {list(groups)}. Use the wizard fallback.")
        for key, val in props.items():
            if key not in groups[group]["properties"]:
                sys.exit(f"config.json group '{group}' has no key '{key}'. Use the wizard fallback.")
            if groups[group]["properties"][key] != val:
                groups[group]["properties"][key] = val
                changed.append(f"{group} / {key}")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("Changed keys:\n  " + "\n  ".join(changed or ["(none)"]))

    jar = os.path.join(WORK, DRIVER)
    if not os.path.exists(jar):
        print(f"Downloading {DRIVER_URL}")
        urllib.request.urlretrieve(DRIVER_URL, jar)
    run(cur, f"PUT 'file://{jar}' '{LIVE}' AUTO_COMPRESS = FALSE OVERWRITE = TRUE")
    run(cur, f"PUT 'file://{path}' '{LIVE}' AUTO_COMPRESS = FALSE OVERWRITE = TRUE")

    run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST COMMIT")
    print("   ", run(cur, "SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST')")[0][0])
    if not args.no_start:
        run(cur, "ALTER OPENFLOW CONNECTOR POSTGRES_INGEST START")
        print("   ", run(cur, "SELECT SYSTEM$WAIT_FOR_OPENFLOW_CONNECTOR_STATUS(300, 'RUNNING', "
                            "'OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST')")[0][0])
    print("   ", run(cur, "SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST'", show=False)[0][:3])
    conn.close()


if __name__ == "__main__":
    main()
