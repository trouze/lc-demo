with source as (
    select * from {{ source('dugout', 'raw_salaries') }}
),

renamed as (
    select
        player_id,
        year,
        salary,
        team_id,
        -- Add some basic transformations
        salary / 1000000 as salary_millions,
        case 
            when year >= 2020 then true
            else false
        end as is_post_covid
    from source
)

select * from renamed 