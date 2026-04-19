-- This test fails (returns rows) if duplicates exist in the raw layer.
-- A DAG run that produces duplicates will fail here before touching analytics.
select
    claim_id,
    count(*) as occurrences
from {{ ref('stg_claims') }}
group by claim_id
having count(*) > 1
