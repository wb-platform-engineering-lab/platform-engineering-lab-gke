with source as (
    select * from {{ source('raw', 'claims') }}
),

cleaned as (
    select
        cast(id as int64)           as claim_id,
        member_id,
        cast(amount as numeric)     as claim_amount,
        lower(trim(description))    as description,
        lower(status)               as status,
        date(created_at)            as claim_date,
        created_at                  as created_at_ts

    from source
    where id is not null
      and amount > 0
)

select * from cleaned
