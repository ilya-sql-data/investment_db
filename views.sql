-- обновления поступления по позииции бумаг в портфеле
REFRESH MATERIALIZED VIEW v_cash_balance;
REFRESH MATERIALIZED VIEW v_portfolio_current;
REFRESH MATERIALIZED VIEW v_portfolio_weights;
REFRESH MATERIALIZED VIEW v_positions_current;
REFRESH MATERIALIZED VIEW v_positions_with_avg_price;


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
        end) <> 0;

-- представление средней цены входа в позицию по каждой бумаге на каждом счете
create MATERIALIZED view v_positions_with_avg_price as 
select t.account_id,
    t.asset_id,
    a.ticker,
    a.asset_type,
    ROUND(sum(case when t.side = 'BUY' then t.quantity else -t.quantity end), 2) as position_qty,
    round(sum(case when t.side = 'BUY' then t.quantity * t.price else 0 end)
        / nullif(sum(case when t.side = 'BUY' then t.quantity else 0 end), 0), 2) as avg_buy_price
from trades t
join assets a using(asset_id)
group by t.account_id, t.asset_id, a.ticker, a.asset_type
HAVING sum(case when t.side = 'BUY' then t.quantity else -t.quantity end) > 0;

-- представление для витрины текущих цен на активы в портфеле
create MATERIALIZED VIEW v_portfolio_current as 
with latest_prices as (
    select distinct on (asset_id)
        asset_id
        , price_date
        , close_price
    from prices
    order by asset_id, price_date desc
)
SELECT pos.account_id
    , pos.asset_id
    , pos.ticker
    , pos.asset_type
    , pos.position_qty
    , pos.avg_buy_price
    , lp.close_price as market_price
    , pos.avg_buy_price * pos.position_qty as cost_basis
    , pos.position_qty * lp.close_price as market_value
    , pos.position_qty * (lp.close_price - pos.avg_buy_price) as unrealized_pnl
from v_positions_with_avg_price as pos
join latest_prices as lp using(asset_id);

-- представление для получения текущих весов бумаг в портфеле
create MATERIALIZED VIEW v_portfolio_weights as
with portfolio as (
    select account_id
        , asset_id
        , ticker
        , position_qty
        , avg_buy_price
        , market_price
        , cost_basis
        , market_value
        , unrealized_pnl
    from v_portfolio_current
),
totals as (
    select account_id, sum(market_value) as total_portfolio_value
    from portfolio
    group by 1
)
select p.*
    , t.total_portfolio_value
    , market_value
        / nullif(t.total_portfolio_value, 0) as weight_in_portfolio
from portfolio p
join totals t using(account_id);

-- представление свободных денег на кошелке брокера (пока что без учета сделок)
create MATERIALIZED VIEW v_cash_balance as 
select account_id
    , currency
    , sum(amount) filter(where txn_type in('Дивиденды', 'Купон')) as cash_balance
from cash_transactions
GROUP BY 1,2

