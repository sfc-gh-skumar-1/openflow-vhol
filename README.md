# Prompt to Pipeline: Let AI Build Your Real-Time Data Pipeline, Then Talk to It

Virtual Hands-On Lab.

What if you could build a production-grade data pipeline just by describing it? In this
hands-on lab, you'll do exactly that. Using CoCo, Snowflake's AI coding agent, you'll prompt
your way from an operational Postgres database to a live AI analyst. You'll write no ETL code
and stitch together no tools.

You run a candle and fragrance brand: 12 scents like *Frosted Juniper*, *Vanilla Cedarlight*
and *Sea Salt Blossom*. They sell online and through 4 regional store networks, shipped from
5 warehouses.

Your sales and reviews live in a Postgres database. Your team wants answers now, not next week.

In about an hour you'll stream that data into Snowflake, enrich it with AI, and put an agent on
top that answers questions in plain English, all without leaving Snowflake.

After a one-time setup script, you build everything by prompting **CoCo (Cortex Code) Desktop**.

<p align="center">
  <img src="docs/architecture.svg" alt="RETAIL_HOL_PG (Managed Postgres) streams via Openflow Gen2 PostgreSQL CDC into BRONZE Iceberg tables; Dynamic Iceberg Tables refine to SILVER_MANAGED_ICEBERG then GOLD_MANAGED_ICEBERG; RETAIL_ANALYST_AGENT reads Gold through the RETAIL_PRODUCT_INTELLIGENCE semantic view and is used from Snowflake CoWork and DATA_AGENT_RUN" width="420">
</p>

## The story: four people, four tools, zero alignment

| Persona | Asks | Today |
|---|---|---|
| **The Merchandiser** (daily) | "What sold yesterday? Is anything running low?" | Waits for a nightly batch |
| **The VP of Retail** (weekly) | "How did we do? Where are we trending?" | A slide someone built by hand |
| **The CX Lead** (constantly) | "What are customers saying about us right now?" | Reads reviews one at a time |
| **The Supply Chain Planner** | "Which warehouse needs a truck today?" | A spreadsheet export |

Each of them uses a different tool, waits for a different report, and trusts a different copy of the data.

**What you'll build:** one platform, one pipeline, and one agent that answers all four of them. Every
layer runs inside Snowflake under one governance and RBAC model, with no third-party CDC
engine, no data egress, and no ETL glue.

| Act | Title | You'll see |
|---|---|---|
| **Act 1** | *Lay the foundation* | Openflow set up in SQL (started first, ~15 min) |
| **Act 2** | *Open the store* | Postgres loaded with ~10,000 retail rows |
| **Act 3** | *Stream it in* | Postgres streams into Iceberg via CDC |
| **Act 4** | *Watch it flow* | Live traffic, latency, and an alert on a failed table |
| **Act 5** | *Make it make sense* | Silver/Gold tables with built-in AI |
| **Act 6** | *Ask it anything* | An agent answers every persona, then goes live in CoWork |
| **Act 7** | *Clean up* | Everything removed |

## What you need

- A **Snowflake event account** (provided to you) with SPCS, Openflow, Snowflake Managed
  Postgres and Cortex AI enabled. You will be ACCOUNTADMIN. The lab checks feature availability
  for you in Act 0.
- **CoCo Desktop** ([download](https://www.snowflake.com/en/product/snowflake-coco/downloads/)).
- **Git** and **Python 3.9+** on your machine (used to load the Postgres data).

## Repo layout

```
README.md                         this file: setup + the full lab story
secret.pat_example                template for your PAT: paste the token, rename to secret.pat (gitignored)
solutions/                        SQL answer key (00 bootstrap ... 04b observability ... 08 agent, 99 cleanup)
scripts/setup_postgres.py         creates RETAIL_HOL_PG, saves creds to pg_creds.json, creates the secret + egress rule
scripts/load_retail_data.py       generates + loads the retail data into Postgres, creates the CDC publication
scripts/configure_connector.py    creates + configures (config.json) + commits + starts the CDC connector via SQL
scripts/cdc_demo.py               live CDC proof: one-shot rows, or --continuous traffic generator
scripts/fail_replication.py       Act 4 drill: --break one table (no primary key) to fire the alert, --fix to restore
notebooks/                        the original Snowsight notebooks (reference only)
docs/                             architecture diagram + presenter guide (timing, talk track, troubleshooting)
.snowflake/cortex/skills/openflow-retail-vhol/   the VHOL skill (added in setup step 5)
```

## Setup

### A. Get the lab files

1. Clone the repo. CoCo Desktop will ask for this folder when it launches.
   ```
   git clone https://github.com/sfc-gh-skumar-1/openflow-vhol.git
   cd openflow-vhol
   ```
   (No git? Use **Code -> Download ZIP** and unzip it.)

### B. Bootstrap the account (Snowsight)

2. Log in to your event account in **Snowsight** as the provided admin user (you are ACCOUNTADMIN).

   Run the SQL below in a worksheet (identical to `solutions/00_bootstrap.sql`).

   It's two separate blocks. Run **Block 1**, copy its token, then run **Block 2**.
   In a worksheet, paste one block, highlight it and press **Cmd/Ctrl+Enter**.

   Roles, warehouse, Postgres, Openflow, Iceberg tables and the agent are built later by prompting CoCo (Act 1 onwards).

   #### Block 1: identity + PAT

   Creates the lab user `VHOLuser`, its network policy, and its PAT `vhol_pat`.

   ```sql
   USE ROLE ACCOUNTADMIN;

   -- Lab user for the CoCo connection and the helper scripts. ACCOUNTADMIN so CoCo can
   -- build the rest of the pipeline (roles, Postgres, Openflow, Iceberg, agent) via prompts.
   -- No password is set: the PAT below is the only credential.
   CREATE USER IF NOT EXISTS VHOLuser
     DEFAULT_ROLE = ACCOUNTADMIN
     DEFAULT_SECONDARY_ROLES = ('ALL')
     COMMENT = 'Openflow Retail VHOL lab user';
   GRANT ROLE ACCOUNTADMIN TO USER VHOLuser;

   -- PATs require the user to be under a network policy, so open a permissive one (lab only).
   CREATE NETWORK POLICY IF NOT EXISTS vhol_np ALLOWED_IP_LIST = ('0.0.0.0/0');
   ALTER USER VHOLuser SET NETWORK_POLICY = vhol_np;

   -- No ROLE_RESTRICTION on purpose: a role-restricted PAT pins the session to that one role
   -- (USE ROLE is rejected, secondary roles are ignored). This lab switches between
   -- ACCOUNTADMIN, OPENFLOW_ADMIN and RETAIL_HOL_ROLE, so the token must not be restricted.
   ALTER USER VHOLuser
     ADD PROGRAMMATIC ACCESS TOKEN vhol_pat
       DAYS_TO_EXPIRY = 7
       COMMENT = 'Openflow Retail VHOL lab token';
   ```

   **Copy the `token_secret` from the results grid now** (it's shown only once).

   Save it in the repo root using the template `secret.pat_example`:
   1. Open `secret.pat_example` and replace the placeholder line with your token. The file must contain **only the token**
      (one line, no quotes, no extra text).
   2. Rename the file to **`secret.pat`** (macOS/Linux: `mv secret.pat_example secret.pat`; Windows: `ren secret.pat_example secret.pat`).

   > **Note:** `secret.pat` is listed in `.gitignore`, so it is never committed or pushed to GitHub.

   You'll paste the same token into the CoCo connection (step 4), and the lab's helper scripts read `secret.pat` to log in as `VHOLuser`.

   #### Block 2: account identifier

   ```sql
   SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier;
   ```

   Copy the **`account_identifier`** (e.g. `MYORG-MYACCT`); you'll paste it into the CoCo connection (step 4).

   <details><summary>Optional teardown (later, from Snowsight as your admin user, NOT from CoCo)</summary>

   ```sql
   ALTER USER VHOLuser REMOVE PROGRAMMATIC ACCESS TOKEN vhol_pat;  -- revoke just the token
   DROP USER IF EXISTS VHOLuser;                                   -- remove the lab user
   DROP NETWORK POLICY IF EXISTS vhol_np;                          -- remove its network policy
   ```
   </details>

### C. Connect CoCo Desktop (as VHOLuser)

3. **Install and launch CoCo Desktop.** When it asks for a project folder, open the repo
   folder you cloned in step 1.
   - Download: https://www.snowflake.com/en/product/snowflake-coco/downloads/
   - Setup/docs: https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-desktop

   CoCo Desktop is available to all accounts; usage is billed on token consumption, so it
   runs on your event account's credits.
4. **Add the connection.** In CoCo Desktop click **Connections** -> add a new connection:

   | Field | Value |
   |---|---|
   | Account identifier | `account_identifier` from **Block 2** (e.g. `MYORG-MYACCT`) |
   | User | `VHOLuser` |
   | Authentication | **Password** -> paste the PAT `token_secret` from **Block 1** |

   `VHOLuser` has no real password. Snowflake accepts a PAT anywhere a password is expected, so the
   token *is* the password here. (If your CoCo version lists **Programmatic Access Token**, that works too.)

   Make it the **active** connection.
5. **Add the lab skill.** The `openflow-retail-vhol` skill is what gives everyone the same object names and
   settings, so add it before you start:
   1. In CoCo Desktop, open **Agent Settings** (left sidebar) -> **Skills**.
   2. Click the **+** button (top right, next to **Browse Shared**) and choose **Add Local Skill**.
   3. In the folder picker, go into the repo you cloned in step 1 and select the **`skills`** folder at
      **`openflow-vhol/.snowflake/cortex/skills`** (the folder that *contains* `openflow-retail-vhol/`).
      - `.snowflake` is a hidden folder. On macOS press **Cmd+Shift+. (period)** in the picker to show it; on Windows
        type the path into the address bar, e.g. `C:\...\openflow-vhol\.snowflake\cortex\skills`.
      - Don't pick the repo root (`openflow-vhol`): CoCo only looks one level down and reports
        *"No valid skills found ... Directory was NOT persisted"*.
   4. Search for `openflow-retail-vhol` in **Search skills...** and confirm it's listed.

   (CoCo may already list it, because it auto-discovers skills in an opened project. If it does,
   you're done with this step.)
6. **Pick the model:** the latest Claude Sonnet or Opus, or the latest GPT if Claude isn't listed.

## Run the lab

Each step below is **one prompt** you type into CoCo. The `openflow-retail-vhol` skill makes
sure your objects get exactly the same names and settings as everyone else's. After each
part, CoCo runs a **checkpoint** query and tells you why that step matters.

### Act 0: Ready to build

> Test my Snowflake connection, confirm the openflow-retail-vhol skill is active, and run the lab preflight.

You added the skill in setup step 5; this is a quick check that the connection, skill and account are all
ready. CoCo shows your account, user (`VHOLUSER`), role (`ACCOUNTADMIN`) and region, confirms the skill is
active, and checks that Openflow, Managed Postgres and Cortex AI respond in this account.

---

### Act 1: Lay the foundation (and start the clock)

*An Openflow deployment takes about 15 minutes to become ACTIVE, so you start it first and build
the Postgres source while it provisions.*

> Set up the lab environment: the RETAIL_HOL_ROLE data role, the RETAIL_HOL_WH warehouse, the
> RETAIL_HOL_ADMIN database for secrets and network rules, the RETAIL_HOL_ICEBERG destination
> database on Snowflake-managed Iceberg storage, the Postgres network policy, and the
> RETAIL_HOL_POSTGRES_EAI external access integration.

> Now kick off Openflow: create OPENFLOW_DB.OPENFLOW_SCHEMA, the OPENFLOW_ADMIN role and the
> least-privilege POSTGRES_INGEST_SERVICE_ROLE, the SPCS_SOM Gen2 deployment, and a dedicated
> EVENTS event table attached to it. Don't wait for it to finish.

**Checkpoint D:** `SPCS_SOM` appears in `SHOW OPENFLOW DEPLOYMENTS` while it provisions.

> **Why it matters.** The whole deployment is *infrastructure-as-SQL*: repeatable, reviewable,
> and version-controlled. Before any data moves, admin duties and the connector's identity are
> already separated, so a compromised connector can only affect a single ingest role. Telemetry
> lands in an event table from the first minute.

---

### Act 2: Open the store (the operational source)

*Your store's system of record is a Postgres database. With Snowflake Managed Postgres it runs
in the same account as your analytics.*

> Set up a Python virtual environment for my OS and install scripts/requirements.txt.

> Create the RETAIL_HOL_PG Snowflake Managed Postgres instance for the lab, without showing me
> its password, and wire up the secret and egress rule.

CoCo runs `scripts/setup_postgres.py`, which takes about 5 minutes. It creates the instance and
writes the one-time `snowflake_admin` password straight to `pg_creds.json` (gitignored). Then it
creates the Snowflake secret and points the egress rule at the new host. You'll only ever
see the host and `****` plus the last 4 characters of the password.

> Load the retail data into Postgres and create the CDC publication.

**Checkpoint P:** the loader prints row counts for 5 tables in the `bronze` schema
(`sales_transactions`, `daily_reviews`, `product_reviews`, `customer_comments`, `inventory_feed`,
with JSONB metadata and PostGIS warehouse locations). It also lists the tables in the
`openflow_retail_pub` publication.

> **Why it matters.** OLTP and analytics share one platform and one security perimeter. CDC
> never has to cross clouds or reach an external database.

---

### Act 3: Stream it in (Openflow CDC to Iceberg)

*Check in on Act 1:*

> Is the SPCS_SOM deployment ACTIVE yet?

Once it shows ACTIVE, ask for the connector. You don't ask for a runtime: CoCo works out that the
connector needs one, sees there isn't one yet, and creates `POSTGRES_RUNTIME_SOM` first (a SMALL,
single-node Gen2 runtime running as `POSTGRES_INGEST_SERVICE_ROLE` with the Postgres EAI, plus the
suspend/resume cost-control tasks). It waits for the runtime to be ACTIVE (~4 min), then builds the connector.

Pick **one** path; both build the same `POSTGRES_INGEST` connector.

#### Option A (default): connector as code, via SQL

> Create the POSTGRES_INGEST PostgreSQL CDC connector with SQL, not the wizard: replicate the bronze
> schema from RETAIL_HOL_PG into RETAIL_HOL_ICEBERG as Iceberg v3 tables, commit the configuration,
> and start it.

CoCo first creates the runtime (see above), then runs `scripts/configure_connector.py`. The script:
1. Creates the connector from its catalog definition: `CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC`.
2. Downloads its live `config.json` and fills in the source URL, a **secret reference** for the
   password, the publication, the 5 tables and the Iceberg destination.
3. Uploads the PostgreSQL JDBC driver next to it.
4. Runs `COMMIT`, then `START`, and prints exactly which keys it changed.

The password never appears in the file. Open `connector/config.json` afterwards to see the
"connector as code" for yourself.

#### Option B: the guided setup wizard (Snowsight)

Prefer clicking through a UI? Ask CoCo for your values first:

> I want to use the Openflow setup wizard instead of SQL. Get whatever the connector needs ready, then give me the exact values to enter for POSTGRES_INGEST.

> **Important: switch your Snowsight role to `OPENFLOW_ADMIN` first.** Click your name (top right) ->
> **Switch role** -> **`OPENFLOW_ADMIN`**. The Openflow wizard, the installed connector and the
> **Connector Observability** dashboard (Act 4) only show up under that role. If it isn't in the list,
> see Troubleshooting.

Then in Snowsight:
1. **Ingestion -> Openflow -> Launch Openflow** (role: **`OPENFLOW_ADMIN`**).
2. Open the **Connector library** tab and find **PostgreSQL CDC** (it's marked **gen 2**). Pick runtime
   **`POSTGRES_RUNTIME_SOM`**, then select **Install** and name it **`POSTGRES_INGEST`**.
   If you're prompted, **Allow** the Openflow data plane to access your account.
3. Fill in each wizard step. Select **Verify** on each step to test it; only the final check has to pass.

   | Step | Field | Value |
   |---|---|---|
   | Source | Source Database Connection URL | `jdbc:postgresql://<your host>:5432/postgres` (host printed by `setup_postgres.py`) |
   | | Source Database Driver | upload `postgresql-42.7.5.jar` from [jdbc.postgresql.org](https://jdbc.postgresql.org/download/) |
   | | Source Database User | `snowflake_admin` |
   | | Source Database Password | secret `RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD` |
   | | Publication Name | `openflow_retail_pub` |
   | Replication tables | | **Manual**: tick only schema `bronze` (all 5 tables); untick `public` |
   | Replication columns | | keep all columns; leave "include newly added columns" on |
   | Destination | Destination Database | `RETAIL_HOL_ICEBERG` |
   | | Warehouse | `RETAIL_HOL_WH` |
   | | Destination Schema Strategy | keep the source schema name (lands in `BRONZE`) |
   | | Object Identifier Resolution | Case Insensitive |
   | | Oversized Value Strategy | Set Null |
   | | Table Storage Format / Iceberg Version | Iceberg / 3 |
   | Tuning, Migration | | keep the defaults (merge every minute; ingestion type Full) |

4. Select **Create Connector**. On **Installed Connectors**, open the connector's menu and select **Start**.

> **Tip:** to change it later, use **Installed Connectors -> Edit**. The runtime canvas is read-only for
> wizard connectors.

> Show me the Bronze Iceberg tables Openflow created, and compare their row counts with Postgres.

**Checkpoint C:** 5 Iceberg tables in `RETAIL_HOL_ICEBERG.BRONZE`, and their counts match the loader.

> **Why it matters.** This is CDC without a third-party engine: the Openflow runtime is
> Snowflake-managed SPCS compute running inside your account. The connector's configuration is
> code (a versioned `config.json` with commit and abort), so you can template it for a whole
> fleet of connectors. Data lands as **open Iceberg** from the very first byte.

---

### Act 4: Watch it flow (Openflow observability)

*The pipeline is live. Now see it the way an operator would.*

> Set up observability for the Openflow pipeline: make sure the dedicated EVENTS event table is
> attached to SPCS_SOM, give RETAIL_HOL_ROLE read access, cluster it for the dashboard, and show me
> whether telemetry is arriving and whether there are any errors or stuck FlowFiles.

CoCo runs `solutions/04b_observability.sql`. Then open the dashboard:

1. In Snowsight, **switch your role to `OPENFLOW_ADMIN`** (your name, top right -> **Switch role**). Under other roles
   the connector doesn't appear on the dashboard.
2. **Ingestion -> Openflow -> Connector Observability**.
3. Set **Event table** to `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS` and the time frame to **Last Hour**.
4. Find `POSTGRES_INGEST`. You'll see its status (**Healthy**/**Unhealthy**), throughput and data ingested.
5. Open the connector's menu and select **View Details**. Each of the 5 tables shows its **replication phase**
   (New -> Snapshot Load -> Incremental Replication), its status and **Last Ingested**.

Now prove it's live CDC, not a one-time copy. Turn the store on:

> Start the continuous data generator in the background so the store keeps trading, and show me Bronze keeping up.

CoCo runs `scripts/cdc_demo.py --continuous` in the background. Every 5 seconds it inserts sales and a
product review into Postgres and updates an inventory level (an `UPDATE`, not just new rows). Every
30 seconds it prints how many sales rows are in Postgres versus Bronze. It runs for 20 minutes or until
you ask CoCo to stop it. On the dashboard, throughput climbs and **Last Ingested** keeps moving.

*Measure it.* The PostgreSQL connector reports its own latency into the event table, **once every 60 seconds and
only while data flows**. CoCo answers right away with whatever reports exist (even just one); ask again later
for a fuller picture:

> How fast is it? Show me end-to-end CDC latency per table, and where the time goes between capture and merge.

| Metric | Measures |
|---|---|
| `db.commit.to.capture.latency` | Postgres COMMIT -> connector read the change |
| `db.capture.to.journal.latency` | connector read -> journal table in Snowflake |
| `db.commit.to.merge.latency` | Postgres COMMIT -> merged into the Bronze table (end to end, per table) |

Chart query 9 in Snowsight (minute on X, latency on Y) to see the latency line while the generator runs.

*Break it on purpose.* An operator needs to know when a table stops replicating, without watching a dashboard:

To receive email alerts, add your email to your profile and verify it.
1. In Snowsight, **select your user profile at the bottom left of the screen** 
2. Click on **Settings**.
3. Enter your email address in the profile. You will get a verification email.
4. Verify your email before you ask Coco to create the alert.

> Create an alert that fires when any table in POSTGRES_INGEST fails replication. Then break one table on purpose so I can see it fire.

You don't write the alert logic. Snowflake ships **Openflow alert templates**, and CoCo creates
`POSTGRES_INGEST_TABLE_FAILURE_ALERT` from the built-in **Table replication failure alert (Gen2)** template
(`CREATE ALERT ... FROM TEMPLATE OPENFLOW_GEN2_TABLE_REPLICATION_FAILURE`), setting only the scope (the
`POSTGRES_INGEST` connector), a 1-minute schedule and in-app notification. Then it runs `scripts/fail_replication.py --break`, which adds a new
Postgres table **without a primary key** (`bronze.pos_events`) to replication. Within about 2 minutes:
- `pos_events` shows **failed** (`4008 MISSING_PRIMARY_KEYS`) in the dashboard's **View Details**.
  If the connector shows **Unhealthy**, try **Troubleshoot** for the AI root cause.
- The alert fires: it shows **TRIGGERED** in its alert history (CoCo shows it) and in Snowsight **Monitoring -> Alerts**.
  The in-app notification goes to the user who created the alert (`VHOLuser`), so check the history rather than
  waiting for a pop-up in your Snowsight session.
- The other 5 tables keep replicating. A failure is isolated to one table.

> Fix the broken table.

CoCo runs `scripts/fail_replication.py --fix` in the background, which removes `pos_events` from replication and
**suspends the alert**. The template looks back a whole hour, so it would otherwise keep firing on the old failure.
The connector restarts on its own in about a minute, so you can carry straight on to Act 5.

Prefer clicking? It's the same template in Snowsight: **Monitoring -> Alerts -> + Alert -> OPENFLOW** ->
**Table replication failure alert (Gen2)**. Pick email or webhook there if you have a notification integration.

**Checkpoint O:** the connector is **Healthy** again, the 5 lab tables are in **Incremental Replication**, Bronze kept
up with the generator, the latency query returns rows, and the alert TRIGGERED for the `pos_events` failure.

> **Why it matters.** Openflow writes its logs and metrics to an event table you own, so health is
> both a dashboard and plain SQL you can alert on. Latency is measured by the connector itself, from
> source commit to Bronze, so you can put a number on "real time". When a table fails, an alert tells
> you, the failure stays isolated to that table, and **Troubleshoot** gives an AI root-cause analysis
> built from the same telemetry.

---

### Act 5: Make it make sense (Silver + Gold with built-in AI)

> Build the Silver layer as Dynamic Iceberg Tables: unpivot sales by region, flatten the inventory
> JSON with stock health and warehouse coordinates, and enrich product reviews with Cortex
> sentiment and theme classification.

> Show me the negative reviews with their AI sentiment and theme.

> Build the Gold layer: daily product performance, customer voice analytics with AI summaries
> and intent, and a weekly product scorecard, with frozen regions so history isn't re-processed.

**Checkpoints S and G:** 6 Dynamic Iceberg Tables, all `is_iceberg = true` and `ADAPTIVE`, and
the Gold tables have frozen regions (`immutable_where`).

> **Why it matters.** The data stays in an open format with zero setup: Snowflake-managed Iceberg
> needs no external volume, catalog or IAM. **ADAPTIVE** refresh processes only changed rows, and
> **FROZEN WHERE** stops you paying to re-aggregate history. Sentiment, classification and
> summarization run as plain SQL functions inside the pipeline, so there are no external model calls.

---

### Act 6: Ask it anything

> Create the RETAIL_PRODUCT_INTELLIGENCE semantic view over the Gold tables, then the
> RETAIL_ANALYST_AGENT Cortex Agent that uses it, and publish it to Snowflake CoWork.

CoCo publishes the agent to CoWork with SQL as ACCOUNTADMIN (`ALTER SNOWFLAKE INTELLIGENCE ... ADD AGENT`), because
adding agents to CoWork needs the MODIFY privilege that only ACCOUNTADMIN has by default.

Now ask the questions from the start of the story:

> Ask the agent, as the Merchandiser: what are the top 3 and bottom 3 products by total units
> sold, with their positive review percentage?

> As the Supply Chain Planner: which products are most overstocked relative to their sales, which
> warehouse city holds them, and where should we rebalance?

> As the CX Lead: which products have the worst customer sentiment, and what are customers complaining about by intent type?

> As the VP of Retail: give me a weekly business review and flag products declining over the last 4 weeks.

Now hand it to the business users. In Snowsight:
1. Go to **AI** (or **AI & ML**) **-> Agent Studio** and open **`RETAIL_ANALYST_AGENT`**. CoCo already published it to
   CoWork, so you don't need **+ Add to Snowflake CoWork**. (On a fresh event account that button is greyed out for every
   role, *"You do not have MODIFY privilege"*, until CoCo's SQL has created the CoWork object.)
2. On the **Preview** tab, select **Preview in Snowflake CoWork** (top right), pick **Retail Analyst Agent**, and
   ask it the persona questions in plain English.

There are 20+ more questions in
`.snowflake/cortex/skills/openflow-retail-vhol/references/agent_spec.md`.

> **Why it matters.** The agent writes the SQL for you. One semantic model serves four personas,
> and a budget caps the cost of every answer. The data it reads is the same open Iceberg data a
> Spark or Trino job could query. Each layer, from an insert into Postgres to a business answer,
> was governed end to end on one platform.

---

### Act 7: Clean up

> Clean up everything this lab created.

CoCo asks you to confirm, then runs `solutions/99_cleanup.sql`. It stops the connector,
terminates the runtime and deployment, and drops the Postgres instance, databases, warehouse
and roles. To remove the `VHOLuser` login, use the teardown block in `00_bootstrap.sql` from
Snowsight. You can't do it from CoCo, because CoCo is logged in as that user.

## How the skill knows all this

You typed plain-English prompts, yet everyone's objects came out identical. That consistency comes
from the **`openflow-retail-vhol` skill** (`.snowflake/cortex/skills/openflow-retail-vhol/`).
You added it in setup step 5 (CoCo can also auto-discover it when you open this folder):

- **`SKILL.md`** holds the object model (exact names and settings), the workflow, the checkpoints,
  the secret-handling rules and the "why it matters" lines.
- **`references/object_model.md`** points each part to its verbatim DDL in `solutions/`.
- **`references/connector_config.md`** describes the SQL connector workflow
  (`CREATE OPENFLOW CONNECTOR ... FROM DEFINITION` -> GET/PUT `config.json` -> COMMIT -> START),
  maps each value, and includes a wizard fallback.
- **`references/agent_spec.md`** covers the agent settings and the persona question bank.

### Build your own skill

A skill is a folder containing a `SKILL.md` (YAML front matter with `name` and `description`, then
markdown instructions), plus optional `references/`. Commit it with your repo and it auto-loads
for anyone who opens the project in CoCo Desktop. This skill makes a working template for
encoding your own team's Openflow and pipeline conventions.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deployment stuck in CREATING | It usually takes ~15 min. If it fails and mentions terms of service, an ORGADMIN must accept the Openflow terms once. |
| Loader can't connect to Postgres | Check that the instance is READY and that `pg_creds.json` has the right host. |
| `setup_postgres.py`: instance exists but pg_creds.json is missing | The one-time password is lost. Drop `RETAIL_HOL_PG` (or reset its `snowflake_admin` credentials) and re-run. |
| `USE ROLE not allowed` / `Current session is restricted` | Your PAT was created with `ROLE_RESTRICTION`, which pins the session to one role. In Snowsight, run `ALTER USER VHOLuser REMOVE PROGRAMMATIC ACCESS TOKEN vhol_pat;`, re-run Block 1 (no role restriction), and update the token in `secret.pat` and the CoCo connection. |
| Agent says "I've reached the time limit" | The budget is 120 s / 32,000 tokens per answer. Ask a narrower question, or say "continue". |
| Connector commit/validation error | Ask CoCo to read the error, fix the named key in `config.json`, re-upload and commit again. |
| Connector running but Bronze is empty | Ask CoCo to "show recent Openflow errors from the event table". The usual causes are an egress rule still set to the placeholder host (`example.com:5432`), or the secret not granted to `POSTGRES_INGEST_SERVICE_ROLE`. |
| SQL connector config is blocked | Use **Option B (wizard)** in Act 3. Everything else stays the same. |
| Connector missing from the dashboard | Select event table `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS` and **Last Hour**. Connectors only appear once they've emitted telemetry in that window. |
| Alert didn't fire after `--break` | Allow ~3 min (60 s metric + 1 min schedule). Check the alert is resumed (`SHOW ALERTS IN SCHEMA OPENFLOW_DB.OPENFLOW_SCHEMA`) and run query 11 in `04b_observability.sql` for `pos_events`. If ALERT_HISTORY shows *"EXECUTE ALERT privilege must be granted to owner role"* or *"No Openflow connectors visible for scope"*, re-run the alert block in `04b` (it grants OPENFLOW_ADMIN what it needs). |
| *"You do not have MODIFY privilege to add agents to Snowflake CoWork"* | Adding to CoWork needs MODIFY on the CoWork object (ACCOUNTADMIN only by default). On event accounts the CoWork object doesn't exist yet, so the button is greyed out for every role, even ACCOUNTADMIN. Ask CoCo to run the CoWork block at the end of `08_agent.sql`: it creates the object, adds the agent and grants `RETAIL_HOL_ROLE` MODIFY so the button works afterwards. |
| Add Local Skill: "No valid skills found ... Directory was NOT persisted" | You picked the repo root. Pick `openflow-vhol/.snowflake/cortex/skills` instead (macOS: **Cmd+Shift+. (period)** shows hidden folders). |
| `SNOWFLAKE.CORTEX.SENTIMENT` (or `CLASSIFY_TEXT`, `SUMMARIZE`) is blocked | New accounts can't use the legacy `SNOWFLAKE.CORTEX.*` functions. The lab already uses `AI_SENTIMENT`, `AI_CLASSIFY` and `AI_SUMMARIZE`; make sure CoCo runs `05_silver.sql` / `06_gold.sql` as written. |
| `OPENFLOW_ADMIN` missing from the Snowsight role switcher | Snowsight is logged in as the event admin user, not `VHOLuser`. Ask CoCo to run `GRANT ROLE OPENFLOW_ADMIN TO ROLE SYSADMIN;` (already in `02_openflow_deployment.sql` for new runs), then refresh Snowsight. |
| *"Authentication token has expired"* | The login session expired after a long or idle lab (your PAT is still valid). CoCo retries once; if it persists, re-select the VHOLuser connection in CoCo Desktop -> **Connections** or start a new chat. |
| *"No active warehouse selected"* | Ask CoCo to `USE WAREHOUSE RETAIL_HOL_WH` and retry. New runs set it as VHOLuser's default warehouse in Act 1. |
| Agent "not an allowed model" | The spec already uses `orchestration: auto`. Pick a model in Snowsight -> Agent -> Configuration. |

## Credits

Adapted from the *AI-Ready Data Pipeline* retail hands-on lab notebooks (in `notebooks/`) for a
prompt-driven, CoCo Desktop format.
