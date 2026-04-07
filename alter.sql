-- добавление в таблицу assets столбцов для подгрзки данных с биржи
alter table assets
add column if not exists moex_secid text,
add column if not exists board_id text;