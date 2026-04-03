-- представление для получения текущей позиции по всем бумагам на всех счетах
create MATERIALIZED VIEW v_positions_current AS
select t.account_id
    , t.asset_id
    , a.ticker
    , a.asset_name
    , a.asset_type
    , sum(
        case when side = 'BUY' then quantity
            when side = 'SELL' then - quantity 
        end) as position_qty
from trades t
join assets a using(asset_id)
group by t.account_id
    , t.asset_id
    , a.ticker
    , a.asset_name
    , a.asset_type
having sum(
        case when side = 'BUY' then quantity
            when side = 'SELL' then - quantity
        end) <> 0
;

-- обновления поступления по позииции бумаг в портфеле
REFRESH MATERIALIZED VIEW v_positions_current;
