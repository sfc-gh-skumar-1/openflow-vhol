# Agent spec — RETAIL_ANALYST_AGENT

The agent DDL is verbatim in `solutions/08_agent.sql` (from notebook 04). Key settings:
- `models.orchestration: auto` (account-specific allowed-model lists make pinned models brittle)
- budget: 120 seconds, 32000 tokens
- `instructions.response`: retail analytics expert tone, specific numbers, flag risks, next steps
- `instructions.orchestration`: default to most recent data; map warehouse coordinates to city names
- tool: Cortex Analyst text-to-SQL over the `RETAIL_PRODUCT_INTELLIGENCE` semantic view

Dollar-quote the spec with plain `$$`. To change the agent, re-run the whole
`CREATE OR REPLACE AGENT ... FROM SPECIFICATION` statement.

> Data note (verified on a live run): the generated inventory is never CRITICAL or LOW, so the
> original notebook's stock-out question returns "none". The Supply Chain question below is about
> overstock instead, which tells the real story the data supports.

## The five lab questions (one per persona + an executive close)
| Persona | Question |
|---|---|
| Merchandiser | What are the top 3 and bottom 3 products by total units sold? Include their positive review percentage. |
| Supply Chain Planner | Which products are most overstocked relative to their sales, which warehouse city holds them, and where should we rebalance? |
| CX Lead | Show me the products with the worst customer sentiment. What are customers complaining about? Break down by intent type. |
| VP of Retail | Give me a weekly business review: total units sold per week, trending sentiment, and flag any products with declining performance over the last 4 weeks. |
| Operations | Is there a correlation between product quality score and customer sentiment? Show me products with quality below 90 and their average sentiment. |

Programmatic pattern (from the notebook):
```sql
WITH raw AS (
  SELECT TRY_PARSE_JSON(
    SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
      'RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT',
      $${"messages":[{"role":"user","content":[{"type":"text","text":"<question>"}]}]}$$,
      TRUE)) AS resp
)
SELECT f.value:text::VARCHAR AS ANSWER
FROM raw, LATERAL FLATTEN(input => resp:content) f
WHERE f.value:type::VARCHAR = 'text';
```

## More questions to explore (Snowflake CoWork)
Snowsight -> AI (or AI & ML) -> Agent Studio -> RETAIL_ANALYST_AGENT; CoCo publishes it to CoWork with SQL (ACCOUNTADMIN);
then use **Preview -> Preview in Snowflake CoWork** to chat there.
### Merchandising & Assortment
| # | Question |
|---|----------|
| 1 | Which products have the highest sell-through rate? |
| 2 | What products should I consider discontinuing based on low sales and poor sentiment? |
| 3 | Are there seasonal patterns — which products peak in Q4 vs Q1? |
| 4 | Compare Frosted Juniper to Vanilla Cedarlight across all KPIs |

### Supply Chain & Inventory
| # | Question |
|---|----------|
| 5 | What is the days-of-supply for each product based on current inventory and daily sales? |
| 6 | Which products are consistently overstocked? Can we reduce order quantities? |
| 7 | Show me inventory position vs sales velocity — who needs rebalancing? |
| 8 | Which supplier (based on quality score) delivers the most consistent quality? |

### Customer Experience & Sentiment
| # | Question |
|---|----------|
| 9 | What percentage of customer comments are complaints vs praise? |
| 10 | Which channel (web, social, email) has the most negative sentiment? |
| 11 | Show me the actual comment text for the most negative feedback this month |
| 12 | Are shipping complaints correlated with any specific product? |

### E-Commerce & Channel Strategy
| # | Question |
|---|----------|
| 13 | Which products have the fastest-growing online penetration? |
| 14 | Is there a product better suited for stores-only vs online-only? |
| 15 | What's the weekly trend in online mix percentage? |
| 16 | Compare online vs store performance for products with quality score > 95 |

### Executive & Strategic
| # | Question |
|---|----------|
| 17 | Give me a one-page summary: total units, top product, biggest risk, biggest opportunity |
| 18 | Which products improved sentiment month-over-month? |
| 19 | What's our overall review positivity rate and how does it trend? |
| 20 | Rank all 12 products by a composite score of sales + sentiment + quality |
