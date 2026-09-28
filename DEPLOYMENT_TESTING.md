# Sprint 8 — Deployment & Testing Guide

This document covers three things:
1. How environment variables and API keys reach each container.
2. How to build and start the full stack with Docker Compose.
3. How to test the full flow end-to-end: register/login (Postgres) → place an
   order (Kafka) → executor fill + analytics ETL (DuckDB).

Run all commands below from the repo root on your own machine — the
build needs real internet access to pull base images from Docker Hub and
dependencies from Maven Central / npm / PyPI.

---

## 1. Where environment variables and API keys live

Two different mechanisms are involved — don't mix them up:

- **`ARG` in each Dockerfile** — build-time only, baked into the image at
  `docker build` time (things like `APP_PORT`, `JAVA_VERSION`, `START_CMD`).
  These are generic knobs for reusing the Dockerfile on a different project,
  not where secrets go.
- **`environment:` in `docker-compose.yml`** — run-time, injected into each
  container when it *starts*. This is where real config and secrets
  (`JWT_SECRET`, DB credentials, `FAUXNANCE_API_KEY`, etc.) live.

The chain looks like this:

```
.env  (file you create locally, gitignored — never committed)
   │  docker compose reads it automatically
   ▼
docker-compose.yml → environment: { JWT_SECRET: ${JWT_SECRET:-fallback} }
   │  passed into the running container as a real OS environment variable
   ▼
your app code reads it: process.env.JWT_SECRET / os.environ["DB_PASSWORD"] / System.getenv(...)
```

Concretely:

- `.env.example` at the repo root lists every variable with a safe default —
  `docker compose up` works even without a `.env` file, falling back to
  those defaults.
- Copy it once and edit the real values in your own copy:
  ```
  cp .env.example .env
  ```
  The only placeholder that actually needs a real value is
  `FAUXNANCE_API_KEY` (mock value works fine for local testing).
- `.env` is already listed in `.gitignore` (confirmed) — it is never
  committed, so secrets never end up in git history.
- `auth-service` and `trade-api` are both given the *same* `JWT_SECRET` /
  `JWT_ISSUER` from `.env` — that shared secret is how JWT trust works
  between them without any network call.
- Nothing sensitive is hardcoded in any Dockerfile. Baking a secret into an
  image layer would let anyone who gets the image extract it.

---

## 2. Build and run the stack

### Step 1 — Create your `.env`

```powershell
cd C:\Users\Administrator\Documents\CD2026
copy .env.example .env
```

Edit `.env` and set a real `FAUXNANCE_API_KEY` if you have one.

### Step 2 — Build and start everything

```powershell
docker compose up --build -d
docker compose ps
```

Expect 7 containers: `postgres`, `kafka`, `kafka-init` (exits with code 0 —
that's correct, it's a one-shot job that creates topics then exits),
`auth-service`, `trade-api`, `executor`, `frontend`.

If anything isn't healthy, check logs:

```powershell
docker compose logs -f kafka-init auth-service trade-api executor frontend
```

---

## 3. Verify the base infrastructure

### Postgres — schema + seed data

```powershell
docker exec -it trading-postgres psql -U postgres -d trading_system_db -c "\dt auth.*" -c "\dt trading.*" -c "SELECT username, email FROM auth.users;" -c "SELECT * FROM trading.holding;"
```

Expect the seed demo user (`demo` / `Capstone@2026`) and one AAPL holding.

### Kafka — topics created

```powershell
docker exec -it trading-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

Expect: `orders`, `orders.DLT`, `trade-events`, `trade-events.DLT`,
`market-data`, `market-data.DLT`.

---

## 4. Test register + login (auth-service ↔ Postgres)

```powershell
curl -X POST http://localhost:3000/auth/register -H "Content-Type: application/json" -d "{\"firstName\":\"Test\",\"lastName\":\"User\",\"username\":\"testuser1\",\"email\":\"test1@example.com\",\"password\":\"TestPass1234\",\"confirmPassword\":\"TestPass1234\"}"

curl -X POST http://localhost:3000/auth/login -H "Content-Type: application/json" -d "{\"username\":\"testuser1\",\"password\":\"TestPass1234\"}" -c cookies.txt -v
```

- Register → `201`. Re-running the same call should now `409` (duplicate).
- Login → `200` with a JWT in the response body, and a `refresh_token`
  cookie set (visible in the `-v` output / `cookies.txt`).
- Confirm the new row landed in Postgres:
  ```powershell
  docker exec -it trading-postgres psql -U postgres -d trading_system_db -c "SELECT username FROM auth.users WHERE username='testuser1';"
  ```

Save the JWT from the login response — it's used as a Bearer token next.

---

## 5. Test placing an order (trade-api ↔ Kafka ↔ executor ↔ Postgres)

```powershell
curl -X POST http://localhost:8085/orders -H "Authorization: Bearer <JWT_FROM_LOGIN>" -H "Content-Type: application/json" -d "{\"instrument\":\"AAPL\",\"side\":\"BUY\",\"quantity\":10,\"orderType\":\"MARKET\"}"
```

> The exact endpoint/body may differ slightly — check `sprint8/SPRINT8_RUN.md`'s
> API section if this returns 404.

Then verify the loop happened, in order:

```powershell
# 1. Message landed on the orders topic
docker exec -it trading-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders --from-beginning --max-messages 1

# 2. Executor consumed it and produced a fill/trade-event
docker exec -it trading-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic trade-events --from-beginning --max-messages 1

# 3. Order + updated holding landed in Postgres
docker exec -it trading-postgres psql -U postgres -d trading_system_db -c "SELECT * FROM trading.orders ORDER BY created_at DESC LIMIT 5;" -c "SELECT * FROM trading.holding;"
```

---

## 6. Verify analytics / dashboard (DuckDB ETL loop)

```powershell
docker compose logs executor | Select-String "ETL"
```

Then open `http://localhost:4200` in a browser, log in with the demo or your
test user, and confirm the analytics/dashboard page reflects the new
holding/trade. The executor's Python ETL subprocess rewrites
`analytics.duckdb` on the shared `analytics_data` volume roughly every 45s
(`ETL_REFRESH_INTERVAL_SECONDS`), so allow a minute after your trade before
checking.

---

## Quick reference — ports

| Service      | Port  | URL / check                          |
|--------------|-------|---------------------------------------|
| Frontend     | 4200  | http://localhost:4200                |
| Auth Service | 3000  | http://localhost:3000/docs (Swagger) |
| Trade API    | 8085  | http://localhost:8085/health         |
| Executor     | 8083  | -                                     |
| Postgres     | 5432  | -                                     |
| Kafka        | 9092  | -                                     |
