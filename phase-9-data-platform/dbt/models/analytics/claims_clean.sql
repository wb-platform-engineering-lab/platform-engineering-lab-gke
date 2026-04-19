with staged as (
    select * from {{ ref('stg_claims') }}
),

deduplicated as (
    select *,
        row_number() over (
            partition by claim_id
            order by created_at_ts desc
        ) as row_num
    from staged
),

final as (
    select
        claim_id,
        member_id,
        claim_amount,
        description,
        status,
        claim_date,
        created_at_ts,
        case
            when claim_amount > 5000 then 'high'
            when claim_amount > 1000 then 'medium'
            else 'low'
        end as amount_tier

    from deduplicated
    where row_num = 1
)

select * from final
