with claims as (
    select * from {{ ref('claims_clean') }}
),

member_stats as (
    select
        member_id,
        count(*)                    as total_claims_30d,
        sum(claim_amount)           as total_amount_30d,
        avg(claim_amount)           as avg_amount_30d,
        countif(status = 'pending') as pending_count

    from claims
    where claim_date >= date_sub(current_date(), interval 30 day)
    group by member_id
),

signals as (
    select
        member_id,
        total_claims_30d,
        total_amount_30d,
        avg_amount_30d,
        pending_count,
        case
            when total_claims_30d > 10 then true
            when total_amount_30d  > 20000 then true
            when pending_count     > 5 then true
            else false
        end as is_flagged

    from member_stats
)

select * from signals
