import os
import sys
import time
import requests
import psycopg
from datetime import date, timedelta, datetime

MOEX_BASE_URL = "https://iss.moex.com/iss"
REQUEST_TIMEOUT = 30
SLEEP_BETWEEN_REQUESTS = 0.2


def get_db_connection():
    # Я беру DSN из переменной окружения, чтобы не хардкодить доступ к БД в коде.
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        raise RuntimeError("Не задана переменная окружения DATABASE_URL")
    return psycopg.connect(dsn)


def map_market(asset_type: str) -> str:
    """
    Перевожу внутренний asset_type в market_name,
    который понимает API MOEX ISS.
    """
    mapping = {
        "stock": "shares",
        "fund": "shares",
        "bond": "bonds",
    }
    if asset_type not in mapping:
        raise ValueError(f"Неизвестный asset_type: {asset_type}")
    return mapping[asset_type]

def fetch_bond_face_value(secid: str):
    url = f"{MOEX_BASE_URL}/securities/{secid}.json"
    params = {"iss.meta": "off"}

    resp = requests.get(url, params=params, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    payload = resp.json()

    description = payload.get("description", {})
    columns = description.get("columns", [])
    rows = description.get("data", [])

    for row in rows:
        item = dict(zip(columns, row))
        if item.get("name") == "FACEVALUE":
            value = item.get("value")
            if value is not None:
                return float(value)

    return None


def fetch_assets(conn):
    # выбираю только те активы, по которым реально могу сходить в MOEX:
    # нужен secid, board и поддерживаемый тип инструмента.
    query = """
        select
            asset_id,
            ticker,
            asset_name,
            asset_type,
            moex_secid,
            board_id
        from assets
        where moex_secid is not null
          and board_id is not null
          and asset_type in ('stock', 'bond', 'fund')
        order by asset_id
    """
    with conn.cursor() as cur:
        cur.execute(query)
        rows = cur.fetchall()

    assets = []
    for row in rows:
        # сразу собираю строки из БД в удобный словарь,
        # чтобы дальше обращаться к полям по именам.
        assets.append({
            "asset_id": row[0],
            "ticker": row[1],
            "asset_name": row[2],
            "asset_type": row[3],
            "moex_secid": row[4],
            "board_id": row[5],
        })
    return assets


def fetch_candles(secid: str, board_id: str, market: str, from_date: date, till_date: date):
    """
    Здесь запрашиваются дневные свечи по инструменту за нужный диапазон дат.
    Если MOEX отдает данные порциями, добираю их через пагинацию.
    """
    all_rows = []
    start = 0

    while True:
        # Формирую URL под конкретный рынок, board и бумагу.
        url = (
            f"{MOEX_BASE_URL}/engines/stock/markets/{market}/boards/"
            f"{board_id}/securities/{secid}/candles.json"
        )

        # В параметрах задаю диапазон дат, дневной интервал и смещение для пагинации.
        params = {
            "from": from_date.isoformat(),
            "till": till_date.isoformat(),
            "interval": 24,
            "start": start,
            "iss.meta": "off",
        }

        resp = requests.get(url, params=params, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
        payload = resp.json()

        candles = payload.get("candles", {})
        rows = candles.get("data", [])
        columns = candles.get("columns", [])

        if not rows:
            # Если данных больше нет, завершаю цикл.
            break

        for row in rows:
            # Склеиваю список значений с названиями колонок,
            # чтобы получить словарь по каждой свече.
            all_rows.append(dict(zip(columns, row)))

        if len(rows) < 100:
            # Если пришла неполная страница, считаю, что это последний кусок.
            break

        start += len(rows)
        time.sleep(SLEEP_BETWEEN_REQUESTS)

    return all_rows


def normalize_close_price(candle: dict, asset_type: str, face_value: float | None = None):
    # Беру только дату и цену закрытия
    close_price = candle.get("close")
    begin_ts = candle.get("begin")

    if close_price is None or begin_ts is None:
        # Если в свече нет ключевых полей, такую запись пропускаю.
        return None
    
    if asset_type == "bond" and face_value is not None:
        close_price = float(close_price) * face_value / 100
    else:
        close_price = float(close_price)

    price_date = datetime.fromisoformat(begin_ts.replace("Z", "")).date()
    return price_date, float(close_price)


def upsert_prices(conn, asset_id: int, rows, source_name: str = "MOEX"):
    if not rows:
        return 0

    # Использую upsert, чтобы повторный запуск не создавал дубликаты,
    # а обновлял уже существующую цену за дату.
    query = """
        insert into prices (
            asset_id,
            price_date,
            close_price,
            currency,
            source_name
        )
        values (%s, %s, %s, %s, %s)
        on conflict (asset_id, price_date)
        do update set
            close_price = excluded.close_price,
            currency = excluded.currency,
            source_name = excluded.source_name
    """

    payload = []
    for price_date, close_price in rows:
        payload.append((asset_id, price_date, close_price, "RUB", source_name))

    with conn.cursor() as cur:
        cur.executemany(query, payload)

    # Коммичу после пачки записей по одному активу.
    conn.commit()
    return len(payload)


def load_history(days_back: int = 365):
    # В этом режиме загружаю историю за указанное количество дней.
    from_date = date.today() - timedelta(days=days_back)
    till_date = date.today()

    with get_db_connection() as conn:
        assets = fetch_assets(conn)
        print(f"Найдено активов: {len(assets)}")

        total_loaded = 0

        for asset in assets:
            try:
                # Сначала определяю MOEX market по типу актива.
                market = map_market(asset["asset_type"])
                candles = fetch_candles(
                    secid=asset["moex_secid"],
                    board_id=asset["board_id"],
                    market=market,
                    from_date=from_date,
                    till_date=till_date,
                )
                
                face_value = None
                if asset["asset_type"] == "bond":
                    face_value = fetch_bond_face_value(asset["moex_secid"])

                normalized = []
                for candle in candles:
                    # На этом шаге фильтрую и нормализую только пригодные свечи.
                    item = normalize_close_price(candle, asset["asset_type"], face_value)
                    if item is not None:
                        normalized.append(item)

                loaded = upsert_prices(conn, asset["asset_id"], normalized)
                total_loaded += loaded

                print(
                    f"[OK] {asset['ticker']} ({asset['moex_secid']}, {market}, {asset['board_id']}) "
                    f"-> {loaded} записей"
                )

                time.sleep(SLEEP_BETWEEN_REQUESTS)

            except Exception as e:
                # Ошибка по одной бумаге не должна останавливать всю загрузку.
                print(
                    f"[ERROR] {asset['ticker']} ({asset['moex_secid']}) -> {e}",
                    file=sys.stderr
                )

        print(f"Всего загружено/обновлено строк: {total_loaded}")


def load_latest():
    """
    Беру короткий диапазон и сохраняю только
    самую свежую торговую дату по каждому активу.
    """
    from_date = date.today() - timedelta(days=10)
    till_date = date.today()

    with get_db_connection() as conn:
        assets = fetch_assets(conn)
        print(f"Найдено активов: {len(assets)}")

        total_loaded = 0

        for asset in assets:
            try:
                market = map_market(asset["asset_type"])
                candles = fetch_candles(
                    secid=asset["moex_secid"],
                    board_id=asset["board_id"],
                    market=market,
                    from_date=from_date,
                    till_date=till_date,
                )

                face_value = None
                if asset["asset_type"] == "bond":
                    face_value = fetch_bond_face_value(asset["moex_secid"])

                normalized = []
                for candle in candles:
                    item = normalize_close_price(candle, asset["asset_type"], face_value)
                    if item is not None:
                        normalized.append(item)

                if normalized:
                    # Выбираю самую позднюю дату из полученных свечей
                    # и сохраняю только ее.
                    latest_row = max(normalized, key=lambda x: x[0])
                    loaded = upsert_prices(conn, asset["asset_id"], [latest_row])
                else:
                    loaded = 0

                total_loaded += loaded

                print(
                    f"[OK] latest {asset['ticker']} ({asset['moex_secid']}, {market}, {asset['board_id']}) "
                    f"-> {loaded} запись"
                )

                time.sleep(SLEEP_BETWEEN_REQUESTS)

            except Exception as e:
                print(
                    f"[ERROR] latest {asset['ticker']} ({asset['moex_secid']}) -> {e}",
                    file=sys.stderr
                )

        print(f"Всего загружено/обновлено последних цен: {total_loaded}")


if __name__ == "__main__":
    # Ожидаю режим запуска из командной строки: history или latest.
    if len(sys.argv) < 2:
        print("Использование:")
        print("  python load_prices.py history [days_back]")
        print("  python load_prices.py latest")
        sys.exit(1)

    mode = sys.argv[1].lower()

    if mode == "history":
        days_back = int(sys.argv[2]) if len(sys.argv) > 2 else 365
        load_history(days_back=days_back)
    elif mode == "latest":
        load_latest()
    else:
        print("Неизвестный режим. Используй: history или latest")
        sys.exit(1)
