-- Openflow Retail VHOL — Act 6b Cortex Agent
-- Source: notebooks/04-retail-hol-talk-to-data.ipynb (verbatim DDL). Run as shown; safe to re-run.

USE ROLE RETAIL_HOL_ROLE;
USE WAREHOUSE RETAIL_HOL_WH;
USE DATABASE RETAIL_HOL_ICEBERG;
USE SCHEMA GOLD_MANAGED_ICEBERG;

-- Create the Retail Intelligence Agent
CREATE OR REPLACE AGENT RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT
  COMMENT = 'Retail product intelligence agent - ask questions about sales, inventory, sentiment, and warehouse locations'
  PROFILE = '{"display_name": "Retail Analyst Agent"}'
  FROM SPECIFICATION
  $$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 120
    tokens: 32000

instructions:
  response: >-
    You are a retail analytics expert for a candle and fragrance company.
    You help merchandising, supply chain, marketing, and executive teams
    answer questions about product performance, inventory health, customer sentiment,
    and warehouse geolocation. Always provide specific numbers and percentages,
    compare to benchmarks when relevant (e.g., 80%+ positive review rate is good),
    flag products that need attention (critical stock, declining sentiment),
    and suggest actionable next steps when appropriate.
  orchestration: >-
    For time-based questions, default to the most recent data available.
    For location questions, map coordinates to city names:
    Los Angeles (-118.24, 34.05), Houston (-95.37, 29.76),
    New York (-73.99, 40.75), Chicago (-87.63, 41.88),
    San Francisco (-122.42, 37.77).
    Product portfolio: Frosted Juniper, Citrus Petal, Golden Amberleaf, Harvest Thyme,
    Lavender Honeycomb, Lemon Verbena Grove, Meadow Bloom, Peachwood Breeze,
    Rainleaf, Sea Salt Blossom, Spiced Oak & Apple, Vanilla Cedarlight.
    Channels: Online, Northeast stores, Northwest stores, Southeast stores, Southwest stores.
    Warehouse Locations: Los Angeles, Houston, New York, Chicago, San Francisco.
  sample_questions:
    - question: "What are the top 3 and bottom 3 products by total units sold?"
    - question: "Which products had critical or low stock health status?"
    - question: "Show me inventory distribution by warehouse city."

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: retail_analyst
      description: >-
        Answers questions about retail product performance, inventory health,
        customer sentiment, and warehouse geolocation by querying the
        RETAIL_PRODUCT_INTELLIGENCE semantic view.

tool_resources:
  retail_analyst:
    semantic_view: RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_PRODUCT_INTELLIGENCE
    execution_environment:
      type: warehouse
      warehouse: RETAIL_HOL_WH
$$;

-- Verify the agent is created
SHOW AGENTS IN SCHEMA GOLD_MANAGED_ICEBERG;

-- Programmatic question (Q1)
-- Q1: Merchandising — Top and bottom performers
WITH raw AS (
  SELECT TRY_PARSE_JSON(
    SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
      'RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT',
      $${
        "messages": [
          {
            "role": "user",
            "content": [
              { "type": "text", "text": "What are the top 3 and bottom 3 products by total units sold? Include their positive review percentage." }
            ]
          }
        ]
      }$$,
      TRUE
    )
  ) AS resp
)
SELECT f.value:text::VARCHAR AS ANSWER
FROM raw, LATERAL FLATTEN(input => resp:content) f
WHERE f.value:type::VARCHAR = 'text';

-- Publish the agent to Snowflake CoWork (REQUIRED for Act 6; run as ACCOUNTADMIN).
-- Adding an agent to CoWork needs MODIFY on the account's CoWork object, which only ACCOUNTADMIN has by
-- default. Clicking "+ Add to Snowflake CoWork" in Agent Studio under RETAIL_HOL_ROLE / an attendee role fails
-- with "You do not have MODIFY privilege to add agents to Snowflake CoWork", so CoCo does it here instead.
USE ROLE ACCOUNTADMIN;
-- 1. Ensure the CoWork (Snowflake Intelligence) object exists. Event accounts don't have one yet, which is why
--    "+ Add to Snowflake CoWork" is greyed out for every role until this runs.
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

-- 2. Grant USAGE so the role can interact with the agent in CoWork
GRANT USAGE ON AGENT RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT
  TO ROLE RETAIL_HOL_ROLE;
  
-- 3. Add the agent to the CoWork object so it appears in the dropdown
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT;
-- If it says the agent is already added, that's fine (re-run).

-- 4. Let users see the CoWork agent list (no-op if already granted)
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE PUBLIC;

-- 5. Let the lab role manage CoWork agents itself (enables the Agent Studio "+ Add to Snowflake CoWork" button for it)
GRANT MODIFY ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE RETAIL_HOL_ROLE;

-- Checkpoint: the agent is published
SHOW AGENTS IN SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;
