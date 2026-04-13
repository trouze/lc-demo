with game_stats as (
    select * from {{ ref('stg_game_stats') }}
),

players as (
    select * from {{ ref('stg_players') }}
),

salaries as (
    select * from {{ ref('stg_salaries') }}
),

-- Calculate player performance metrics
player_performance as (
    select
        gs.player_id,
        p.full_name,
        p.position,
        date_part('year', gs.game_date) as year,
        -- Batting performance
        sum(gs.at_bats) as total_at_bats,
        sum(gs.hits) as total_hits,
        sum(gs.home_runs) as total_home_runs,
        sum(gs.rbi) as total_rbi,
        sum(gs.stolen_bases) as total_stolen_bases,
        sum(gs.walks) as total_walks,
        sum(gs.strikeouts) as total_strikeouts,
        -- Pitching performance
        sum(gs.innings_pitched) as total_innings_pitched,
        sum(gs.earned_runs) as total_earned_runs,
        sum(gs.strikeouts_pitched) as total_strikeouts_pitched,
        sum(gs.win) as total_wins,
        sum(gs.loss) as total_losses,
        sum(gs.save) as total_saves,
        -- Calculate advanced metrics
        case 
            when sum(gs.at_bats) > 0 
            then (sum(gs.hits)::float / COALESCE(sum(gs.at_bats), 1))::int
            else null
        end as batting_average,
        case 
            when sum(gs.innings_pitched) > 0 
            then (sum(gs.earned_runs)::float * 9 / COALESCE(sum(gs.innings_pitched), 1))::int
            else null
        end as era
    from game_stats gs
    inner join players p
        on gs.player_id = p.player_id
    group by gs.player_id, p.full_name, p.position, date_part('year', gs.game_date)
),

-- Calculate league averages for comparison
league_averages as (
    select
        year,
        position,
        avg(batting_average) as league_avg_batting,
        avg(era) as league_avg_era,
        avg(total_home_runs) as league_avg_home_runs,
        avg(total_rbi) as league_avg_rbi,
        avg(total_stolen_bases) as league_avg_stolen_bases,
        avg(total_wins) as league_avg_wins,
        avg(total_saves) as league_avg_saves
    from player_performance
    group by year, position
)

-- Calculate final value metrics
select
    pp.*,
    s.salary,
    s.salary_millions,
    la.league_avg_batting,
    la.league_avg_era,
    la.league_avg_home_runs,
    la.league_avg_rbi,
    la.league_avg_stolen_bases,
    la.league_avg_wins,
    la.league_avg_saves,
    -- Calculate performance vs league average
    case 
        when pp.batting_average is not null 
        then ((pp.batting_average - la.league_avg_batting) / (la.league_avg_batting * 100 + 1))::int
        else null
    end as batting_avg_vs_league_pct,
    case 
        when pp.era is not null 
        then ((la.league_avg_era - pp.era) / (la.league_avg_era * 100 + 1))::int
        else null
    end as era_vs_league_pct,
    -- Calculate value scores
    case 
        when pp.position = 'Pitcher' and pp.total_wins > 0 
        then (s.salary::float / (pp.total_wins + 1))::int
        when pp.position != 'Pitcher' and pp.total_home_runs > 0 
        then (s.salary::float / (pp.total_home_runs + 1))::int
        else null
    end as cost_per_primary_stat,
    -- Calculate overall value score (higher is better)
    case 
        when pp.position = 'Pitcher' then
            (
                (pp.total_wins * 3) + 
                (pp.total_saves * 2) + 
                (pp.total_strikeouts_pitched * 0.1) - 
                (pp.total_earned_runs * 2)
            )::int
        else
            (
                (pp.total_home_runs * 4) + 
                (pp.total_rbi * 3) + 
                (pp.total_stolen_bases * 2) + 
                (pp.total_hits * 1)
            )::int
    end as value_score,
    -- Calculate value efficiency (value score per million dollars)
    case 
        when s.salary_millions > 0 
        then (value_score::float / s.salary_millions)::int
        else null
    end as value_efficiency
from player_performance pp
left join salaries s
    on pp.player_id = s.player_id
    and pp.year = s.year
left join league_averages la
    on pp.year = la.year
    and pp.position = la.position
order by pp.year desc, value_efficiency desc 