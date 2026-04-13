with source as (
    select * from {{ source('dugout', 'raw_teams') }}
),

renamed as (
    select
        team_id,
        team_name,
        city,
        state,
        league,
        division,
        -- Add some basic transformations
        concat(city, ' ', team_name) as full_team_name,
        case 
            when league = 'National' then 'NL'
            when league = 'American' then 'AL'
            else league
        end as league_abbreviation
    from source
)

select * from renamed 