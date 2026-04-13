with source as (
    select * from {{ source('dugout', 'raw_game_stats') }}
),

renamed as (
    select
        game_id,
        player_id,
        game_date,
        opponent_team_id,
        -- Batting stats
        at_bats,
        hits,
        runs,
        home_runs,
        rbi,
        stolen_bases,
        walks,
        strikeouts,
        -- Pitching stats
        innings_pitched,
        earned_runs,
        hits_allowed,
        walks_allowed,
        strikeouts_pitched,
        win,
        loss,
        save,
        -- Derived metrics
        case 
            when at_bats > 0 then (hits::float / at_bats)::int
            else null
        end as batting_average,
        case 
            when at_bats > 0 then ((hits + walks)::float / (at_bats + walks))::int
            else null
        end as on_base_percentage,
        case 
            when innings_pitched > 0 then (earned_runs::float * 9 / innings_pitched)::int
            else null
        end as era,
        case 
            when innings_pitched > 0 then ((hits_allowed + walks_allowed)::float * 9 / innings_pitched)::int
            else null
        end as whip
    from source
)

select * from renamed 