with game_stats as (
    select * from {{ ref('stg_game_stats') }}
),

players as (
    select * from {{ ref('stg_players') }}
    where position = 'Pitcher'
),

-- Calculate basic game stats for pitchers
pitcher_games as (
    select
        gs.player_id,
        p.full_name,
        gs.game_date,
        -- Basic stats
        gs.innings_pitched,
        gs.earned_runs,
        gs.hits_allowed,
        gs.walks_allowed,
        gs.strikeouts_pitched,
        gs.win,
        gs.loss,
        gs.save,
        -- Calculate advanced metrics
        case 
            when gs.innings_pitched > 0 
            then ((gs.strikeouts_pitched::float / gs.innings_pitched) * 9)::int
            else null
        end as k_per_9,
        case 
            when gs.innings_pitched > 0 
            then ((gs.walks_allowed::float / gs.innings_pitched) * 9)::int
            else null
        end as bb_per_9,
        case 
            when gs.innings_pitched > 0 
            then ((gs.hits_allowed::float / gs.innings_pitched) * 9)::int
            else null
        end as h_per_9,
        -- Calculate quality start (6+ innings, 3 or fewer earned runs)
        case 
            when gs.innings_pitched >= 6 and gs.earned_runs <= 3 then 1
            else 0
        end as quality_start,
        -- Calculate game score (Bill James metric)
        case 
            when gs.innings_pitched > 0 then
                50 + 
                (gs.innings_pitched * 2) + 
                (gs.strikeouts_pitched) - 
                (gs.hits_allowed * 2) - 
                (gs.walks_allowed * 2) - 
                (gs.earned_runs * 4)
            else null
        end as game_score
    from game_stats gs
    inner join players p
        on gs.player_id = p.player_id
    where gs.innings_pitched > 0
),

-- Calculate season totals
season_stats as (
    select
        player_id,
        date_part('year', game_date) as year,
        sum(innings_pitched) as season_innings,
        sum(earned_runs) as season_earned_runs,
        sum(strikeouts_pitched) as season_strikeouts,
        sum(quality_start) as season_quality_starts,
        case 
            when sum(innings_pitched) > 0 
            then ((sum(earned_runs)::float * 9 / sum(innings_pitched)))::int
            else null
        end as season_era
    from pitcher_games
    group by player_id, date_part('year', game_date)
)

select
    pg.*,
    ss.season_innings,
    ss.season_earned_runs,
    ss.season_strikeouts,
    ss.season_quality_starts,
    ss.season_era
from pitcher_games pg
left join season_stats ss
    on pg.player_id = ss.player_id
    and date_part('year', pg.game_date) = ss.year
order by pg.game_date desc, pg.game_score desc 