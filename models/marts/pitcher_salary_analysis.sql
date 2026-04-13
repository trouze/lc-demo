-- depends_on: {{ ref('int_player_value_analysis') }}
with salary_data as (
    select * from {{ ref('fct_player_salaries') }}
    where is_pitcher = true
    and year >= 2019
),

pitcher_totals as (
    select
        year,
        count(distinct player_id) as total_pitchers,
        sum(salary) as total_salary,
        sum(salary_millions) as total_salary_millions,
        avg(salary) as avg_salary,
        avg(salary_millions) as avg_salary_millions,
        min(salary) as min_salary,
        max(salary) as max_salary
    from salary_data
    group by year
),

pitcher_details as (
    select
        year,
        player_id,
        full_name,
        salary,
        salary_millions
    from salary_data
)

select
    pd.*,
    pt.total_pitchers,
    pt.total_salary_millions as team_total_salary_millions,
    pt.avg_salary_millions as team_avg_salary_millions,
    pt.min_salary,
    pt.max_salary
from pitcher_details pd
left join pitcher_totals pt
    on pd.year = pt.year
order by pd.year desc, pd.salary desc 