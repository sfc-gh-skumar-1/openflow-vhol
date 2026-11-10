-- Openflow Retail VHOL — Act 1a: Base environment (replaces the pre-provisioned DataOps objects)
-- Run as ACCOUNTADMIN. Safe to re-run.
USE ROLE ACCOUNTADMIN;

-- Data role + warehouse
CREATE ROLE IF NOT EXISTS RETAIL_HOL_ROLE COMMENT = 'Retail HOL data role (Postgres, Silver/Gold, agent)';
GRANT ROLE RETAIL_HOL_ROLE TO ROLE SYSADMIN;
SET MY_USER = CURRENT_USER();
GRANT ROLE RETAIL_HOL_ROLE TO USER IDENTIFIER($MY_USER);

CREATE WAREHOUSE IF NOT EXISTS RETAIL_HOL_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Retail HOL warehouse';
GRANT USAGE, OPERATE ON WAREHOUSE RETAIL_HOL_WH TO ROLE RETAIL_HOL_ROLE;
-- Give the lab user a default warehouse, so every new session (CoCo reconnects, helper scripts) can run
-- queries that need compute without a USE WAREHOUSE first ("No active warehouse selected").
ALTER USER IDENTIFIER($MY_USER) SET DEFAULT_WAREHOUSE = RETAIL_HOL_WH;

-- Admin DB: secrets + network rules
CREATE DATABASE IF NOT EXISTS RETAIL_HOL_ADMIN COMMENT = 'Retail HOL admin objects (secrets, network)';
CREATE SCHEMA IF NOT EXISTS RETAIL_HOL_ADMIN.SECRETS;
CREATE SCHEMA IF NOT EXISTS RETAIL_HOL_ADMIN.NETWORK;
GRANT USAGE ON DATABASE RETAIL_HOL_ADMIN TO ROLE RETAIL_HOL_ROLE;
GRANT USAGE ON SCHEMA RETAIL_HOL_ADMIN.SECRETS TO ROLE RETAIL_HOL_ROLE;

-- Destination DB: Snowflake-managed Iceberg by default (no external volume / catalog setup)
CREATE DATABASE IF NOT EXISTS RETAIL_HOL_ICEBERG
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'SNOWFLAKE_MANAGED'
  COMMENT = 'Retail HOL: Bronze (CDC) + Silver/Gold Dynamic Iceberg Tables';
GRANT USAGE, CREATE SCHEMA ON DATABASE RETAIL_HOL_ICEBERG TO ROLE RETAIL_HOL_ROLE;

-- Postgres instance network policy (lab-only: open ingress so CoCo Desktop's laptop can load data)
CREATE NETWORK RULE IF NOT EXISTS RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_INGRESS_RULE
  TYPE = IPV4 MODE = POSTGRES_INGRESS VALUE_LIST = ('0.0.0.0/0');
CREATE NETWORK POLICY IF NOT EXISTS RETAIL_HOL_NETWORK_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_INGRESS_RULE')
  COMMENT = 'Retail HOL Postgres instance access (lab only)';
GRANT USAGE ON NETWORK POLICY RETAIL_HOL_NETWORK_POLICY TO ROLE RETAIL_HOL_ROLE;

-- Egress rule + EAI used by the Openflow runtime to reach Postgres.
-- Placeholder host; updated with the real instance host in Act 2 (setup_postgres.py).
-- Must be a resolvable hostname: Snowflake rejects unresolvable hosts such as 'placeholder.invalid'
-- ("One or more values might be an unresolvable host name"). example.com is inert and gets replaced.
CREATE NETWORK RULE IF NOT EXISTS RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE
  TYPE = HOST_PORT MODE = EGRESS VALUE_LIST = ('example.com:5432');
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS RETAIL_HOL_POSTGRES_EAI
  ALLOWED_NETWORK_RULES = (RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE)
  ENABLED = TRUE
  COMMENT = 'Openflow runtime egress to Snowflake Managed Postgres';
GRANT USAGE ON INTEGRATION RETAIL_HOL_POSTGRES_EAI TO ROLE RETAIL_HOL_ROLE;

-- Postgres instance creation privilege for the data role
GRANT CREATE POSTGRES INSTANCE ON ACCOUNT TO ROLE RETAIL_HOL_ROLE;

-- Cortex AI functions + agents
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE RETAIL_HOL_ROLE;
