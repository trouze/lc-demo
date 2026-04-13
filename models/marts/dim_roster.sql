with players as (
    select * from {{ ref('stg_players') }}
),

teams as (
    select * from {{ ref('stg_teams') }}
),

final as (
    select
        p.player_id,
        p.full_name,
        p.position,
        p.position_abbreviation,
        p.birth_date,
        p.height,
        p.weight,
        p.throws,
        p.bats,
        t.team_name,
        t.city as team_city,
        t.state as team_state,
        t.league,
        t.division,
        -- Add some derived fields
        date_part('year', current_date()) - date_part('year', p.birth_date) as age,
        case 
            when p.position = 'Pitcher' then true
            else false
        end as is_pitcher
    from players p
    left join teams t
        on t.team_id = 'TEAM1'  -- For this example, we're only showing TEAM1
)

select * from final 