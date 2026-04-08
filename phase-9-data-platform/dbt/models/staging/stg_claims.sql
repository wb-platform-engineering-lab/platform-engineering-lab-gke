-- stg_claims.sql
-- Clean and validate raw claims data.
-- Catches the wrong WHERE clause that broke Amara's report for 3 weeks.

with source as (
    select * from {{ source('coverline_raw', 'raw_claims') }}
),

cleaned as (
    select
        id                                          as claim_id,
        member_id,
        cast(amount as numeric)                     as claim_amount,
        lower(trim(status))                         as claim_status,
        description,
        timestamp(created_at)                       as claimed_at,
        timestamp(updated_at)                       as updated_at,
        date(_loaded_at)                            as loaded_date,
        _week_start                                 as week_start

    from source

    -- Only include valid, processable claims
    where claim_status in ('approved', 'pending', 'rejected')
      and claim_amount > 0
      and claim_amount < 1000000  -- sanity cap: claims over 1M are data errors
)

select * from cleaned
