# End-to-End Flow — How the Stack Was Tested

This documents how the full trading flow was verified on the EC2 box after
`docker-compose up`: infrastructure first (containers, Postgres, Kafka), then
auth, then order placement through Kafka and the executor back into Postgres,
and finally a full browser-style user journey replayed with `curl`.

All commands run **on the EC2 box** from the repo root (`~/ETP-testing`).
The analytics ETL (DuckDB) is out of scope for this document.

---

## 0. The flow being tested

```
 Browser / curl
     │
     │ 1. register / login            ┌──────────────┐
     ├───────────────────────────────▶│ auth-service │──── auth.users, auth.refresh_token
     │    ◀── JWT + refresh cookie    │   :3000      │     (Postgres)
     │                                └──────────────┘
     │ 2. POST /api/v1/orders (Bearer JWT)
     ▼
 ┌───────────┐  3. insert order (NEW)   ┌──────────┐
 │ trade-api │─────────────────────────▶│ Postgres │ trading.orders
 │   :8085   │                          │  :5432   │
 └───────────┘                          └──────────┘
     │ 4. ORDER_PLACED ─▶ Kafka topic "orders"             ▲
     ▼                                                     │ 7. order FILLED/REJECTED,
 ┌──────────┐  5. GET quote            ┌───────────┐       │    holding + cash updated
 │ executor │─────────────────────────▶│ Fauxnance │       │
 │  :8083   │◀── price ────────────────│  (HTTPS)  │       │
 └──────────┘                          └───────────┘       │
     │ 6. fill decision ───────────────────────────────────┘
     └─▶ TRADE_* event ─▶ Kafka topic "trade-events"

 Unmarketable LIMIT orders stay NEW; the executor's MarketDataPoller re-checks
 them every POLL_INTERVAL_SECONDS (60s) and fills them once the price allows.
```

---

## 1. Prerequisites

### 1.1 `.env` with a real Fauxnance key

The executor needs live prices. Without a real key and URL, **no order ever
fills**: market orders are rejected with `PRICE_NOT_AVAILABLE` and limit
orders stay `NEW`. This is because the default `FAUXNANCE_BASE_URL`
(`http://localhost:8080`) points at the executor container itself.

```bash
cp .env.example .env
# edit .env:
FAUXNANCE_API_KEY=<your fnx_dev_... key>
FAUXNANCE_BASE_URL=https://y4t9nq2bqf.execute-api.eu-west-2.amazonaws.com/v1
```

`.env` is in `.gitignore`, so the key is never committed.

Check that the key works from inside the executor container:

```bash
docker exec trading-executor python3 -c "
import os, urllib.request
r = urllib.request.Request(os.environ['FAUXNANCE_BASE_URL'] + '/quotes/AAPL',
                           headers={'X-Api-Key': os.environ['FAUXNANCE_API_KEY']})
print(urllib.request.urlopen(r, timeout=8).read()[:200])"
```

Expected: JSON with `"symbol":"AAPL","price":...`. A `403 Forbidden` means the
key is wrong or missing.

### 1.2 Frontend URLs (`docker-compose.yml`)

The frontend passes `AUTH_URL` and `BACKEND_URL` to the **browser**, not to its
own server. They used to be set to `http://auth-service:3000` and
`http://trade-api:8085`, Docker-internal names a browser cannot resolve. Those
two lines were removed, so the app falls back to `http://localhost:3000` and
`http://localhost:8085`.

### 1.3 Start the stack

```bash
docker-compose up --build -d
docker-compose ps
```

If you only changed `.env` or the frontend settings, recreate just that service:

```bash
docker-compose up -d --no-deps executor
docker-compose up -d --no-deps frontend
```

---

## 2. Infrastructure checks

### 2.1 Containers

```bash
docker-compose ps
```

| Container              | Expected state                          |
|------------------------|-----------------------------------------|
| trading-postgres       | Up (healthy)                            |
| trading-kafka          | Up (healthy)                            |
| trading-kafka-init     | **Exited (0)**: one-shot topic creator, this is correct |
| trading-auth-service   | Up (healthy)                            |
| trading-trade-api      | Up (healthy)                            |
| trading-executor       | Up (no healthcheck defined)             |
| trading-frontend       | Up (healthy)                            |

### 2.2 Postgres: schema and seed data

```bash
docker exec trading-postgres psql -U postgres -d trading_system_db \
  -c "\dt auth.*" -c "\dt trading.*" \
  -c "SELECT username, email FROM auth.users;" \
  -c "SELECT * FROM trading.holding;"
```

Expected:
- `auth` schema: `users`, `refresh_token`
- `trading` schema: `account`, `holding`, `instrument`, `orders`
- Seed user `demo` / `demo@example.com` (password `Capstone@2026`, account 1)
- Account 1 holds `AAPL 50 @ 150.00`

### 2.3 Kafka: topics

```bash
docker exec trading-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
```

Expected: `orders`, `orders.DLT`, `trade-events`, `trade-events.DLT`,
`market-data`, `market-data.DLT` (plus the internal `__consumer_offsets`).
Topic auto-creation is disabled on purpose, so all six must exist.

### 2.4 Executor is consuming

```bash
docker logs trading-executor 2>&1 | grep "partitions assigned"
docker exec trading-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --group trade-executor --describe
```

Expected: the `trade-executor` group owns the 3 `orders` partitions, and `LAG`
is `0` (or `-` for partitions that have never had a message).

`NOT_COORDINATOR` / `JoinGroup failed` lines at startup are INFO-level noise
while Kafka elects a group coordinator. They are harmless once partitions are
assigned.

---

## 3. Auth service (auth-service ↔ Postgres)

> The login body field is **`identifier`** (username *or* email), not
> `username` as `DEPLOYMENT_TESTING.md` says. Sending `username` returns `422`.

```bash
U=testuser_$(date +%s)

# Register → 201; running it again → 409 (duplicate)
curl -s -X POST localhost:3000/auth/register -H 'Content-Type: application/json' \
  -d "{\"firstName\":\"Test\",\"lastName\":\"User\",\"username\":\"$U\",\"email\":\"$U@example.com\",\"password\":\"TestPass1234\",\"confirmPassword\":\"TestPass1234\"}" \
  -w "\nHTTP %{http_code}\n"

# Login → 200, JWT in body, refresh_token cookie saved to jar.txt
curl -s -X POST localhost:3000/auth/login -H 'Content-Type: application/json' \
  -d "{\"identifier\":\"$U\",\"password\":\"TestPass1234\"}" -c jar.txt -o login.json -w "HTTP %{http_code}\n"

TOKEN=$(python3 -c "import json;print(json.load(open('login.json'))['accessToken'])")
ACC=$(python3 -c "import json;print(json.load(open('login.json'))['user']['accountId'])")
echo "accountId=$ACC"
```

Verify the user and their trading account landed in Postgres:

```bash
docker exec trading-postgres psql -U postgres -d trading_system_db -c \
  "SELECT u.username, a.account_id, a.cash_balance
     FROM auth.users u JOIN trading.account a USING (user_id)
    WHERE u.username = '$U';"
```

Expected: one row with a new `account_id` and `cash_balance = 100000.00`.

Other auth checks:

| Check                                 | Command (abridged)                                          | Expected |
|---------------------------------------|-------------------------------------------------------------|----------|
| Login by email                        | `-d '{"identifier":"<email>","password":...}'`              | 200      |
| Wrong password                        | `-d '{"identifier":"<user>","password":"wrong"}'`           | 401      |
| Current user                          | `GET /auth/me` with `Authorization: Bearer $TOKEN`          | 200      |
| Refresh session                       | `POST /auth/refresh -b jar.txt`                             | 200      |
| Logout                                | `POST /auth/logout -b jar.txt`                              | 200      |
| Refresh after logout                  | `POST /auth/refresh -b jar.txt`                             | 401      |
| Swagger UI                            | `GET /docs`                                                 | 200      |

---

## 4. Orders (trade-api → Kafka → executor → Postgres)

> The endpoint is **`POST /api/v1/orders`**, not `/orders`. The body needs
> `accountId`, `symbol`, `side`, `quantity`, `price`, `orderType` and a unique
> `idempotencyKey` (8–100 chars). Send `"price": 0` for MARKET orders; leaving
> `price` out currently causes a 500 (known bug, see §7).

### 4.1 Place orders

```bash
order() {
  curl -s -X POST localhost:8085/api/v1/orders \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$1" -w "  HTTP %{http_code}\n"
}
K=test-$(date +%s)

order "{\"accountId\":$ACC,\"symbol\":\"AAPL\",\"side\":\"BUY\", \"quantity\":10, \"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-1\"}"
order "{\"accountId\":$ACC,\"symbol\":\"MSFT\",\"side\":\"BUY\", \"quantity\":2,  \"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-2\"}"
order "{\"accountId\":$ACC,\"symbol\":\"TSLA\",\"side\":\"BUY\", \"quantity\":1,  \"price\":1,\"orderType\":\"LIMIT\", \"idempotencyKey\":\"$K-3\"}"
sleep 3
order "{\"accountId\":$ACC,\"symbol\":\"AAPL\",\"side\":\"SELL\",\"quantity\":4,  \"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-4\"}"
order "{\"accountId\":$ACC,\"symbol\":\"AAPL\",\"side\":\"SELL\",\"quantity\":100,\"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-5\"}"

# Replaying an idempotency key → 409
order "{\"accountId\":$ACC,\"symbol\":\"AAPL\",\"side\":\"BUY\", \"quantity\":10, \"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-1\"}"
```

Each accepted order returns `200` with `"status":"NEW"`. The executor settles
it within a second or two.

### 4.2 Verify the message went through Kafka

```bash
# ORDER_PLACED events published by trade-api
docker exec trading-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning --timeout-ms 6000

# TRADE_* events published by the executor after deciding each order
docker exec trading-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic trade-events --from-beginning --timeout-ms 6000

# Dead-letter topics should be empty (all offsets 0)
docker exec trading-kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic orders.DLT
docker exec trading-kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic trade-events.DLT
```

To watch the executor handle an order (quote fetch, fill decision, settlement):

```bash
docker logs -f trading-executor 2>&1 | grep -v ConsumerCoordinator
```

### 4.3 Verify the result in Postgres

```bash
docker exec trading-postgres psql -U postgres -d trading_system_db \
  -c "SELECT order_id, ticker, side, quantity, order_type, status, executed_price, rejection_reason
        FROM trading.orders WHERE account_id = $ACC ORDER BY order_id;" \
  -c "SELECT ticker, quantity, average_price FROM trading.holding WHERE account_id = $ACC;" \
  -c "SELECT cash_balance FROM trading.account WHERE account_id = $ACC;"
```

### 4.4 Verify the same via the API (what the dashboard shows)

```bash
curl -s -H "Authorization: Bearer $TOKEN" localhost:8085/api/v1/accounts/$ACC/orders
curl -s -H "Authorization: Bearer $TOKEN" localhost:8085/api/v1/accounts/$ACC/positions
curl -s -H "Authorization: Bearer $TOKEN" localhost:8085/api/v1/accounts/$ACC/balance
```

### 4.5 Actual results from the test run (2026-09-29, live Fauxnance prices)

| Order                          | Status   | Executed price | Why                                   |
|--------------------------------|----------|----------------|---------------------------------------|
| MARKET BUY 10 AAPL             | FILLED   | 330.57         | market order fills at the live price  |
| MARKET BUY 2 MSFT              | FILLED   | 510.71         |                                       |
| LIMIT BUY 1 TSLA @ 1.00        | NEW      | –              | below market; poller keeps re-checking|
| MARKET SELL 4 AAPL             | FILLED   | 330.57         |                                       |
| MARKET SELL 100 AAPL           | REJECTED | –              | only 6 held                           |

Positions afterwards: `AAPL 6 @ 330.57`, `MSFT 2 @ 510.71`.

Cash check: `100000 − 10×330.57 − 2×510.71 + 4×330.57 = 96995.16`, which
matched `trading.account.cash_balance` and `/balance` exactly.

A LIMIT order priced *above* market (e.g. `"price":100000`) fills immediately
at the market price, not at the limit.

---

## 5. Security checks

```bash
# No token → 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8085/api/v1/orders -H 'Content-Type: application/json' -d '{}'

# Reading someone else's account (account 1 = demo) → 401
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" localhost:8085/api/v1/accounts/1/balance

# Placing an order on someone else's account → 403
order "{\"accountId\":1,\"symbol\":\"AAPL\",\"side\":\"BUY\",\"quantity\":1,\"price\":0,\"orderType\":\"MARKET\",\"idempotencyKey\":\"$K-idor\"}"
```

All three were blocked as expected.

---

## 6. Full user journey (browser flow replayed with curl)

This replays exactly what the browser does, including the
`Origin: http://localhost:4200` header, so CORS is exercised too:

1. Load pages `/`, `/register`, `/login`, `/dashboard`, `/analytics` → all `200`.
   The login page contains `AUTH_URL = "http://localhost:3000"` and
   `BACKEND_URL = "http://localhost:8085"`.
2. Register a new user → 201.
3. Log in → 200, JWT and `refresh_token` cookie.
4. Dashboard data: `/auth/me`, `/api/v1/accounts/{id}`, `/positions`, `/orders` → new account with 100000 cash, empty positions and orders.
5. Place the five orders from §4.1.
6. Reload dashboard data → orders, positions and cash as in §4.5.
7. `POST /auth/refresh` with the cookie → 200 (what the page does when the 15-min JWT expires).
8. `POST /auth/logout` → 200; refresh again → 401.

The browser's real login encrypts credentials (RSA-OAEP wraps an AES-GCM
key; body is `{"request":"<encKey>.<iv>.<cipher>"}`). That path was checked
separately by running the page's exact WebCrypto steps in Node inside the
auth container, and it logged in as `demo` with `200`.

CORS preflight check:

```bash
for u in localhost:3000/auth/login localhost:8085/api/v1/orders; do
  curl -s -o /dev/null -D - -X OPTIONS http://$u -H "Origin: http://localhost:4200" \
    -H "Access-Control-Request-Method: POST" | grep -i "^HTTP\|allow-origin"
done
```

Expected: both return `Access-Control-Allow-Origin: http://localhost:4200`.

### Opening the UI in a real browser

The UI works only when the browser sees everything as `localhost`, so use an
SSH tunnel from your own machine and keep that session open:

```bash
ssh -i <key.pem> -L 4200:localhost:4200 -L 3000:localhost:3000 -L 8085:localhost:8085 ec2-user@<ec2-public-ip>
```

Then browse `http://localhost:4200`. All three ports are required; the page
calls the auth service and trade-api directly from the browser.

Opening `http://<public-ip>:4200` directly does **not** work yet:
- the security group probably blocks the ports;
- trade-api CORS only allows `localhost:4200`, `127.0.0.1:4200` and `frontend:4200` (another origin gets 403);
- the refresh cookie is `Secure`, so browsers drop it over plain http on non-localhost hosts.

---

## 7. Known issues found during testing

| # | Issue | Impact | Where |
|---|-------|--------|-------|
| 1 | Executor runs as non-root `app` but `/data` on a fresh `analytics_data` volume is root-owned → ETL `Permission denied` | ETL broken on any fresh deploy | `executor/Dockerfile`: add `RUN mkdir -p /data && chown app:app /data` before `USER app` |
| 2 | `FAUXNANCE_BASE_URL` defaults to `http://localhost:8080` | No fills without a `.env` override | `docker-compose.yml`, `.env.example` |
| 3 | Market-data events never published: `Map.of(...)` rejects the always-null `bid`/`ask` | `market-data` topic stays empty; log shows `Failed to publish market-data event ...: null` | `MarketDataPoller.publishMarketDataEvent` |
| 4 | MARKET order without `price` → 500 (`price` is `NOT NULL`) | API clients get 500; UI unaffected (sends `price: 0`) | trade-api `OrderService` / schema |
| 5 | 500 responses include raw SQL / exception text | Information leak | trade-api `GlobalExceptionHandler` |
| 6 | Unknown routes (e.g. `POST /orders`) → 500 instead of 404 | Misleading errors | trade-api `GlobalExceptionHandler` |
| 7 | Malformed JSON to auth → HTTP 400 but `errorCode: SRV-500` | Cosmetic | auth-service error filter |
| 8 | Executor has no healthcheck | `docker-compose ps` can't show its health | `docker-compose.yml` |
| 9 | `DEPLOYMENT_TESTING.md` uses `username` for login and `/orders` for orders | Guide commands fail | `DEPLOYMENT_TESTING.md` |
| 10 | ETL watermark is on `received_at`, so status changes after first load are missed | Analytics shows stale status (out of scope here) | `executor/analytics_pipeline.py` |

---

## Quick reference

| Service      | Port | Check                                           |
|--------------|------|-------------------------------------------------|
| Frontend     | 4200 | `curl -s -o /dev/null -w "%{http_code}" localhost:4200/` → 200 |
| Auth service | 3000 | `localhost:3000/docs` (Swagger)                 |
| Trade API    | 8085 | `curl localhost:8085/health` → `{"status":"UP"}` |
| Executor     | 8083 | `docker logs trading-executor`                  |
| Postgres     | 5432 | `docker exec -it trading-postgres psql -U postgres -d trading_system_db` |
| Kafka        | 9092 | `docker exec trading-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` |

Demo login: `demo` / `Capstone@2026` (account 1).
