with source as (
    select * from {{ source('dugout', 'raw_players') }}
),

renamed as (
    select
        player_id,
        first_name,
        last_name,
        position,
        birth_date,
        height,
        weight,
        throws,
        bats,
        -- Add some basic transformations
        concat(first_name, ' ', last_name) as full_name,
        case 
            when position = 'Pitcher' then 'P'
            when position = 'Catcher' then 'C'
            when position = 'First Base' then '1B'
            when position = 'Second Base' then '2B'
            when position = 'Third Base' then '3B'
            when position = 'Shortstop' then 'SS'
            when position = 'Left Field' then 'LF'
            when position = 'Center Field' then 'CF'
            when position = 'Right Field' then 'RF'
            else position
        end as position_abbreviation
    from source
)

select * from renamed 