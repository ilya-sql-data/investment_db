insert into accounts (
    account_name,
    broker_name,
    account_type,
    base_currency,
    opened_at
)
values
    ('Основной брокерский счет', 'T-Bank', 'brokerage', 'RUB', '2024-01-01');

insert into assets (
    ticker,
    asset_name,
    asset_type,
    currency,
    sector,
    maturity,
    nominal,
    coupon_rate,
    created_at
)
values
    ('SBER', 'Сбербанк', 'stock', 'RUB', 'finance', null, null, null, now()),
    ('OFZ26238', 'ОФЗ 26238', 'bond', 'RUB', null, '2041-05-15', 1000, 7.10, now()),
    ('SBMX', 'БПИФ Индекс МосБиржи', 'fund', 'RUB', 'index', null, null, null, now());

insert into trades (
    account_id,
    asset_id,
    trade_date,
    side,
    quantity,
    price,
    accrued_interest,
    commission,
    comment
)
select
    1,
    asset_id,
    '2024-02-01',
    'BUY',
    10,
    300.00,
    0,
    2.00,
    'Первая покупка'
from assets
where ticker = 'SBER';

insert into cash_transactions (
    account_id,
    asset_id,
    txn_date,
    txn_type,
    amount
)
select 1, asset_id, '2026-04-28', 'Дивиденды', 378
from assets 
where asset_name = 'ОФЗ';


-- Тестовая загрузка snapshot на текущую дату.
-- Источник данных: верхнеуровневые summary views по счету и P&L.
insert into portfolio_snapshot_daily (
    snapshot_date,
    account_id,
    market_value,
    cash_balance,
    total_account_value,
    unrealized_pnl,
    realized_pnl,
    net_income
)
select
    current_date as snapshot_date,
    a.account_id,
    a.total_market_value as market_value,
    a.cash_balance,
    a.total_account_value,
    p.total_unrealized_pnl as unrealized_pnl,
    p.total_realized_pnl as realized_pnl,
    a.net_income
from v_account_summary a
join v_pnl_summary_by_account p
    on p.account_id = a.account_id;
