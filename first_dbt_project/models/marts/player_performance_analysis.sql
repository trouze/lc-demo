with game_stats as (
    select * from {{ ref('stg_game_stats') }}
),

players as (
    select * from {{ ref('stg_players') }}
),

salaries as (
    select * from {{ ref('stg_salaries') }}
),

-- Aggregate game stats by player and year
player_season_stats as (
    select
        player_id,
        date_part('year', game_date) as year,
        -- Batting stats
        sum(at_bats) as total_at_bats,
        sum(hits) as total_hits,
        sum(runs) as total_runs,
        sum(home_runs) as total_home_runs,
        sum(rbi) as total_rbi,
        sum(stolen_bases) as total_stolen_bases,
        sum(walks) as total_walks,
        sum(strikeouts) as total_strikeouts,
        -- Pitching stats
        sum(innings_pitched) as total_innings_pitched,
        sum(earned_runs) as total_earned_runs,
        sum(hits_allowed) as total_hits_allowed,
        sum(walks_allowed) as total_walks_allowed,
        sum(strikeouts_pitched) as total_strikeouts_pitched,
        sum(win) as total_wins,
        sum(loss) as total_losses,
        sum(save) as total_saves,
        -- Calculate averages
        case 
            when sum(at_bats) > 0 then (sum(hits)::float / sum(at_bats))::int
            else null
        end as season_batting_average,
        case 
            when sum(innings_pitched) > 0 then (sum(earned_runs)::float * 9 / sum(innings_pitched))::int
            else null
        end as season_era
    from game_stats
    group by player_id, date_part('year', game_date)
),

final as (
    select
        pss.player_id,
        p.full_name,
        p.position,
        pss.year,
        -- Performance metrics
        pss.total_at_bats,
        pss.total_hits,
        pss.total_runs,
        pss.total_home_runs,
        pss.total_rbi,
        pss.total_stolen_bases,
        pss.total_walks,
        pss.total_strikeouts,
        pss.total_innings_pitched,
        pss.total_earned_runs,
        pss.total_hits_allowed,
        pss.total_walks_allowed,
        pss.total_strikeouts_pitched,
        pss.total_wins,
        pss.total_losses,
        pss.total_saves,
        pss.season_batting_average,
        pss.season_era,
        -- Salary information
        s.salary,
        s.salary_millions,
        -- Performance per dollar metrics
        case 
            when s.salary > 0 and pss.total_hits > 0 
            then (s.salary::float / pss.total_hits)::int
            else null
        end as cost_per_hit,
        case 
            when s.salary > 0 and pss.total_home_runs > 0 
            then (s.salary::float / pss.total_home_runs)::int
            else null
        end as cost_per_home_run,
        case
            when s.salary > 0 and pss.total_wins > 0
            then (s.salary::float / pss.total_wins)::int
            else null
        end as cost_per_win,
        -- Date column required for MetricFlow time dimension
        date_from_parts(pss.year::int, 1, 1) as season_date
    from player_season_stats pss
    left join players p
        on pss.player_id = p.player_id
    left join salaries s
        on pss.player_id = s.player_id
        and pss.year = s.year
)

select * from final 