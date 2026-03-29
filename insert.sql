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
    txn_date,
    txn_type,
    amount,
    currency,
    comment
)
values
    (1, '2024-01-01', 'deposit', 10000, 'RUB', 'Первое пополнение счета');