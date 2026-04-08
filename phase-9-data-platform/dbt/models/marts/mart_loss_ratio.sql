-- mart_loss_ratio.sql
-- Weekly loss ratio: total approved claims / total premiums collected.
-- This is the number Amara used to calculate manually every Monday in Excel.
-- Formula: Loss Ratio = Claims Paid / Premiums Earned

with claims as (
    select
        week_start,
        sum(claim_amount) as total_claims_amount,
        count(*)          as total_claims
    from {{ ref('stg_claims') }}
    where claim_status = 'approved'
    group by week_start
),

members as (
    select
        sum(premium_monthly) as total_monthly_premiums,
        count(*)             as active_members
    from {{ ref('stg_members') }}
    where is_active = true
),

final as (
    select
        c.week_start,
        c.total_claims_amount,
        c.total_claims,
        m.total_monthly_premiums                                        as total_premiums,
        m.active_members,
        round(
            safe_divide(c.total_claims_amount, m.total_monthly_premiums),
            4
        )                                                               as loss_ratio,
        current_timestamp()                                             as calculated_at

    from claims c
    cross join members m
)

select * from final
order by week_start desc
