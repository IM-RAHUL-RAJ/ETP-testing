# Sprint 8 — Run Book & Verification

## Overview

Sprint 8 delivers a complete authentication layer (`Sprint 08 Auth Service`,
separate NestJS service) that **owns the users table and all password
material**, plus a Trade REST API (`sprint8/`, port **8085**) that trusts
tokens issued by the auth service, and a frontend (port **4200**) that
registers/logs in against the auth service and calls the trade API.

- **Auth service** — `sprint8-auth-service/` (NestJS, TypeScript, Jest)
- **Trade API** — `sprint8/` (Spring Boot / MyBatis, port 8085)
- **Frontend** — `sprint8/front-end/` (Flask, port 4200; register is the default page at `/`)
- **Database** — PostgreSQL `trading_system_db`, schemas `auth` + `trading`

## Ports

| Service     | Port |
| ----------- | ---- |
| Auth API    | 3000 |
| Trade API   | 8085 |
| Frontend    | 4200 |
| Executor    | 8083 |

## Prerequisites

- Java 21 + Maven 3.9+ (trade-api), Node 20/24 + npm (auth service), Python 3
  (frontend), PostgreSQL 13+ (uses `gen_random_uuid`).

## 1. Database bootstrap

```bash
psql -U postgres -h localhost -p 5432 -c "CREATE DATABASE trading_system_db;"
psql -U postgres -h localhost -p 5432 -d trading_system_db -v ON_ERROR_STOP=1 -f sprint8/db/schema.sql
psql -U postgres -h localhost -p 5432 -d trading_system_db -v ON_ERROR_STOP=1 -f sprint8/db/seed-data.sql
```

`schema.sql` sets `search_path = trading, public` for the postgres role in this
database so unqualified `account`/`orders`/`holding`/`instrument` queries (used
by the executor & ETL) keep resolving to `trading`.

`auth.users.username` and `auth.users.email` are both `NOT NULL UNIQUE`
(duplicate registration → `409 AUTH-409`).

Seed demo credentials:

| username | email             | password        |
| -------- | ----------------- | --------------- |
| demo     | demo@example.com  | Capstone@2026   |

Account **1** is seeded with an AAPL holding (50 @ 150.00), a filled order and
100000.00 USD.

## 2. Run the auth service (port 3000)

```bash
cd sprint8-auth-service
cp .env.example .env      # edit DB credentials if needed
npm install
npm test                  # 29 tests in 5 suites
npm run test:integration  # 21 tests (real PostgreSQL; global-setup creates trading_system_db_test)
npm run build
npm start
```

Swagger UI: http://localhost:3000/docs — OpenAPI JSON: http://localhost:3000/docs/json

On first boot the auth service generates an **RSA-4096 keypair** into
`LOGIN_KEY_DIR` (default `login-keys/`, auto-created). The keypair is used to
**seal login/register payloads** (see the credential-transport section below);
keep `private.pem` secret and keep the directory between restarts (the public
key is served at `/auth/public-key` and the frontend caches it).
`login-keys/` is git-ignored.

## 3. Run the trade API (port 8085)

```bash
cd sprint8
cp .env.example .env      # edit DB credentials / JWT secret if needed
mvn package -DskipTests
java -jar target/sprint-08-trade-api-1.0-SNAPSHOT.jar
```

Health: http://localhost:8085/health

The `JWT_SECRET` and `JWT_ISSUER` **must match** the auth service's
configuration — the trade API rejects tokens with a different issuer, a blank
`sub`, or an empty `roles` claim.

## 4. Run the frontend (port 4200)

```bash
cd sprint8/front-end
pip install -r requirements.txt
python app.py
```

- `/` — **Create account** (registration, default page)
- `/login` — sign in with username or email
- `/dashboard` — profile / place order / holdings / orders (uses the trade API
  with the stored Bearer token; refreshes the access token on 401 via
  `/auth/refresh`)
- `/analytics` — reporting dashboard reading `analytics.duckdb` (built by the
  ETL below)

**Route guard.** `/dashboard` is protected: `app.js` redirects
anonymous visitors to `/login` and re-validates the access token via
`/auth/me` on navigation — it never refreshes on ordinary navigation. The
access token is only renewed when a protected call returns 401 (the
`apiFetch` wrapper calls `/auth/refresh` once and retries); if the refresh
token is invalid/expired the user is bounced to `/login`. **`/analytics` is
public** — it is not part of the session and is left untouched by the guard.

After a successful registration the frontend redirects to **exactly
`/login`** (no query string). Registration never stores tokens or a refresh
cookie.

The frontend stores **only the access token** (`jwt`) in localStorage; on load
it purges any legacy `refreshToken` / `refresh_token` / `accountId` /
`account_id` keys. The **refresh token is an HttpOnly cookie** and the account
id is always derived from the authenticated user via `/auth/me` / the login
response — never from localStorage.

## 5. Run the order executor + analytics ETL

The executor (`executor/`, Spring Boot, port **8083**) consumes `ORDER_PLACED`
events from Kafka and fills orders in `trading_system_db` (transactional:
order → `FILLED`, account cash with optimistic `version` lock, holding upsert),
then publishes `ORDER_FILLED` / `ORDER_REJECTED` to the `trade-events` topic.
A `MarketDataPoller` also rescues still-`NEW` orders by polling quotes and
filling them once the price condition is met.

```bash
cd executor
# executor/.env must target trading_system_db and the Kafka broker:
#   DB_NAME=trading_system_db
#   KAFKA_BOOTSTRAP_SERVERS=<kafka-host>:9092   (see KAFKA_BOOTSTRAP_SERVERS in sprint8/.env)
mvn package -DskipTests
java -jar target/trade-executor-1.0-SNAPSHOT.jar
# with env overrides for DB_USER/DB_PASSWORD/FAUXNANCE_API_KEY/FAUXNANCE_BASE_URL
# (application.yml connects via ?currentSchema=trading and defaults DB_NAME=trading_system_db)
```

The jar's `EtlStartupRunner` launches `executor/etl_trigger_service.py`, which
every ~45 s runs `executor/analytics_pipeline.py` against **`trading_system_db`**
(schema is discovered via `current_schema()`; orders without `instrument_id`
are joined to `instrument` on `ticker`/`symbol`) and refreshes
`<repo>/analytics.duckdb` (`dim_account`, `dim_date`, `dim_instrument`,
`fact_trades`, `dead_letter_trades`), which the dashboard serves.

## API reference (contract)

| Method | Path            | Auth  | Success | Errors |
| ------ | --------------- | ----- | ------- | ------ |
| POST   | `/auth/register`| none  | 201 `{ message, user }` — account created, **no tokens and no cookie**; sign in afterwards | 409 `AUTH-409`, 422 `VAL-422` |
| POST   | `/auth/login`   | none  | 200 access body `{ accessToken, expiresIn, user }` + sets `refresh_token` cookie (HttpOnly; Secure; SameSite=Lax; Path=/; 7 days) | 401 `AUTH-401`, 429 `RATE-429`, 422 `VAL-422` |
| GET    | `/auth/public-key`| none | 200 `{ key }` — PEM public key used to seal login/register credentials | — |
| POST   | `/auth/refresh` | cookie (or body fallback)| 200 renewed access body `{ accessToken, expiresIn, user }` — **non-rotating**: the same refresh token keeps its 7-day life, cookie not re-issued | 401 `AUTH-401`, 422 `VAL-422` |
| POST   | `/auth/logout`  | cookie (or body fallback)| 200 `{ message }`; revokes + clears cookie | 401 `AUTH-401` |
| GET    | `/auth/me`      | Bearer| 200 profile + accountId | 401 `AUTH-401` |

Error envelope: `{ "errorCode": string, "message": string }`.

The **refresh token is never in a response body** — it is an HttpOnly + Secure +
SameSite cookie that JavaScript cannot read; the frontend only stores the
access token (localStorage) and sends `credentials: 'include'` so the cookie
travels with `/auth/refresh` and `/auth/logout`.

Registration atomically creates `auth.users` row **and** a
`trading.account` (USD, 100000.00, ACTIVE, version 1) in one transaction, but
**registration itself issues no token and sets no cookie** — the flow is
register → `POST /auth/login` → tokens (the frontend redirects to `/login`
after registration). Login returns the access body and sets the `refresh_token`
cookie.
JWT claims: `sub` = user `uuid`, `accountId` (integer — coerced from the DB
BIGSERIAL), `roles` (always non-empty), `iss` = `auth-service`, 15-minute
expiry (access `JWT_TTL_SECONDS=900`; refresh cookie `REFRESH_TTL_SECONDS=604800`,
7 days). Tokens are issued at every successful login; the access token is
renewed (non-rotating) at `/auth/refresh` while the **same** refresh token stays
valid for its full 7-day lifetime — the cookie is left untouched.

**Password policy (review decision, spec-aligned).** Length-only: minimum **12**
characters, maximum **128** (`RegisterDto` `MinLength`/`MaxLength`), per the
spec's "length beats character-class rules / do not impose a symbol
requirement" guidance. Username `^[a-zA-Z0-9._-]+$`, min 3, max 64. The
register page mirrors the same rule client-side (`minlength="12"` + a live
✔/✗ "Minimum 12 characters" indicator) so submissions are blocked before the
network.

**Password handling (task 3/5).** Passwords are hashed with **bcrypt cost 12**
(`BCRYPT_ROUNDS` in `auth.service.ts`, spec: "bcrypt at cost 12 or above"). Only
the bcrypt hash is persisted; no plaintext password is ever stored, logged
(`AuthService` logs user ids/identifiers only) or echoed.

**Credential transport — sealed payloads.** The browser never sends the
plaintext password over the wire. On login and registration `app.js` fetches
`GET /auth/public-key`, generates an ephemeral AES-256-GCM key, and encrypts
the payload (credentials + a fresh random nonce + a 60-second expiry) in hybrid
mode: RSA-OAEP (SHA-256) wraps the AES key, and the body becomes
`{ "request": "<base64>.<base64>.<base64>" }`. The server unwraps with its
private key, authenticates the GCM tag, checks the nonce is fresh/unused and
the expiry window holds, then runs the exact same DTO validation as the
plaintext path — so the plaintext password no longer appears in the DevTools
Network tab. Replayed ciphertext, stale payloads and tampered bodies are
refused with `422 VAL-422`. The plaintext `{ identifier, password }` form is
kept as a compatibility fallback for API clients, and the frontend falls back
to it only when Web Crypto is unavailable (plain-HTTP hosts other than
localhost). A TLS-terminating proxy/HTTPS is still required in front of the
auth service before deployment (TLS protects the HTTP layer — headers, cookies
and the whole session — which payload sealing does not).

Trade API endpoints (Bearer token required for `/api/v1/**`; cross-account
access returns 401):

- `GET /api/v1/accounts/{id}` — account incl. formatted id `ACC-000001` and `holderName` joined from `auth.users`
- `GET /api/v1/accounts/{id}/balance`
- `GET /api/v1/accounts/{id}/positions`
- `GET /api/v1/accounts/{id}/orders?status=&from=&to=`
- `POST /api/v1/orders` — place order (`idempotencyKey` required, min 8 chars)
- `DELETE /api/v1/orders/{idempotencyKey}` — cancel a `NEW` order

## Security & review verification (2026-09-25)

Re-run of the Sprint 8 auth review after the register→login rework:

1. Unit: `npm test` → **29/29** in 5 suites (password policy now length-only; DTO
   suite covers min 12 / max 128 / username bounds; new `LoginCryptoService`
   suite covers seal round-trip, tamper, replay, expiry and wrong-key
   rejection).
2. Integration: `npm run test:integration` → **21/21** against a real
   PostgreSQL `trading_system_db_test` (global-setup creates the DB and the
   `auth`/`trading` schemas; drop/recreate each run). Covers register
   (success/dup 409/invalid email 422/short password 422/mismatch 422/DB
   persistence with bcrypt + account row), login (claims exactly
   `accountId, roles, iat, exp, iss, sub`; refresh token stored as SHA-256;
cookie attributes HttpOnly/Secure/SameSite=Lax/Path=/), **non-rotating
    refresh** (the same token works repeatedly, access renewed 15-min, exactly
    one unrevoked DB row, expired → 401, logout revokes → 401),
   `/auth/me` ownership mapping, and the **sealed-credential path** (public-key
   endpoint serves the PEM; a sealed register/login succeeds exactly like the
   plaintext one; replay of the same ciphertext → `422 VAL-422`; tampered and
   garbage `request` bodies → `422 VAL-422`; DTO validation still applies after
   decryption).
3. Playwright E2E: `cd e2e && npm install && npx playwright install chromium &&
npx playwright test` → **15/15**. Notably: registration lands on exactly
    `/login` (no query string) with no tokens stored and no cookie; **the login
    and register POST bodies are sealed `{"request": "..."}` blobs that never
    contain the plaintext password or readable field names**; protected
    `/dashboard` redirects anonymous users while `/analytics` is **public**
    (no `/auth/me` guard); after login only the
   `jwt` key is in localStorage (no `accountId`/`refresh_token`); the access
   token is renewed **only on a 401** (navigation itself never triggers
   `/auth/refresh`; non-rotating — the cookie never changes); an invalid/revoked refresh token bounces to `/login`; the
   refresh cookie is HttpOnly+Secure+SameSite=Lax on the auth origin; an
   account-id mismatch in the trade API is refused with `403 ACC-403`.
4. **accountId typed correctly**: Postgres BIGSERIAL values are coerced to
   numbers in `AuthService` (login/refresh/me/register), so `user.accountId`,
   `/auth/me` and the JWT claim are integers, not strings.
5. **Credential transport**: RSA-4096 keypair generated on boot; `GET
   /auth/public-key` serves the PEM; the frontend seals login/register payloads
   (RSA-OAEP + AES-256-GCM + nonce + expiry) so the DevTools Network payload no
   longer shows the plaintext password; verified live (register via UI →
   Network payload = `{request: "…"}`) and by E2E/integration.
6. `npm run build` clean; auth service restarted on the new build (port 3000).

## Verified end-to-end (this machine, 2026-09-24)

1. `CREATE DATABASE trading_system_db` + `schema.sql` + `seed-data.sql` — OK.
2. Auth: register `tuser2` → **201** `{ message, user }`, **no access token and
   no `refresh_token` cookie** (must sign in afterwards); duplicate register →
   **409 `AUTH-409`**.
3. Login `tuser1` → **200** (accountId 2, access body + cookie set); wrong password → **401 `AUTH-401`**;
   unknown user → **401 `AUTH-401`** (identical envelope, uniform 150ms delay).
4. `GET /auth/me` → **200** with accountId.
5. `POST /auth/refresh` (cookie, empty body) → **200** renewed access token,
   same refresh token still valid (non-rotating — cookie untouched, DB holds one
   row); `POST /auth/logout` → **200** "Logged out" and the cookie
   is cleared (Max-Age 0).
6. Trade API with an auth-issued token:
   - `GET /api/v1/accounts/2` → **200** `ACC-000002`, holder `Test User`, 100000.00.
   - `GET /api/v1/accounts/1` (demo) → `ACC-000001`, holder `Demo Investor`,
     positions `AAPL 50 @ 150.00`, orders `ORD-seed-0001 FILLED`.
   - Cross-account `accounts/1` with tuser1's token → **401**.
   - Place order `AAPL BUY 5` → **200** status `NEW`; duplicate idempotency key → **409**;
     cancel → **200** `CANCELLED`.
7. `GET /health` (trade-api) → **200**.
8. Frontend: `/` serves registration page, `/login` serves login page; both link
   to each other; reserved `AUTH_URL=http://localhost:3000`, `BACKEND_URL=http://localhost:8085`.
9. **Order fill E2E (Kafka now reachable at `10.8.71.240:9092`)** — executor
   running against `trading_system_db` (`?currentSchema=trading`):
   - `POST /api/v1/orders` `{symbol: AAPL, accountId: 1, side: BUY, quantity: 5,
     orderType: MARKET, idempotencyKey}` → **200 NEW**.
   - Executor log: consumer `trade-executor` received `ORDER_PLACED`, order 4 → 
     **FILLED @ 337.02**; DB shows `status=FILLED`, `executed_price=337.02000000`.
   - Balance 100000.00 → **98314.90** (5 × 337.02), holding `AAPL 55 @ 167.00`
     (was 50 @ 150.00), account `version` incremented.
   - The earlier order (id 3) that had stayed `NEW` because the executor was on
     the old `trading_db` also filled at 337.02 after the re-point.
10. **Analytics ETL re-pointed** — `analytics_pipeline.py` now reads
    `trading_system_db` (via `PG_SCHEMA=trading`, `current_schema()` discovery);
    warehouse rebuilt from scratch:
    `fact_trades` = exactly the 4 sprint-8 orders (seed FILLED, CANCELLED,
    orders 3+4 FILLED), `dim_account` = ACCOUNT-1 + ACCOUNT-6, `dim_instrument`
    = AAPL/EQUITY/USD/US. Legacy sprint-6 rows that collided on
    `source_order_id` were removed (old file kept as `analytics.duckdb.sprint6-backup`).
11. Tests: trade-api `mvn clean test` → **74/74**, auth `npx jest` → **19/19**.

## Known limitations (environment)

- **Docker is not installed on this machine** — the provided `Dockerfile`s
  (trade-api and auth service) and `docker-compose.yml` are untested here. The
  Kafka broker runs in Docker on the user's machine at the private IP in
  `sprint8/.env` (`KAFKA_BOOTSTRAP_SERVERS`); the executor and trade-api must
  point at it or fills stay `NEW`. **2026-09-25: the broker at that private IP
  was unreachable during the review** (the E2E cross-account checks still pass
  — the 403 fires before any Kafka work; the own-account order assertion is
  skipped when the broker is down).
- **Registration auto-creates the trading account** (user decision): the API
  contract (`auth_api_yaml.txt`) says registration must link to an existing
  `accountId` and must **not** create an account; this implementation instead
  atomically inserts `auth.users` + `trading.account` (USD 100000.00) and
  projects the new `accountId`. Documented divergence; keep in sync with the
  contract for a strict conformance review.
- **Transport is plain HTTP** in this dev environment, but credentials are no
  longer sent as plaintext: the browser seals login/register payloads with the
  server's RSA-4096 public key (RSA-OAEP + AES-256-GCM + fresh nonce + expiry),
  so the literal password does not appear in the request body (DevTools Network
  tab) and replayed/stale ciphertext is rejected. TLS is **still required**
  before deployment to protect the HTTP layer (headers, refresh cookie,
  sessions) — payload sealing is not a substitute for HTTPS, and on plain-HTTP
  hosts other than `localhost` Web Crypto is unavailable so the frontend falls
  back to the plaintext contract.
- **Refresh semantics:** the access token is never refreshed on page
  navigation; `apiFetch` renews it internally only when a
  protected request 401s. The refresh itself is **non-rotating** — the access
  token is re-issued every 15 minutes against the same HttpOnly refresh cookie,
  which keeps its full 7-day life (never re-issued, never in a response body).
  An expired/invalid/revoked refresh token logs the user out.
- Registration intentionally returns **no token**: the refresh-token insert
  happens only at `/auth/login`, so there is no partial-state risk during
  signup (a failed signup leaves no user session). The frontend redirects to
  `/login` after a successful register.
- Login throttle state is in-memory (single instance). Documented in the auth
  service README; a shared store (e.g. Redis) is recommended before
  multi-instance deployment.