-- информация по имеющимся аккаунтам
create table accounts (
    account_id bigserial PRIMARY KEY, -- id аккаунта
    account_name text not NULL, -- имя моего аккаунта
    broker_name text not null, -- название брокера
    account_type text not null default 'brokerage', -- тип аккаунта
    base_currency char(3) not null DEFAULT 'RUB', -- валюта вложенных денег
    opened_at date, -- дата открытия
    is_active BOOLEAN not null default true -- используется ли?
);

-- таблица видов драгоценных бумаг. В ней заполняется вся основная информация по 
-- бумагам в портфеле. для облигаций так же есть столбец по информации купонов и погашения
create table assets (
    asset_id bigserial primary key,
    ticker text not null UNIQUE, -- кодировка драг бумаги
    asset_name text not null, -- название драг бумаги
    asset_type text not null, -- тип драг бумаги
    currency char(3) not null default 'RUB',
    sector text,
    maturity date, -- дата погашения облигаций
    nominal decimal(18,4), -- номинал облигации
    coupon_rate decimal(18,4), -- ставка купона облигации 
    created_at TIMESTAMP not null DEFAULT now()
);

-- в данной таблице записывается все сделки с бумагами
create table trades (
    trade_id bigserial primary key,
    account_id bigint not null REFERENCES accounts(account_id),
    asset_id bigint not null REFERENCES assets(asset_id),
    trade_date date not null,
    side text not null CHECK(side in ('BUY', 'SELL')),
    quantity NUMERIC(18,6) not null check(quantity > 0), -- количество драг бумаг
    price NUMERIC(18,6) not null check(price > 0),
    accrued_interest NUMERIC(18,6) not null DEFAULT 0, -- НКД
    commission numeric(18,6) not null DEFAULT 0,
    trade_currency char(3) not null default 'RUB',
    comment TEXT
);

-- таблица транзакций денег на аккаунте (пополнение, вывод...)
create table cash_transactions (
    cash_id bigserial primary key,
    account_id bigint not null REFERENCES accounts(account_id),
    asset_id bigint REFERENCES assets(asset_id),
    txn_date date not null,
    txn_type text not null check(txn_type in ('Пополнение', 'Вывод', 'Налог','Дивиденды','Купон')),
    amount numeric(18,6) not null check(amount > 0),
    commission numeric(18,6) not null DEFAULT 0,
    currency char(3) not null DEFAULT 'RUB',
    comment TEXT
);