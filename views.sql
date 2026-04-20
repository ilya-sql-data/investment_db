-- Обновляю materialized views после загрузки новых данных.
-- Запускать этот блок имеет смысл после обновления trades / cash_transactions / prices.
-- Для обычных VIEW refresh не нужен: их определение пересчитывается на лету.
REFRESH MATERIALIZED VIEW v_cash_balance;
REFRESH MATERIALIZED VIEW v_portfolio_current;
REFRESH MATERIALIZED VIEW v_portfolio_weights;
REFRESH MATERIALIZED VIEW v_positions_current;
REFRESH MATERIALIZED VIEW v_positions_with_avg_price;


-- Текущая открытая позиция по каждой бумаге на каждом счете.
-- Здесь я считаю только итоговое количество бумаги:
-- BUY увеличивает позицию, SELL уменьшает.
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

-- Упрощенная средняя цена покупки по открытой позиции.
-- Здесь средняя цена считается только по всем BUY-сделкам,
-- поэтому этот view не учитывает корректную WAC-логику после продаж.
-- Использую его как промежуточную витрину старого подхода.
create MATERIALIZED view v_positions_with_avg_price as 
select t.account_id,
    t.asset_id,
    a.ticker,
    a.asset_type,
    ROUND(sum(
        case when t.side = 'BUY'
            then t.quantity else -t.quantity
        end), 2) as position_qty,
    round(sum(
        case when t.side = 'BUY'
            then t.quantity * t.price else 0
        end) / nullif(sum(
            case when t.side = 'BUY'
                then t.quantity else 0
            end), 0), 2) as avg_buy_price
from trades t
join assets a using(asset_id)
group by t.account_id, t.asset_id, a.ticker, a.asset_type
HAVING sum(case when t.side = 'BUY' then t.quantity else -t.quantity end) > 0;

-- Текущая рыночная витрина по портфелю.
-- Беру последнюю доступную цену из prices и считаю:
-- cost_basis, market_value и unrealized_pnl.
-- Основа этой витрины уже переведена на v_trade_wac,
-- поэтому avg_buy_price здесь фактически означает WAC avg_cost_after.
create MATERIALIZED VIEW v_portfolio_current as 
with latest_wac as (
    select distinct on (account_id, asset_id)
        account_id
        , asset_id
        , qty_after
        , cost_after
        , avg_cost_after
        , trade_date
        , trade_id
    from v_trade_wac
    order by account_id, asset_id, trade_date desc, trade_id desc
),
latest_prices as (
    select distinct on (asset_id)
        asset_id
        , price_date
        , close_price
    from prices
    order by asset_id, price_date desc
)
SELECT lw.account_id
    , a.asset_name
    , a.ticker
    , a.asset_type
    , lw.qty_after as position_qty
    , lw.avg_cost_after as avg_buy_price
    , lw.cost_after as cost_basis
    , lp.close_price as market_price
    , lw.qty_after * lp.close_price as market_value
    , (lw.qty_after * lp.close_price) - lw.cost_after as unrealized_pnl
from latest_wac as lw
join assets as a using(asset_id)
join latest_prices as lp using(asset_id)
where lw.qty_after > 0
order by unrealized_pnl desc;

-- Доли бумаг в текущем портфеле по рыночной стоимости.
-- Сначала считаю market_value по каждой позиции,
-- затем считаю total_portfolio_value по счету
-- и делю стоимость позиции на общий размер портфеля.
create MATERIALIZED VIEW v_portfolio_weights as
with portfolio as (
    select account_id
        , asset_name
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

-- Денежный поток по сделкам.
-- BUY уменьшает cash на сумму сделки и комиссию,
-- SELL увеличивает cash на сумму продажи за вычетом комиссии.
create view v_trade_cash_flow as 
select trade_id
    , account_id
    , asset_id
    , trade_date
    , trade_currency
    , side
    , quantity
    , price
    , round(quantity * price, 2) as trade_amount
    , round(case
        when side = 'BUY' then -((quantity*price) + accrued_interest + coalesce(commission,0)) 
        when side = 'SELL' then ((quantity*price) + accrued_interest) - coalesce(commission,0)
        else 0
    end,2) as cash_flow_amount
from trades;

-- Единый журнал денежных движений по счету.
-- Объединяю денежную сторону сделок и cash_transactions,
-- чтобы дальше считать cash_balance из одного источника.
create view v_cash_ledger as 
select account_id
    , trade_date as cash_date
    , trade_currency
    , 'trade' as source_type
    , side as operation_type
    , cash_flow_amount as amount
from v_trade_cash_flow

union all

select account_id
    , txn_date
    , currency
    , 'cash_transaction'
    , txn_type
    , amount - commission as amount
from cash_transactions;

-- Итоговый денежный остаток по счету и валюте.
-- Это сумма всех денежных движений из cash ledger.
create materialized view v_cash_balance as
select account_id
    , trade_currency
    , round(sum(amount),2) as cash_balance
from v_cash_ledger
group by 1,2;

-- Базовый поток сделок для дальнейших расчетов.
-- Я нормализую сделки в единый поток:
-- BUY -> положительное количество
-- SELL -> отрицательное количество
-- Этот view нужен как исходный слой для running position и WAC.
create  VIEW v_trade_flow_base as
select trade_id
    , account_id
    , asset_id
    , trade_date
    , side
    , quantity
    , price
    , case when side = 'BUY' then quantity
        when side = 'SELL' then - quantity
        else 0
    end as trade_flow
from trades;

-- Накопительная позиция по каждой бумаге в хронологическом порядке.
-- running_qty_before показывает остаток до сделки.
-- running_qty_after показывает остаток после сделки.
-- Этот слой нужен для контроля качества данных:
-- например, чтобы найти продажи раньше покупок.
create  VIEW v_trade_flow_running as
select fb.*,
    sum(trade_flow) over(partition by account_id, asset_id order by trade_date, trade_id
        rows between unbounded preceding and current row) as running_qty_after,
    sum(trade_flow) over(partition by account_id, asset_id order by trade_date, trade_id
        rows between unbounded preceding and current row) - trade_flow as runnung_qty_before 
from "public"."v_trade_flow_base" fb;

-- Основной расчетный слой WAC по каждой сделке.
-- Здесь я последовательно прохожу сделки в хронологическом порядке
-- и считаю состояние позиции после каждой операции:
-- qty_after   -> сколько бумаг осталось после сделки
-- cost_after  -> суммарная себестоимость оставшегося остатка
-- avg_cost_after -> средняя себестоимость одной бумаги после сделки
--
-- Дополнительно считаю:
-- avg_cost_before -> средняя себестоимость до текущей сделки
-- realized_pnl    -> реализованный результат на продаже
--
-- Это техническое представление, на котором дальше нужно строить
-- корректные витрины текущих позиций и P&L.
create view v_trade_wac as
with recursive ordered_trades as (
    -- Упорядочиваю сделки внутри account_id + asset_id,
    -- чтобы рекурсивно считать состояние позиции шаг за шагом.
    select row_number() over(partition by account_id, asset_id order by trade_date, trade_id) as rn
        , trade_id
        , account_id
        , asset_id
        , trade_date
        , side
        , quantity
        , price
    from v_trade_flow_base
),
 wac as (
    -- Anchor: первая сделка по инструменту.
    -- На этом шаге количество и себестоимость равны параметрам первой сделки.
    select rn
        , trade_id 
        , account_id
        , asset_id
        , trade_date
        , side
        , quantity
        , round(price,2) as price
        , round(quantity::numeric(18,6)) as qty_after
        , round(quantity * price,2) as cost_after
    from ordered_trades
    where rn = 1

    union all

    -- Recursive step: рассчитываю новое состояние позиции
    -- на основе предыдущего состояния и текущей сделки.
    -- После BUY увеличиваю количество и стоимость позиции.
    -- После SELL уменьшаю количество и списываю себестоимость проданного объема.
    select t.rn
        , t.trade_id 
        , t.account_id
        , t.asset_id
        , t.trade_date
        , t.side
        , t.quantity
        , round(t.price,2) as price
        -- количество бумаги после сделки
        , round(case when t.side = 'BUY' then (w.qty_after + t.quantity)::numeric(18,6)
            else  (w.qty_after - t.quantity)::numeric(18,6)
        end) as qty_after
        -- оставшая себестоимость
        , round(case when t.side = 'SELL' and w.qty_after - t.quantity = 0 then 0
                when t.side = 'SELL' then w.cost_after - (t.quantity * (w.cost_after / nullif(w.qty_after, 0)))
                    else w.cost_after + (t.quantity * t.price)
        end,2) as cost_after
    from wac w
    join ordered_trades t
        on t.account_id = w.account_id
            and t.asset_id = w.asset_id
            and t.rn = w.rn + 1
),
wac_after as (
    -- Считаю среднюю себестоимость после сделки.
    -- Пока расчет без учета комиссии.
    select * 
        -- средняя цена пока без учета коммиссии
        , round(case when qty_after = 0 then 0
            else cost_after / qty_after
        end,2) as avg_cost_after
    from wac
    order by rn
), 
wac_before as (
    -- Подтягиваю среднюю себестоимость до сделки.
    -- Это нужно для realized_pnl на SELL.
    select *,
        lag(avg_cost_after, 1,0) over(partition by account_id, asset_id order by rn) as avg_cost_before
    from wac_after 
)
-- Финальный результат по каждой сделке.
-- Для SELL считаю realized_pnl,
-- для BUY realized_pnl = 0.
select *
    , case when side = 'SELL' then round((price - avg_cost_before) * quantity,2) 
        else 0
    end as realized_pnl
from wac_before;

-- Реализованный P&L по каждой сделке продажи.
-- Это самый детальный слой realized результата:
-- одна строка = одна продажа из v_trade_wac.
create view v_realized_pnl_trades as 
select w.trade_id
    , w.account_id
    , w.asset_id
    , a.asset_name
    , a.ticker
    , w.trade_date
    , w.quantity
    , w.price as sell_price
    , w.avg_cost_before
    , w.realized_pnl
from v_trade_wac w
join assets a using(asset_id)
where w.side = 'SELL';

-- Агрегированный realized P&L по бумаге внутри счета.
-- Нужен для ответа на вопрос:
-- на каких инструментах уже зафиксирована прибыль или убыток.
create view v_realized_pnl_by_asset as 
select account_id
    , asset_id
    , ticker
    , asset_name
    , count(*) as sell_trades_count
    , round(sum(realized_pnl),2) as total_realized_pnl
from v_realized_pnl_trades
group by account_id
    , asset_id
    , ticker
    , asset_name;

-- Агрегированный realized P&L на уровне счета.
-- Это верхнеуровневая сводка по уже закрытому результату.
create view v_realized_pnl_by_account as 
select account_id
    , count(*) as sell_trades_count
    , round(sum(realized_pnl),2) as total_realized_pnl
from v_realized_pnl_trades
group by 1;

-- Сводная P&L-витрина по счету.
-- Объединяю текущую нереализованную переоценку портфеля
-- и уже зафиксированный realized P&L по продажам.
create view v_pnl_summary_by_account as
with unrealized as (
    select account_id
        , round(sum(market_value),2) as total_market_value
        , round(sum(unrealized_pnl),2) as total_unrealized_pnl
    from v_portfolio_current
    group by 1
)
select u.account_id
    , u.total_market_value
    , u.total_unrealized_pnl
    , coalesce(r.total_realized_pnl,0) as total_realized_pnl
    , round(u.total_unrealized_pnl + coalesce(r.total_realized_pnl,0),2) as total_pnl
from unrealized u
left join v_realized_pnl_by_account r using(account_id);
