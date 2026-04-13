with salaries as (
    select * from {{ ref('stg_salaries') }}
),

players as (
    select * from {{ ref('stg_players') }}
),

teams as (
    select * from {{ ref('stg_teams') }}
),

final as (
    select
        s.player_id,
        p.full_name,
        p.position,
        p.position_abbreviation,
        s.year,
        s.salary,
        s.salary_millions,
        t.team_name,
        t.league,
        t.division,
        -- Add some derived fields
        case
            when p.position = 'Pitcher' then true
            else false
        end as is_pitcher,
        -- Date column required for MetricFlow time dimension
        date_from_parts(s.year::int, 1, 1) as season_date
    from salaries s
    left join players p
        on s.player_id = p.player_id
    left join teams t
        on s.team_id = t.team_id
)

select * from final 